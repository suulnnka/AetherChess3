// Search: PVS with the full 4ku pruning bundle, TT probing, PV extraction,
// and iterative deepening (main.cpp:628-877, 891-1002). Single-threaded.
//
// Move application is make/unmake on one shared Position; the NNUE
// accumulators live on a per-ply stack (copy-make: written from the parent
// slot plus fused feature deltas, never unmade).
const std = @import("std");
const types = @import("types.zig");
const board = @import("board.zig");
const nnue = @import("nnue.zig");
const tt = @import("tt.zig");
const out = @import("out.zig");

const Position = types.Position;
const Move = types.Move;
const no_move = types.no_move;
const moveEq = types.moveEq;
const Stack = types.Stack;
const inf = types.inf;
const mate_score = types.mate_score;
const Pawn = types.Pawn;
const King = types.King;
const Upper = types.Upper;
const Exact = types.Exact;
const now = types.now;

const isAttacked = board.isAttacked;
const movegen = board.movegen;
const pieceOn = board.pieceOn;

// Search-side material heuristic for move ordering, delta/forward-futility
// pruning and LMR gain classification (cp values, carried over from the 4ku
// HCE table — independent of the NNUE evaluation itself).
const max_material = [7]i32{ 147, 521, 521, 956, 1782, 0, 0 };

// Search limits and hard-stop state (single-threaded: module globals,
// set by the UCI layer / bench before iterativelyDeepen).
pub const Limits = struct {
    depth: i32 = 0, // 0 = unlimited
    nodes: u64 = 0, // 0 = unlimited
    soft: bool = true, // soft time ladder enabled (clock control only)
};
pub var limits: Limits = .{};
pub var hard_stop: u64 = 0; // absolute wall-clock ms; alphabeta aborts past it
var stop_nodes: u64 = std.math.maxInt(u64);
var stopped = false;

// Countermove table: [stm][prev from][prev to] -> refutation move.
// Persisted across searches like the history table; cleared on ucinewgame.
pub var cm_table = std.mem.zeroes([2][64][64]Move);

const append = out.append;
const appendInt = out.appendInt;
const appendMoveStr = out.appendMoveStr;
const flushLine = out.flushLine;

// ---------------------------------------------------------------------------
// History vector (C++ vector<u64> in 4ku; kept as a growable list)
// ---------------------------------------------------------------------------
pub const HistList = struct {
    items: []u64 = &.{},
    len: usize = 0,

    pub fn push(self: *HistList, v: u64) void {
        if (self.len == self.items.len) {
            const new_cap = if (self.items.len == 0) 64 else self.items.len * 2;
            self.items = types.page_alloc.realloc(self.items, new_cap) catch @panic("oom");
        }
        self.items[self.len] = v;
        self.len += 1;
    }

    pub fn pop(self: *HistList) void {
        self.len -= 1;
    }

    pub fn clear(self: *HistList) void {
        self.len = 0;
    }

    pub fn cloneOf(other: *const HistList) HistList {
        var h = HistList{};
        if (other.len > 0) {
            h.items = types.page_alloc.alloc(u64, other.len) catch @panic("oom");
            @memcpy(h.items, other.items[0..other.len]);
            h.len = other.len;
        }
        return h;
    }

    pub fn deinit(self: *HistList) void {
        if (self.items.len > 0) types.page_alloc.free(self.items);
        self.* = .{};
    }
};

const MAX_PLY = 128;
const Accs = [MAX_PLY + 2]nnue.Acc;

