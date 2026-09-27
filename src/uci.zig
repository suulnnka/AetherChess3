// UCI front-end: stdin tokenizer, option handling, the command loop, the
// move-application branch, and the fixed-depth bench command
// (main.cpp:1089-1331, 1110-1159).
const std = @import("std");
const linux = std.os.linux;
const types = @import("types.zig");
const board = @import("board.zig");
const nnue = @import("nnue.zig");
const tt = @import("tt.zig");
const search = @import("search.zig");
const out = @import("out.zig");

const Position = types.Position;
const Move = types.Move;
const None = types.None;
const TTEntry = types.TTEntry;
const now = types.now;

const setFen = board.setFen;
const setupPosition = board.setupPosition;
const perft = board.perft;
const movegen = board.movegen;
const pieceOn = board.pieceOn;

const evalFresh = nnue.evalFresh;

const HistList = search.HistList;
const iterativelyDeepen = search.iterativelyDeepen;

const append = out.append;
const appendInt = out.appendInt;
const appendMoveStr = out.appendMoveStr;
const flushLine = out.flushLine;

// ---------------------------------------------------------------------------
// Bench (main.cpp:1110-1159)
// ---------------------------------------------------------------------------
const BenchPos = struct { fen: []const u8, depth: i32 };

const bench_positions = [_]BenchPos{
    .{ .fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", .depth = 14 }, // Phase 24
    .{ .fen = "r1n2rk1/1pq2pp1/4bn1p/N1bpp3/4P3/3QBP2/PPP1B1PP/2KR3R w - - 0 1", .depth = 13 }, // Phase 23
    .{ .fen = "r1bq1rk1/pp2p1bp/2p3p1/1P3p2/2QPn3/6P1/PB1NPPBP/R4RK1 b - - 0 1", .depth = 14 }, // Phase 22
    .{ .fen = "r3r1k1/ppqn1p2/4bppp/8/2PB4/1P1B2b1/P1Q2PPP/R3R1K1 w - - 0 1", .depth = 14 }, // Phase 21
    .{ .fen = "r4rk1/pp3ppp/2nppq2/8/2BPb3/4P3/PP1N1PPP/R2Q1RK1 b - - 0 1", .depth = 13 }, // Phase 20
    .{ .fen = "r2q2k1/1p1r4/p4b2/2Bn2p1/4Q3/6PP/PP3P2/R2R2K1 w - - 0 1", .depth = 12 }, // Phase 19
    .{ .fen = "2bq1rk1/1pn2ppp/3p4/p2Np3/4P1P1/PN2BP2/1PP3QP/2K1b2R w - - 0 1", .depth = 15 }, // Phase 18
    .{ .fen = "2rr3k/1p3pp1/1Q2b2p/pP2p3/P1B1P3/3P2R1/5P1P/2q3NK w - - 0 1", .depth = 15 }, // Phase 17
    .{ .fen = "4k2r/3nbp1p/pqp1p3/3p2p1/3P1B2/4PPN1/PP2QP1P/2R3K1 w k - 0 1", .depth = 14 }, // Phase 16
    .{ .fen = "6k1/5p2/p3p1p1/2qnQ3/6P1/1r5P/1P2R2K/5R2 w - - 0 1", .depth = 13 }, // Phase 15
    .{ .fen = "q1b2rk1/2R1Qp1p/p5p1/1p6/1P1Np2P/P3P1P1/5P2/6K1 b - - 0 1", .depth = 15 }, // Phase 14
    .{ .fen = "6k1/3q2b1/1nNp4/3Pp1pp/4Pp2/5P2/6PP/2RQ2K1 w - - 0 1", .depth = 14 }, // Phase 13
    .{ .fen = "1r3rk1/p4p2/2p1bp1p/3Pb3/8/1P1BN3/P4PPP/4RRK1 b - - 0 1", .depth = 15 }, // Phase 12
    .{ .fen = "5b2/5k1p/4bpp1/2p5/4Pq2/3PN2P/2P2PP1/Q5K1 w - - 0 1", .depth = 13 }, // Phase 11
    .{ .fen = "3k4/2p5/p2qn3/1p1pNQ2/1P6/P6P/6P1/5K2 b - - 0 1", .depth = 14 }, // Phase 10
    .{ .fen = "r1b3k1/2p2ppp/1b6/p3N3/5B2/2P5/PP4PP/R2n1K2 b - - 0 1", .depth = 14 }, // Phase 9
    .{ .fen = "2k5/1pp2Q1p/8/8/5P2/3q4/P5K1/8 b - - 0 1", .depth = 17 }, // Phase 8
    .{ .fen = "8/1R4b1/3k4/3npp1p/3p3P/r2P1NP1/4PP2/6K1 w - - 0 1", .depth = 16 }, // Phase 7
    .{ .fen = "8/2p2p2/2Bb1kp1/R6p/P6P/r5P1/4PPK1/8 b - - 0 1", .depth = 13 }, // Phase 6
    .{ .fen = "8/5b2/pr4p1/4k2p/8/P1K3P1/7P/5R2 w - - 0 1", .depth = 15 }, // Phase 5
    .{ .fen = "8/7R/8/4p1k1/1r6/3K4/8/8 b - - 0 1", .depth = 15 }, // Phase 4
    .{ .fen = "8/8/5kp1/5p1p/4pP1P/6P1/4K3/2R3b1 b - - 0 1", .depth = 22 }, // Phase 3
    .{ .fen = "8/8/3bB3/7p/8/pK4kP/8/8 w - - 0 1", .depth = 25 }, // Phase 2
    .{ .fen = "8/5k2/P6P/5b2/P7/3p4/3K4/8 b - - 0 1", .depth = 18 }, // Phase 1
    .{ .fen = "8/8/p1Pk2pp/3p1p2/p4P2/6P1/5K1P/8 w - - 0 1", .depth = 16 }, // Phase 0
};

pub fn runBench() void {
    // Initialise the TT
    tt.allocTT(tt.num_tt_entries);

    var pos = Position{};
    var hash_history = HistList{};
    var hh_table = std.mem.zeroes([2][2][64][64]i32);
    var total_nodes: u64 = 0;

    const start_time = now();
    for (bench_positions) |bp| {
        setFen(&pos, bp.fen);
        search.limits = .{};
        search.hard_stop = now() +% (1 << 20);
        _ = iterativelyDeepen(&pos, &hash_history, &hh_table, bp.depth, &total_nodes, 1 << 20, now());
    }
    const elapsed = now() - start_time;

    append("Bench: ");
    appendInt(elapsed);
    append(" ms ");
    appendInt(total_nodes);
    append(" nodes ");
    appendInt(total_nodes * 1000 / @max(elapsed, 1));
    append(" nps\n");
    flushLine();
}

// ---------------------------------------------------------------------------
// stdin tokenizer (mirrors cin >> word / cin >> i32 semantics)
// ---------------------------------------------------------------------------
const Reader = struct {
    buf: [1 << 16]u8 = undefined,
    start: usize = 0,
    end: usize = 0,
    pending_buf: [32]u8 = undefined,
    pending_len: usize = 0,

    fn next(self: *Reader) ?[]const u8 {
        if (self.pending_len > 0) {
            const s = self.pending_buf[0..self.pending_len];
            self.pending_len = 0;
            return s;
        }
        while (true) {
            var i = self.start;
            while (i < self.end and std.ascii.isWhitespace(self.buf[i])) i += 1;
            self.start = i;
            if (i == self.end) {
                if (!self.refill()) return null;
                continue;
            }
            var j = i;
            while (j < self.end and !std.ascii.isWhitespace(self.buf[j])) j += 1;
            if (j == self.end) {
                // Token may continue past the buffer; compact and refill once.
                if (!self.refill()) {
                    const tok = self.buf[self.start..self.end];
                    self.start = self.end;
                    return tok;
                }
                continue;
            }
            const tok = self.buf[i..j];
            self.start = j;
            return tok;
        }
    }

    /// Push one already-read token back (copied; UCI command words are short).
    fn unread(self: *Reader, tok: []const u8) void {
        const n = @min(tok.len, self.pending_buf.len);
        @memcpy(self.pending_buf[0..n], tok[0..n]);
        self.pending_len = n;
    }

    /// True when the current input line has been fully consumed (UCI is a
    /// line protocol — senders write whole commands per write()).
    fn atLineEnd(self: *Reader) bool {
        var i = self.start;
        while (i < self.end and (self.buf[i] == ' ' or self.buf[i] == '\t' or self.buf[i] == '\r')) i += 1;
        return i < self.end and self.buf[i] == '\n';
    }

    fn refill(self: *Reader) bool {
        const rem = self.end - self.start;
        std.mem.copyForwards(u8, self.buf[0..rem], self.buf[self.start..self.end]);
        self.start = 0;
        self.end = rem;
        const n = linux.read(0, self.buf[rem..].ptr, self.buf.len - rem);
        const cnt: usize = @bitCast(@as(isize, @bitCast(n)));
        if (cnt == 0 or @as(isize, @bitCast(n)) <= 0) return false;
        self.end = rem + cnt;
        return true;
    }

    fn nextInt(self: *Reader, comptime T: type) ?T {
        const tok = self.next() orelse return null;
        return std.fmt.parseInt(T, tok, 10) catch null;
    }
};

// move_str comparison for the UCI move-application branch
fn movePromoEqlUci(word: []const u8, move: Move) bool {
    var buf: [5]u8 = undefined;
    buf[0] = 'a' + move.from % 8;
    buf[1] = '1' + move.from / 8;
    buf[2] = 'a' + move.to % 8;
    buf[3] = '1' + move.to / 8;
    var len: usize = 4;
    if (move.promo != None) {
        const promos = "nbrq";
        buf[4] = promos[move.promo - @as(u8, types.Knight)];
        len = 5;
    }
    return std.mem.eql(u8, word, buf[0..len]);
}

// ---------------------------------------------------------------------------
// UCI loop (main.cpp:1089-1331)
// ---------------------------------------------------------------------------
pub fn run() void {
    var pos = Position{};
    var hash_history = HistList{};
    var hh_table = std.mem.zeroes([2][2][64][64]i32);
    var reader = Reader{};

    // Wait for "uci"
    _ = reader.next();

    // Send UCI info
    append("id name AetherChess3\n");
    append("id author AetherChess\n");
    append("option name Hash type spin default ");
    appendInt(tt.num_tt_entries * @sizeOf(TTEntry) / (1024 * 1024));
    append(" min 1 max 65536\n");
    append("uciok\n");
    flushLine();

    // Initialise the TT
    tt.allocTTIfEmpty();

    while (true) {
        const word = reader.next() orelse break;
        if (std.mem.eql(u8, word, "quit")) {
            break;
        } else if (std.mem.eql(u8, word, "ucinewgame")) {
            hh_table = std.mem.zeroes([2][2][64][64]i32);
            search.cm_table = std.mem.zeroes([2][64][64]Move);
            @memset(tt.transposition_table, TTEntry{});
        } else if (std.mem.eql(u8, word, "isready")) {
            append("readyok\n");
            flushLine();
        } else if (std.mem.eql(u8, word, "setoption")) {
            _ = reader.next() orelse break; // "name"
            const opt = reader.next() orelse break;
            if (std.mem.eql(u8, opt, "Hash")) {
                var megabytes: i32 = 1;
                _ = reader.next() orelse break; // "value"
                if (reader.nextInt(i32)) |mb| {
                    megabytes = mb;
                }
                const clamped: u64 = @intCast(@max(1, @min(65536, megabytes)));
                tt.num_tt_entries = clamped * 1024 * 1024 / @sizeOf(TTEntry);
                tt.allocTT(tt.num_tt_entries);
            }
        } else if (std.mem.eql(u8, word, "go")) {
            // Full go parsing: wtime/btime/winc/binc, movetime, depth, nodes,
            // infinite (movestogo accepted and ignored, as in 4ku's spirit)
            var wtime: i64 = 0;
            var btime: i64 = 0;
            var winc: i64 = 0;
            var binc: i64 = 0;
            var movetime: i64 = 0;
            var depth_lim: i32 = 0;
            var nodes_lim: u64 = 0;
            var infinite = false;
            while (!reader.atLineEnd()) {
                const w = reader.next() orelse break;
                if (std.mem.eql(u8, w, "wtime")) {
                    wtime = reader.nextInt(i64) orelse 0;
                } else if (std.mem.eql(u8, w, "btime")) {
                    btime = reader.nextInt(i64) orelse 0;
                } else if (std.mem.eql(u8, w, "winc")) {
                    winc = reader.nextInt(i64) orelse 0;
                } else if (std.mem.eql(u8, w, "binc")) {
                    binc = reader.nextInt(i64) orelse 0;
                } else if (std.mem.eql(u8, w, "movetime")) {
                    movetime = reader.nextInt(i64) orelse 0;
                } else if (std.mem.eql(u8, w, "depth")) {
                    depth_lim = reader.nextInt(i32) orelse 0;
                } else if (std.mem.eql(u8, w, "nodes")) {
                    nodes_lim = reader.nextInt(u64) orelse 0;
                } else if (std.mem.eql(u8, w, "infinite")) {
                    infinite = true;
                } else if (std.mem.eql(u8, w, "movestogo")) {
                    _ = reader.nextInt(i32);
                } else {
                    // Not a go parameter: the next command — push it back
                    reader.unread(w);
                    break;
                }
                if (reader.atLineEnd())
                    break;
            }

            const start = now();

            // Time plan: optimum (soft base) / hard budget.
            //   clock: optimum = time/20 + 3/4 inc, hard = time/6
            //   movetime: both = movetime; depth/nodes/infinite: unlimited
            var optimum: i32 = 1 << 20;
            var hard: i64 = 1 << 30;
            var soft = false;
            if (movetime > 0) {
                optimum = @intCast(movetime);
                hard = movetime;
            } else if (!infinite and depth_lim == 0 and nodes_lim == 0) {
                const t = if (pos.stm == 1) btime else wtime;
                const inc = if (pos.stm == 1) binc else winc;
                if (t > 0) {
                    soft = true;
                    optimum = @intCast(@max(1, @divTrunc(t, 20) + @divTrunc(inc * 3, 4)));
                    hard = @max(1, @min(@divTrunc(t, 6), t - 30));
                }
            }
            search.limits = .{ .depth = depth_lim, .nodes = nodes_lim, .soft = soft };
            search.hard_stop = start +% @as(u64, @intCast(hard));

            var dummy_nodes: u64 = 0;
            const best_move = iterativelyDeepen(&pos, &hash_history, &hh_table, 0, &dummy_nodes, optimum, start);
            append("bestmove ");
            appendMoveStr(best_move);
            append("\n");
            flushLine();
        } else if (std.mem.eql(u8, word, "position")) {
            // Set to startpos
            pos = Position{};
            hash_history.clear();

            var fen: [128]u8 = undefined;
            var fen_len: usize = 0;
            var fen_size: i32 = 0;

            // Try collect FEN string
            while (fen_size < 6) {
                const tok = reader.next() orelse break;
                if (std.mem.eql(u8, tok, "moves") or std.mem.eql(u8, tok, "startpos"))
                    break;
                if (!std.mem.eql(u8, tok, "fen")) {
                    if (fen_len == 0) {
                        @memcpy(fen[0..tok.len], tok);
                        fen_len = tok.len;
                    } else {
                        fen[fen_len] = ' ';
                        @memcpy(fen[fen_len + 1 ..][0..tok.len], tok);
                        fen_len += 1 + tok.len;
                    }
                    fen_size += 1;
                }
            }

            if (fen_len > 0)
                setFen(&pos, fen[0..fen_len])
            else
                setupPosition(&pos); // startpos reset: rebuild derived state
        } else if (std.mem.eql(u8, word, "perft")) {
            const depth = reader.nextInt(i32) orelse 0;
            const t0 = now();
            const nodes = perft(&pos, depth);
            const dt = now() - t0;
            append("info");
            append(" depth ");
            appendInt(depth);
            append(" nodes ");
            appendInt(nodes);
            append(" time ");
            appendInt(dt);
            if (dt > 0) {
                append(" nps ");
                appendInt(1000 * nodes / dt);
            }
            append("\n");
            append("nodes ");
            appendInt(nodes);
            append("\n");
            flushLine();
        } else if (std.mem.eql(u8, word, "dhash")) {
            // Debug extension: not present in 4ku; used for port verification only.
            appendInt(pos.hash);
            append("\n");
            flushLine();
        } else if (std.mem.eql(u8, word, "deval")) {
            // Debug extension: not present in 4ku; used for port verification only.
            appendInt(evalFresh(&pos));
            append("\n");
            flushLine();
        } else if (std.mem.eql(u8, word, "dmoves")) {
            // Debug extension: not present in 4ku; used for port verification only.
            var moves: [256]Move = undefined;
            const num_moves = movegen(&pos, &moves, false);
            for (moves[0..@intCast(num_moves)]) |m| {
                append(" ");
                appendMoveStr(m);
            }
            append("\n");
            flushLine();
        } else {
            var moves: [256]Move = undefined;
            const num_moves = movegen(&pos, &moves, false);
            for (moves[0..@intCast(num_moves)]) |move| {
                if (movePromoEqlUci(word, move)) {
                    // C++ quirk preserved: piece_on() is used as a truthy int,
                    // so a Pawn (index 0) counts as false here.
                    if (pieceOn(&pos, move.to) == None and pieceOn(&pos, move.from) != 0)
                        hash_history.push(pos.hash)
                    else
                        hash_history.clear();

                    const minfo = board.prepareMove(&pos, move);
                    _ = board.make(&pos, minfo, move);
                    break;
                }
            }
        }
    }
}
