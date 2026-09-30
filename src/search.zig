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
const tun = @import("tunables.zig");
const see = @import("see.zig");

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
// NOTE: a 2026-09-29 experiment rescaled this to the v7 net's remove-one-piece
// average ({130,330,410,470,910}) and gated -69±25 over 200 games when the
// dependent qs_delta/ffp margins were left at their old-table optima — the
// margins absorb the scale, so a joint retune is required if ever retried.
const max_material = &tun.mat;

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
// Node count at the last wall-clock probe: clock_gettime costs ~25ns, more
// than a make/unmake pair, so the time limit is only sampled every 2048 nodes.
var time_check_nodes: u64 = 0;

// Countermove table: [stm][prev from][prev to] -> refutation move.
// Persisted across searches like the history table; cleared on ucinewgame.
pub var cm_table = std.mem.zeroes([2][64][64]Move);

// 1-ply continuation history (small table): quality of a quiet move's
// destination given the previous move's piece and destination. Used for
// quiet ordering only (v1); updated with the same depth^2 gravity shape as
// the main history on cutoffs (bonus) and tried quiets (malus).
pub var cont_table = std.mem.zeroes([13][64][64]i16); // [12] = neutral (null-move) context

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
// Distinct TT key contribution for the excluded move of a singular
// verification search (any bijective-enough mix; not a Zobrist table).
inline fn exclHash(m: Move) u64 {
    return (@as(u64, m.from) << 6 | m.to) *% 0x9E3779B97F4A7C15 +% @as(u64, m.promo) *% 0xD1B54A32D192ED03;
}

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
    excluded: Move,
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
    const tt_key = if (moveEq(excluded, no_move)) pos.hash else pos.hash ^ exclHash(excluded);

    if (ply > 0 and !in_qsearch) {
        // 50-move rule: once 100 halfmoves pile up the side to move could
        // claim a draw. In-check nodes still search so a mate delivered on
        // the 100th halfmove is found.
        if (pos.halfmove >= 100 and !in_check)
            return 0;

        // Repetition detection, bounded by the halfmove clock: keys older
        // than the last irreversible move (pawn move / capture) describe a
        // different placement and can never match again.
        const bound: usize = @min(hash_history.len, pos.halfmove);
        for (hash_history.items[hash_history.len - bound .. hash_history.len]) |old_hash| {
            if (old_hash == tt_key)
                return 0;
        }
    }

    // TT Probing (two-tier bucket)
    const tt_entry = tt.probe(tt_key) orelse &tt.no_entry;
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
        if (depth < tun.get(.rfp_max_depth)) {
            if (static_eval - tun.get(.rfp_margin) * (depth - @as(i32, @intFromBool(improving))) >= beta)
                return static_eval;

            in_qsearch = static_eval + tun.get(.razoring) * depth < alpha;
        }

        // Null move pruning (in-place null: stm flip + ep clear; pieces and
        // thus the accumulator are unchanged, copied to the child slot)
        if (depth > 2 and static_eval >= beta and static_eval >= stack[@intCast(ply)].score and do_null and
            pos.colour[stm] & ~pos.pieces[Pawn] & ~pos.pieces[King] != 0)
        {
            const saved_ep = pos.ep;
            const saved_hash = pos.hash;
            const saved_halfmove = pos.halfmove;
            if (pos.ep != 0)
                pos.hash ^= board.keys[768 + @as(usize, @intCast(@ctz(pos.ep)))];
            pos.ep = 0;
            pos.stm ^= 1;
            pos.hash ^= 1;
            pos.halfmove += 1;
            @memcpy(&accs[@as(usize, @intCast(ply)) + 1], &accs[@intCast(ply)]);
            // neutral conthist context for the null child (row 12 is never
            // read for ordering context except through this sentinel)
            stack[@intCast(ply)].current = no_move;
            stack[@intCast(ply)].current_pt = 12;
            const null_depth = depth - tun.get(.nmp_base) - @divTrunc(depth, tun.get(.nmp_div)) - @min(@divTrunc(static_eval - beta, tun.get(.nmp_eval_div)), tun.get(.nmp_cap));
            const v = -alphabeta(pos, accs, -beta, -alpha, null_depth, ply + 1, nodes, stack, hash_history, hh_table, false, no_move);
            pos.ep = saved_ep;
            pos.hash = saved_hash;
            pos.halfmove = saved_halfmove;
            pos.stm ^= 1;
            if (v >= beta)
                return beta;
        }
    }

    // Singular extension: with a deep TT entry backing the ttMove, search
    // all OTHER moves at reduced depth with beta = ttScore - depth. If they
    // all fail low the ttMove is the only promising move — extend it by 1.
    // Excluded-move key isolates the verification; no back-to-back ext.
    var ext_se: i32 = 0;
    stack[@intCast(ply)].se_ext = false;
    const parent_ext = ply > 0 and stack[@intCast(ply - 1)].se_ext;
    if (ply > 0 and !in_qsearch and alpha == beta - 1 and depth >= tun.get2(.se_depth) and
        !parent_ext and
        tt_entry.key == tt_key and !moveEq(tt_move, no_move) and
        (tt_entry.flag == types.Lower or tt_entry.flag == types.Exact) and
        @as(i32, tt_entry.depth) >= depth - 3 and
        // exclude mate scores: they live in |s| >= mate_score - 127, so the
        // window must be mate_score - 200 (SF VALUE_KNOWN_WIN); a +100 bound
        // lets every mate score through
        tt_entry.score > @as(i32, 200) - mate_score and tt_entry.score < mate_score - 200)
    {
        const beta_v = @as(i32, tt_entry.score) - @divTrunc(tun.get2(.se_margin) * depth, 16);
        const v = alphabeta(pos, accs, beta_v - 1, beta_v, @divTrunc(depth - 1, tun.get2(.se_vdiv)), ply, nodes, stack, hash_history, hh_table, false, tt_move);
        if (v < beta_v)
            ext_se = 1;
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
            // Conthist context: the move that led into this node (parent's
            // current move and its mover). Fixed for the whole scoring pass.
            const ch_on = ply > 0;
            const ch_pt: usize = if (ch_on) stack[@intCast(ply - 1)].current_pt else 0;
            const ch_to: u8 = if (ch_on) stack[@intCast(ply - 1)].current.to else 0;
            var j: i32 = 0;
            while (j < num_moves) : (j += 1) {
                const gain = max_material[moves[@intCast(j)].promo] + max_material[@intCast(pieceOn(pos, moves[@intCast(j)].to))];
                const cm_bonus = @intFromBool(gain == 0 and moveEq(moves[@intCast(j)], cm_table[stm][moves[@intCast(j)].from][moves[@intCast(j)].to]));
                const ch = if (gain == 0 and ch_on) cont_table[ch_pt][ch_to][moves[@intCast(j)].to] else 0;
                // MVV-LVA: victim x16 dominates the attacker term (victim still
                // decides order); with SEE-backed pruning/LMR the bad captures
                // this drops below the killers are handled by their own channels
                const order = if (gain != 0)
                    gain * tun.get2(.mvv_scale) - max_material[@intCast(pieceOn(pos, moves[@intCast(j)].from))]
                else
                    0;
                var score = hh_table[stm][@intFromBool(gain == 0)][moves[@intCast(j)].from][moves[@intCast(j)].to] +
                    @as(i32, @intFromBool(gain != 0 or moveEq(moves[@intCast(j)], stack[@intCast(ply)].killer))) * 2048 + @as(i32, cm_bonus) * 1024 + order + ch;
                // Bad-capture demotion (Cfish movepick.c:150): a capture whose
                // SEE falls below a fraction of its ordering value is demoted
                // below the quiets (tried last) instead of ahead of the
                // killers. Main search only — qsearch's negative-SEE prune
                // already removes those moves outright.
                if (!in_qsearch and gain != 0 and
                    see.see(pos, moves[@intCast(j)]) < -tun.get2(.demote_coef) * @divTrunc(order, 1024))
                    score -= tun.get2(.demote_pen);
                move_scores[@intCast(j)] = score;
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

        // singular verification root: the excluded move is the one under test
        if (!moveEq(excluded, no_move) and moveEq(move, excluded))
            continue;

        // Material gain
        const gain = max_material[move.promo] + max_material[@intCast(pieceOn(pos, move.to))];

        // SEE of a capture/promotion, computed once on the pre-move board
        // (after make, board[to] holds the mover and board[from] is 0xFF,
        // which idType() reads as a rook). Only the qsearch capture prunes
        // consume it; quiets run their own call in the hanging-quiet prune.
        const cap_see: i32 = if (in_qsearch and gain != 0) see.see(pos, move) else 0;

        // SEE pruning in qsearch (promotions and EP exempt): any capture
        // with SEE < 0; equal exchanges (SEE == 0) also go when stand-pat
        // plus the futility margin cannot reach alpha (Cfish qsearch:
        // futilityBase <= alpha && !see_ge(move, 1))
        if (in_qsearch and !in_check and move.promo == types.None and gain != 0) {
            if (cap_see < 0)
                continue;
            if (cap_see == 0 and static_eval + tun.get2(.qs_fut_margin) <= alpha)
                continue;
        }

        // Delta pruning
        if (in_qsearch and !in_check and static_eval + tun.get(.qs_delta) + gain < alpha)
            break :loop;

        // SEE pruning of hanging quiets (main search) — quadratic capped at
        // depth 12 so the threshold keeps firing in long-timecontrol searches
        // (uncapped it starves: -4600 at depth 16 but -12000 at depth 26)
        if (ply > 0 and !in_qsearch and !in_check and gain == 0 and move.promo == types.None and
            see.see(pos, move) < -tun.get2(.sq_coef) * @min(depth, tun.get2(.sq_cap)) * @min(depth, tun.get2(.sq_cap)))
            continue;

        // Forward futility pruning
        if (ply > 0 and depth < tun.get(.ffp_max_depth) and !in_qsearch and !in_check and num_moves_evaluated != 0 and
            static_eval + tun.get(.ffp_margin) * depth + gain < alpha)
            break :loop;

        // Make the move on the board in place; keep the accumulator of the
        // parent ply and write the child's from it plus the feature deltas.
        stack[@intCast(ply)].current = move;
        const minfo = board.prepareMove(pos, move);
        stack[@intCast(ply)].current_pt = @intCast(minfo.us * 6 + minfo.piece);
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
        const ext: i32 = @intFromBool(ext_se != 0 and moveEq(move, tt_move));
        if (ext != 0)
            stack[@intCast(ply)].se_ext = true;
        if (depth > 3 and num_moves_evaluated > 1) {
            const hist = @divTrunc(hh_table[stm][@intFromBool(gain == 0)][move.from][move.to], 128);
            const clamped = @min(@max(hist, -2), 2);
            reduction = @max(@divTrunc(num_moves_evaluated, tun.get(.lmr_move_div)) + @divTrunc(depth, tun.get(.lmr_depth_div)) +
                @as(i32, @intFromBool(alpha == beta - 1)) + @as(i32, @intFromBool(!improving)) - clamped, 0);
        }

        while (num_moves_evaluated != 0) {
            score = -alphabeta(pos, accs, -alpha - 1, -alpha, depth - reduction - 1 + ext, ply + 1, nodes, stack, hash_history, hh_table, true, no_move);
            if (!(score > alpha and reduction > 0))
                break;
            reduction = 0;
        }

        if (num_moves_evaluated == 0 or (score > alpha and score < beta))
            score = -alphabeta(pos, accs, -beta, -alpha, depth - 1 + ext, ply + 1, nodes, stack, hash_history, hh_table, true, no_move);

        board.unmake(pos, move, undo);

        // Exit early if out of time or node limit hit. The node limit is
        // exact (checked every move); the wall clock every 2048 nodes at
        // ANY depth — qsearch blossoms (mutual-check chains through the
        // check extension) otherwise never see the deadline and can burn
        // minutes of wall clock on a 200ms move.
        if (stopped)
            return 0;
        if (nodes.* -% time_check_nodes >= 2048) {
            time_check_nodes = nodes.*;
            if (now() >= hard_stop) {
                // Sticky: a plain return would unwind one ply at a time
                // (the global time_check_nodes resets the 2048 budget for
                // every ancestor), and each ancestor would re-descend into
                // fresh subtrees — an abort multiplied by the branching
                // factor per ply. stopped short-circuits every move loop.
                stopped = true;
                return 0;
            }
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
                    if (gain == 0) {
                        const ppt = stack[@intCast(ply - 1)].current_pt;
                        const pto = prev.to;
                        const v: i32 = cont_table[ppt][pto][move.to];
                        const b: i32 = depth * depth;
                        cont_table[ppt][pto][move.to] = @intCast(std.math.clamp(v + (b - @divTrunc(b * v, tun.get3(.ch_gravity))), -16000, 16000));
                    }
                }

                const hidx = [2]usize{ stm, @intFromBool(gain == 0) };
                hh_table[hidx[0]][hidx[1]][move.from][move.to] +%= depth *% depth -% @divTrunc(depth *% depth *% hh_table[hidx[0]][hidx[1]][move.from][move.to], tun.get(.hist_gravity));
                var j3: i32 = 0;
                while (j3 < num_moves_evaluated) : (j3 += 1) {
                    const prev_gain = max_material[moves_evaluated[@intCast(j3)].promo] + max_material[@intCast(pieceOn(pos, moves_evaluated[@intCast(j3)].to))];
                    const pidx = [2]usize{ stm, @intFromBool(prev_gain == 0) };
                    hh_table[pidx[0]][pidx[1]][moves_evaluated[@intCast(j3)].from][moves_evaluated[@intCast(j3)].to] -%= depth *% depth +% @divTrunc(depth *% depth *% hh_table[pidx[0]][pidx[1]][moves_evaluated[@intCast(j3)].from][moves_evaluated[@intCast(j3)].to], tun.get(.hist_gravity));
                    if (ply > 0 and prev_gain == 0) {
                        const ppt = stack[@intCast(ply - 1)].current_pt;
                        const pto = stack[@intCast(ply - 1)].current.to;
                        const mv = moves_evaluated[@intCast(j3)];
                        const v: i32 = cont_table[ppt][pto][mv.to];
                        const b: i32 = depth * depth;
                        cont_table[ppt][pto][mv.to] = @intCast(std.math.clamp(v - (b + @divTrunc(b * v, tun.get3(.ch_gravity))), -16000, 16000));
                    }
                }
                break :loop;
            }
        }

        moves_evaluated[@intCast(num_moves_evaluated)] = move;
        num_moves_evaluated += 1;
        if (gain == 0)
            num_quiets_evaluated += 1;

        // Late move pruning based on quiet move count
        if (!in_check and alpha == beta - 1 and num_quiets_evaluated > ((tun.get(.lmp_base) + depth * depth) >> @intCast(@intFromBool(!improving))))
            break :loop;
    }

    // Return mate or draw scores if no moves found
    if (best_score == -inf)
        return if (in_check) ply - mate_score else 0;

    // Save to TT (two-tier; excluded-key nodes store under their own key)
    tt.store(tt_key, best_move, tt_flag, best_score, @as(i32, @intFromBool(!in_qsearch)) * depth);

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
    const tt_entry = tt.probe(tt_key) orelse &tt.no_entry;

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
// Emergency legal move: an aborted first iteration (time hit during a
// qsearch blossom) can leave the root move unset (no_move) — never send
// that to the GUI; fall back to movegen's first legal move.
fn anyLegalMove(pos: *Position) Move {
    var moves: [256]Move = undefined;
    const n = movegen(pos, &moves, false);
    return if (n > 0) moves[0] else no_move;
}