// ---------------------------------------------------------------------------
// Search (main.cpp:628-877)
// ---------------------------------------------------------------------------
fn alphabeta(
    pos: *Position,
    accs: *Accs,
    alpha_in: i32,
    beta_in: i32,
    depth_in: i32,
    ply: i32,
    nodes: *u64,
    stack: *[128]Stack,
    hash_history: *HistList,
    hh_table: *[2][2][64][64]i32,
    do_null: bool,
) i32 {
    var alpha = alpha_in;
    var beta = beta_in;
    var depth = depth_in;
    const stm: usize = pos.stm; // this node's side to move (pos is mutated below)

    // Don't overflow the stack
    if (ply > 127)
        return nnue.evalAcc(pos, &accs[@intCast(ply)]);

    // Mate distance pruning
    if (ply > 0) {
        const alpha_mate = -mate_score + ply;
        const beta_mate = mate_score - ply - 1;
        if (alpha < alpha_mate) alpha = alpha_mate;
        if (beta > beta_mate) beta = beta_mate;
        if (alpha >= beta) return alpha;
    }

    // Check extensions
    const in_check = isAttacked(pos, pos.king_sq[stm], stm ^ 1) != 0;
    depth += @intFromBool(in_check);

    var in_qsearch = depth <= 0;
    const tt_key = pos.hash;

    if (ply > 0 and !in_qsearch) {
        // Repetition detection
        for (hash_history.items[0..hash_history.len]) |old_hash| {
            if (old_hash == tt_key)
                return 0;
        }
    }

    // TT Probing
    const tt_entry = &tt.transposition_table[@intCast(tt_key % tt.num_tt_entries)];
    var tt_move = no_move;
    if (tt_entry.key == tt_key) {
        tt_move = tt_entry.move;
        if (alpha == beta - 1 and @as(i32, tt_entry.depth) >= depth and tt_entry.flag != @as(u8, @intFromBool(tt_entry.score < beta)))
            // If tt_entry.score < beta, tt_entry.flag cannot be Lower (ie must be Upper or Exact).
            // Otherwise, tt_entry.flag cannot be Upper (ie must be Lower or Exact).
            return tt_entry.score;
    }
    // Internal iterative reduction
    else {
        depth -= @intFromBool(depth > 3);
    }

    stack[@intCast(ply)].score = nnue.evalAcc(pos, &accs[@intCast(ply)]);
    var static_eval = stack[@intCast(ply)].score;
    const improving = ply > 1 and static_eval > stack[@intCast(ply - 2)].score;

    // If static_eval > tt_entry.score, tt_entry.flag cannot be Lower (ie must be Upper or Exact).
    // Otherwise, tt_entry.flag cannot be Upper (ie must be Lower or Exact).
    if (tt_entry.key == tt_key and tt_entry.flag != @as(u8, @intFromBool(static_eval > tt_entry.score)))
        static_eval = tt_entry.score;

    if (in_qsearch and static_eval > alpha) {
        if (static_eval >= beta)
            return static_eval;
        alpha = static_eval;
    }

    if (ply > 0 and !in_qsearch and !in_check and alpha == beta - 1) {
        // Reverse futility pruning
        if (depth < 8) {
            if (static_eval - 71 * (depth - @as(i32, @intFromBool(improving))) >= beta)
                return static_eval;

            in_qsearch = static_eval + 238 * depth < alpha;
        }

        // Null move pruning (in-place null: stm flip + ep clear; pieces and
        // thus the accumulator are unchanged, copied to the child slot)
        if (depth > 2 and static_eval >= beta and static_eval >= stack[@intCast(ply)].score and do_null and
            pos.colour[stm] & ~pos.pieces[Pawn] & ~pos.pieces[King] != 0)
        {
            const saved_ep = pos.ep;
            const saved_hash = pos.hash;
            if (pos.ep != 0)
                pos.hash ^= board.keys[768 + @as(usize, @intCast(@ctz(pos.ep)))];
            pos.ep = 0;
            pos.stm ^= 1;
            pos.hash ^= 1;
            @memcpy(&accs[@as(usize, @intCast(ply)) + 1], &accs[@intCast(ply)]);
            const null_depth = depth - 4 - @divTrunc(depth, 5) - @min(@divTrunc(static_eval - beta, 196), 3);
            const v = -alphabeta(pos, accs, -beta, -alpha, null_depth, ply + 1, nodes, stack, hash_history, hh_table, false);
            pos.ep = saved_ep;
            pos.hash = saved_hash;
            pos.stm ^= 1;
            if (v >= beta)
                return beta;
        }
    }

    hash_history.push(tt_key);
    defer hash_history.pop();

    var tt_flag: u8 = Upper;

    var num_moves_evaluated: i32 = 0;
    var num_quiets_evaluated: i32 = 0;
    var best_score: i32 = if (in_qsearch) static_eval else -inf;
    var best_move = tt_move;

    const moves = &stack[@intCast(ply)].moves;
    const move_scores = &stack[@intCast(ply)].move_scores;
    const moves_evaluated = &stack[@intCast(ply)].moves_evaluated;
    const num_moves = movegen(pos, moves, in_qsearch);

    var i: i32 = 0;
    loop: while (i < num_moves) : (i += 1) {
        // Score moves at the first loop, except if we have a hash move,
        // then we'll use that first and delay sorting one iteration.
        if (i == @as(i32, @intFromBool(!moveEq(no_move, tt_move)))) {
            var j: i32 = 0;
            while (j < num_moves) : (j += 1) {
                const gain = max_material[moves[@intCast(j)].promo] + max_material[@intCast(pieceOn(pos, moves[@intCast(j)].to))];
                const cm_bonus = @intFromBool(gain == 0 and moveEq(moves[@intCast(j)], cm_table[stm][moves[@intCast(j)].from][moves[@intCast(j)].to]));
                move_scores[@intCast(j)] = hh_table[stm][@intFromBool(gain == 0)][moves[@intCast(j)].from][moves[@intCast(j)].to] +
                    @as(i32, @intFromBool(gain != 0 or moveEq(moves[@intCast(j)], stack[@intCast(ply)].killer))) * 2048 + @as(i32, cm_bonus) * 1024 + gain;
            }
        }

        // Find best move remaining
        var best_move_index = i;
        var j2 = i;
        while (j2 < num_moves) : (j2 += 1) {
            if (moveEq(moves[@intCast(j2)], tt_move)) {
                best_move_index = j2;
                break;
            }
            if (move_scores[@intCast(j2)] > move_scores[@intCast(best_move_index)])
                best_move_index = j2;
        }

        const move = moves[@intCast(best_move_index)];
        moves[@intCast(best_move_index)] = moves[@intCast(i)];
        move_scores[@intCast(best_move_index)] = move_scores[@intCast(i)];

        // Material gain
        const gain = max_material[move.promo] + max_material[@intCast(pieceOn(pos, move.to))];

        // Delta pruning
        if (in_qsearch and !in_check and static_eval + 50 + gain < alpha)
            break :loop;

        // Forward futility pruning
        if (ply > 0 and depth < 8 and !in_qsearch and !in_check and num_moves_evaluated != 0 and
            static_eval + 105 * depth + gain < alpha)
            break :loop;

        // Make the move on the board in place; keep the accumulator of the
        // parent ply and write the child's from it plus the feature deltas.
        stack[@intCast(ply)].current = move;
        const minfo = board.prepareMove(pos, move);
        const undo = board.make(pos, minfo, move);

        nodes.* += 1;
        if (nodes.* >= stop_nodes)
            stopped = true;

        nnue.applyMoveDeltasAcc(&accs[@intCast(ply)], &accs[@as(usize, @intCast(ply)) + 1], minfo.mf_pre, minfo.us, minfo.piece, minfo.ty_to, minfo.from, minfo.to, minfo.victim_ty, minfo.victim_sq, minfo.rook);
        const mf_post = nnue.mirrorFlags(pos);
        if (mf_post[0] != minfo.mf_pre[0]) nnue.refreshPerspAcc(pos, 0, &accs[@as(usize, @intCast(ply)) + 1]);
        if (mf_post[1] != minfo.mf_pre[1]) nnue.refreshPerspAcc(pos, 1, &accs[@as(usize, @intCast(ply)) + 1]);

        var score: i32 = undefined;
        var reduction: i32 = 0;
        if (depth > 3 and num_moves_evaluated > 1) {
            const hist = @divTrunc(hh_table[stm][@intFromBool(gain == 0)][move.from][move.to], 128);
            const clamped = @min(@max(hist, -2), 2);
            reduction = @max(@divTrunc(num_moves_evaluated, 13) + @divTrunc(depth, 14) +
                @as(i32, @intFromBool(alpha == beta - 1)) + @as(i32, @intFromBool(!improving)) - clamped, 0);
        }

        while (num_moves_evaluated != 0) {
            score = -alphabeta(pos, accs, -alpha - 1, -alpha, depth - reduction - 1, ply + 1, nodes, stack, hash_history, hh_table, true);
            if (!(score > alpha and reduction > 0))
                break;
            reduction = 0;
        }

        if (num_moves_evaluated == 0 or (score > alpha and score < beta))
            score = -alphabeta(pos, accs, -beta, -alpha, depth - 1, ply + 1, nodes, stack, hash_history, hh_table, true);

        board.unmake(pos, move, undo);

        // Exit early if out of time or node limit hit
        if (stopped or (depth > 4 and now() >= hard_stop)) {
            return 0;
        }

        if (score > best_score)
            best_score = score;

        if (score > alpha) {
            best_move = move;
            tt_flag = Exact;
            alpha = score;
            stack[@intCast(ply)].move = move;
            if (score >= beta) {
                tt_flag = types.Lower;

                if (gain == 0)
                    stack[@intCast(ply)].killer = move;
                if (ply > 0) {
                    const prev = stack[@intCast(ply - 1)].current;
                    cm_table[stm][prev.from][prev.to] = move;
                }

                const hidx = [2]usize{ stm, @intFromBool(gain == 0) };
                hh_table[hidx[0]][hidx[1]][move.from][move.to] +%= depth *% depth -% @divTrunc(depth *% depth *% hh_table[hidx[0]][hidx[1]][move.from][move.to], 512);
                var j3: i32 = 0;
                while (j3 < num_moves_evaluated) : (j3 += 1) {
                    const prev_gain = max_material[moves_evaluated[@intCast(j3)].promo] + max_material[@intCast(pieceOn(pos, moves_evaluated[@intCast(j3)].to))];
                    const pidx = [2]usize{ stm, @intFromBool(prev_gain == 0) };
                    hh_table[pidx[0]][pidx[1]][moves_evaluated[@intCast(j3)].from][moves_evaluated[@intCast(j3)].to] -%= depth *% depth +% @divTrunc(depth *% depth *% hh_table[pidx[0]][pidx[1]][moves_evaluated[@intCast(j3)].from][moves_evaluated[@intCast(j3)].to], 512);
                }
                break :loop;
            }
        }

        moves_evaluated[@intCast(num_moves_evaluated)] = move;
        num_moves_evaluated += 1;
        if (gain == 0)
            num_quiets_evaluated += 1;

        // Late move pruning based on quiet move count
        if (!in_check and alpha == beta - 1 and num_quiets_evaluated > ((1 + depth * depth) >> @intCast(@intFromBool(!improving))))
            break :loop;
    }

    // Return mate or draw scores if no moves found
    if (best_score == -inf)
        return if (in_check) ply - mate_score else 0;

    // Save to TT
    tt_entry.* = .{
        .key = tt_key,
        .move = best_move,
        .flag = tt_flag,
        .score = @truncate(best_score),
        .depth = @truncate(@as(i32, @intFromBool(!in_qsearch)) * depth),
    };

    return best_score;
}

