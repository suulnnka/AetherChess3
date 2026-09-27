// AetherChess3 — Zig engine that started as a bit-exact port of 4ku
// (kz04px, MIT, commit 917a087) and now evolves independently.
//
// Modules: types.zig (constants/core types), board.zig (bitboards, movegen,
// makemove, FEN, perft, hashing), nnue.zig (v7 NNUE eval, embedded net),
// tt.zig (transposition table), search.zig (alphabeta, iterative deepening),
// uci.zig (protocol front-end + bench), out.zig (output buffer).
// The 4ku HCE was replaced by AetherChess2's v7_s1_D NNUE net.
const std = @import("std");
const board = @import("board.zig");
const nnue = @import("nnue.zig");
const uci = @import("uci.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    // Generate used attack masks and Zobrist keys, load the NNUE net
    board.init();
    nnue.init();

    // argv bench
    {
        var args = std.process.Args.Iterator.init(init.args);
        _ = args.next();
        if (args.next()) |a1| {
            if (std.mem.eql(u8, a1, "bench")) {
                uci.runBench();
                return;
            }
        }
    }

    uci.run();
}