/// Last iterativelyDeepen() results (wasm C-ABI getters read these; the
/// native UCI path ignores them — it prints info lines instead).
pub var last_score: i32 = 0;
pub var last_depth: i32 = 0;
pub var last_nodes: u64 = 0;

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
    time_check_nodes = 0;
    stop_nodes = if (limits.nodes > 0) limits.nodes else std.math.maxInt(u64);
    // Stability-scaled soft budget: an iteration that changes the best move
    // buys more time (x1.5 per change, cumulative) within the hard budget.
    var opt: i32 = allocated_time;
    var prev_best: Move = no_move;

    var score: i32 = 0;
    var i: i32 = 1;
    var completed: i32 = 0; // last depth whose aspiration search settled
    depth_loop: while (i < 128) : (i += 1) {
        if (limits.depth > 0 and i > limits.depth)
            break;
        if (nodes >= stop_nodes)
            break;
        var research: i32 = 0;
        var window: i32 = tun.get(.asp_base) + ((score * score) >> 14);
        while (true) {
            research += 1;
            const alpha = score -% window;
            const beta = score +% window;
            score = alphabeta(pos, &accs, alpha, beta, i, 0, &nodes, &stack, hash_history, hh_table, true, no_move);

            // Hard time / node limit exceeded
            if (stopped or now() >= hard_stop)
                return if (moveEq(stack[0].move, no_move)) anyLegalMove(pos) else stack[0].move;

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
                last_score = score;
                last_depth = i;
                last_nodes = nodes;
                return if (moveEq(stack[0].move, no_move)) anyLegalMove(pos) else stack[0].move;
            }

            if (score > alpha and score < beta)
                break;

            window *%= 2;
        }
        completed = i;

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
    last_score = score;
    last_depth = completed;
    last_nodes = nodes;
    return if (moveEq(stack[0].move, no_move)) anyLegalMove(pos) else stack[0].move;
}