// ---------------------------------------------------------------------------
// PV extraction (main.cpp:891-920) — TT walk with make/unmake
// ---------------------------------------------------------------------------
fn isPseudolegalMove(pos: *const Position, move: Move) i32 {
    var moves: [256]Move = undefined;
    const num_moves = movegen(pos, &moves, false);
    for (moves[0..@intCast(num_moves)]) |m| {
        if (moveEq(m, move))
            return 1;
    }
    return 0;
}

fn printPv(pos: *Position, move: Move, hash_history: *HistList) void {
    // Legal generation: list membership implies legality
    if (isPseudolegalMove(pos, move) == 0)
        return;

    const minfo = board.prepareMove(pos, move);
    const undo = board.make(pos, minfo, move);

    // Print current move
    append(" ");
    appendMoveStr(move);

    // Probe the TT in the resulting position
    const tt_key = pos.hash;
    const tt_entry = &tt.transposition_table[@intCast(tt_key % tt.num_tt_entries)];

    // Only continue if the move was valid and comes from a PV search
    if (tt_entry.key != tt_key or moveEq(tt_entry.move, no_move) or tt_entry.flag != Exact) {
        board.unmake(pos, move, undo);
        return;
    }

    // Avoid infinite recursion on a repetition
    for (hash_history.items[0..hash_history.len]) |old_hash| {
        if (old_hash == tt_key) {
            board.unmake(pos, move, undo);
            return;
        }
    }

    hash_history.push(tt_key);
    printPv(pos, tt_entry.move, hash_history);
    hash_history.pop();
    board.unmake(pos, move, undo);
}

