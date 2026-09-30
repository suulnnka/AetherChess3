// Shared constants, core data types, and small utilities.
const std = @import("std");
const linux = std.os.linux;

// ---------------------------------------------------------------------------
// Constants (main.cpp:39-52)
// ---------------------------------------------------------------------------
pub const mate_score: i32 = 30000;
pub const inf: i32 = 32000;

pub const Pawn: usize = 0;
pub const Knight: usize = 1;
pub const Bishop: usize = 2;
pub const Rook: usize = 3;
pub const Queen: usize = 4;
pub const King: usize = 5;
pub const None: usize = 6;

// Static eval using the TT and TT cutoffs rely on this specific ordering, do not change it.
pub const Upper: u8 = 0;
pub const Lower: u8 = 1;
pub const Exact: u8 = 2;

// ---------------------------------------------------------------------------
// Types (main.cpp:60-108). Absolute-coordinate board (no POV flipping):
// colour[0] is always White, colour[1] always Black; stm is the side to move.
// The NNUE accumulators and cached king squares live in the position so they
// are cloned along with it and updated incrementally by makemove.
// ---------------------------------------------------------------------------
pub const Position = struct {
    castling: [4]i32 = .{ 1, 1, 1, 1 }, // [0] White O-O, [1] White O-O-O, [2] Black O-O, [3] Black O-O-O
    colour: [2]u64 = .{ 0xFFFF, 0xFFFF000000000000 }, // absolute: [0] White, [1] Black
    pieces: [6]u64 = .{
        0xFF00000000FF00,
        0x4200000000000042,
        0x2400000000000024,
        0x8100000000000081,
        0x800000000000008,
        0x1000000000000010,
    },
    ep: u64 = 0, // absolute en-passant target square bit
    stm: u8 = 0, // side to move: 0 White, 1 Black
    halfmove: u16 = 0, // plies since last pawn move / capture (50-move rule)
    king_sq: [2]u8 = .{ 4, 60 },
    board: [64]u8 = [_]u8{0xFF} ** 64, // mailbox: piece id (color*6+type), 0xFF empty
    hash: u64 = 0, // incremental Zobrist hash (maintained by make/unmake)
};

pub inline fn idColor(id: u8) usize {
    return id / 6;
}

pub inline fn idType(id: u8) usize {
    return id % 6;
}

pub const Move = extern struct {
    from: u8 = 0,
    to: u8 = 0,
    promo: u8 = 0,
};

pub const no_move = Move{};

pub fn moveEq(lhs: Move, rhs: Move) bool {
    return lhs.from == rhs.from and lhs.to == rhs.to and lhs.promo == rhs.promo;
}

pub const Stack = struct {
    moves: [256]Move = undefined,
    moves_evaluated: [256]Move = undefined,
    move_scores: [256]i32 = undefined,
    move: Move = no_move,
    killer: Move = no_move,
    current: Move = no_move, // move currently being searched at this ply
    se_ext: bool = false, // this line already used a singular extension (no back-to-back)
    current_pt: u8 = 0, // mover piece id (color*6+type) of `current` (conthist context)
    score: i32 = 0,
};

pub const TTEntry = extern struct {
    key: u64 = 0,
    move: Move = no_move,
    flag: u8 = 0,
    score: i16 = 0,
    depth: i16 = 0,
};

comptime {
    std.debug.assert(@sizeOf(Move) == 3);
    std.debug.assert(@sizeOf(TTEntry) == 16);
}

// ---------------------------------------------------------------------------
// Time (main.cpp:54-58) — CLOCK_MONOTONIC in ms, computed in f64 like C++
// ---------------------------------------------------------------------------
pub fn now() u64 {
    if (@import("builtin").target.cpu.arch == .wasm32)
        return 0; // freestanding wasm has no wall clock; callers use node/depth limits
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
    const v = @as(f64, @floatFromInt(ts.sec)) * 1000.0 + @as(f64, @floatFromInt(ts.nsec)) / 1e6;
    return @intFromFloat(@trunc(v));
}

pub const page_alloc = std.heap.page_allocator;
