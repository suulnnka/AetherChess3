// SEE sanity test for the empty-target (quiet move) fix. Run from the
// AetherChess3 directory:  zig test src/see_test.zig
const std = @import("std");
const board = @import("board.zig");
const see = @import("see.zig");
const types = @import("types.zig");

fn mkMove(from: u8, to: u8) types.Move {
    return .{ .from = from, .to = to, .promo = 6 }; // promo = None
}

test "quiet moves start the exchange at 0" {
    board.init();
    var pos = types.Position{};

    // Nb1-c3, hung to black pawn b4, no recapture: SEE = -320.
    // (The old phantom code read the empty target as a rook and returned +180.)
    board.setFen(&pos, "8/8/8/8/1p6/8/8/1N2K2k w - - 0 1");
    try std.testing.expectEqual(@as(i32, -320), see.see(&pos, mkMove(1, 18)));

    // Qd1-d4, hung to black pawn c5, no recapture: SEE = -900.
    board.setFen(&pos, "8/8/8/2p5/8/8/8/3QK2k w - - 0 1");
    try std.testing.expectEqual(@as(i32, -900), see.see(&pos, mkMove(3, 27)));

    // Rg1-g3, no enemy attacker at all: SEE = 0.
    board.setFen(&pos, "6k1/8/8/8/8/8/8/6RK w - - 0 1");
    try std.testing.expectEqual(@as(i32, 0), see.see(&pos, mkMove(6, 22)));
}

test "captures keep the classic swap values" {
    board.init();
    var pos = types.Position{};

    // Qxd5 undefended pawn: +100.
    board.setFen(&pos, "8/8/8/3p4/8/8/8/3QK2k w - - 0 1");
    try std.testing.expectEqual(@as(i32, 100), see.see(&pos, mkMove(3, 35)));

    // Qxd5 defended by c6/e6 pawns: 100 - 900 = -800.
    board.setFen(&pos, "8/8/2ppp3/3p4/8/8/8/3QK2k w - - 0 1");
    try std.testing.expectEqual(@as(i32, -800), see.see(&pos, mkMove(3, 35)));

    // Rxd5 pawn defended by pawn e6, no white follow-up: 100 - 500 = -400.
    board.setFen(&pos, "6k1/8/4p3/3p4/8/8/8/R3K3 w - - 0 1");
    try std.testing.expectEqual(@as(i32, -400), see.see(&pos, mkMove(0, 35)));
}