// ---------------------------------------------------------------------------
// Iterative deepening (main.cpp:923-1002)
// ---------------------------------------------------------------------------
pub fn iterativelyDeepen(
    pos: *Position,
    hash_history: *HistList,
    hh_table: *[2][2][64][64]i32,
    bench_depth: i32,
    total_nodes: *u64,
    allocated_time: i32,
    start_time: u64,
) Move {
    var stack: [128]Stack = std.mem.zeroes([128]Stack);
    var accs: Accs = undefined;
    nnue.refreshAcc(pos, &accs[0]);
    var nodes: u64 = 0;
    stopped = false;
    stop_nodes = if (limits.nodes > 0) limits.nodes else std.math.maxInt(u64);
    // Stability-scaled soft budget: an iteration that changes the best move
    // buys more time (x1.5 per change, cumulative) within the hard budget.
    var opt: i32 = allocated_time;
    var prev_best: Move = no_move;

    var score: i32 = 0;
    var i: i32 = 1;
    depth_loop: while (i < 128) : (i += 1) {
        if (limits.depth > 0 and i > limits.depth)
            break;
        if (nodes >= stop_nodes)
            break;
        var research: i32 = 0;
        var window: i32 = 28 + ((score * score) >> 14);
        while (true) {
            research += 1;
            const alpha = score -% window;
            const beta = score +% window;
            score = alphabeta(pos, &accs, alpha, beta, i, 0, &nodes, &stack, hash_history, hh_table, true);

            // Hard time / node limit exceeded
            if (stopped or now() >= hard_stop)
                return stack[0].move;

            // Print with every iteration normally, or when the target depth
            // has finished when benchmarking
            if (bench_depth == 0 or (i == bench_depth and alpha < score and score < beta)) {
                const elapsed = now() - start_time;
                append("info");
                append(" depth ");
                appendInt(i);
                append(" score cp ");
                appendInt(score);
                if (score >= beta) {
                    append(" lowerbound");
                } else if (score <= alpha) {
                    append(" upperbound");
                }
                append(" time ");
                appendInt(elapsed);
                append(" nodes ");
                appendInt(nodes);
                if (elapsed > 0) {
                    append(" nps ");
                    appendInt(nodes * 1000 / elapsed);
                }
                // Not a lowerbound - a fail low won't have a meaningful PV.
                if (score > alpha) {
                    append(" pv");
                    printPv(pos, stack[0].move, hash_history);
                }
                append("\n");
                flushLine();
            }
            // OpenBench compliance
            if (bench_depth > 0 and i >= bench_depth and alpha < score and score < beta) {
                total_nodes.* += nodes;
                return stack[0].move;
            }

            if (score > alpha and score < beta)
                break;

            window *%= 2;
        }

        // Stability adjustment: best move changed -> extend the soft budget
        if (!moveEq(stack[0].move, prev_best)) {
            opt = @min(@divTrunc(opt * 3, 2), @as(i32, @intCast(@as(i64, @bitCast(hard_stop -% start_time)))));
            prev_best = stack[0].move;
        }

        // Early exit after completed ply (soft ladder, clock control only)
        if (limits.soft and 4 > research) {
            const soft = @divTrunc(@as(i64, opt) * (2 * research - 1), 10);
            if (now() >= start_time +% @as(u64, @bitCast(soft)))
                break :depth_loop;
        }
    }
    return stack[0].move;
}
