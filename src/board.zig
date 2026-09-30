// Board representation, attack generation, movegen, make/unmake (board only,
// in place — the NNUE accumulators live on a per-ply stack in the search),
// FEN, perft, and Zobrist hashing. Absolute coordinates: colour[0] = White,
// colour[1] = Black, stm = side to move.
const std = @import("std");
const types = @import("types.zig");

const Position = types.Position;
const Move = types.Move;
const Pawn = types.Pawn;
const Knight = types.Knight;
const Bishop = types.Bishop;
const Rook = types.Rook;
const Queen = types.Queen;
const King = types.King;
const None = types.None;

// ---------------------------------------------------------------------------
// Globals (main.cpp:110-117)
// ---------------------------------------------------------------------------
pub var diag_mask: [64]u64 = undefined;
pub var keys: [848]u64 = undefined;

// ---------------------------------------------------------------------------
// Bit utilities (main.cpp:119-210)
// ---------------------------------------------------------------------------
pub inline fn flipU64(bb: u64) u64 {
    return @byteSwap(bb);
}

pub inline fn lsb(bb: u64) i32 {
    return @ctz(bb);
}

pub inline fn count(bb: u64) i32 {
    return @popCount(bb);
}

pub inline fn west(bb: u64) u64 {
    return bb >> 1 & ~@as(u64, 0x8080808080808080);
}

pub inline fn east(bb: u64) u64 {
    return bb << 1 & ~@as(u64, 0x101010101010101);
}

pub inline fn north(bb: u64) u64 {
    return bb << 8;
}

pub inline fn south(bb: u64) u64 {
    return bb >> 8;
}

pub inline fn nw(bb: u64) u64 {
    return north(west(bb));
}

pub inline fn ne(bb: u64) u64 {
    return north(east(bb));
}

pub inline fn sw(bb: u64) u64 {
    return south(west(bb));
}

pub inline fn se(bb: u64) u64 {
    return south(east(bb));
}

inline fn ray(sq: i32, blockers: u64, comptime f: *const fn (u64) callconv(.@"inline") u64) u64 {
    @setEvalBranchQuota(100000);
    var mask = f(@as(u64, 1) << @intCast(sq));
    var i: u32 = 0;
    while (i < 6) : (i += 1)
        mask |= f(mask & ~blockers);
    return mask;
}

inline fn xattack(sq: i32, blockers: u64, dir_mask: u64) u64 {
    const bm = blockers & dir_mask;
    const sm = @as(u64, 1) << @intCast(sq);
    return dir_mask & ((bm -% sm) ^ flipU64(flipU64(bm) -% flipU64(sm)));
}

pub inline fn bishop(sq: i32, blockers: u64) u64 {
    return xattack(sq, blockers, diag_mask[@intCast(sq)]) |
        xattack(sq, blockers, flipU64(diag_mask[@intCast(sq ^ 56)]));
}

pub inline fn rook(sq: i32, blockers: u64) u64 {
    const dir = (@as(u64, 1) << @intCast(sq)) ^ (@as(u64, 0x101010101010101) << @intCast(@mod(sq, 8)));
    return xattack(sq, blockers, dir) | ray(sq, blockers, east) | ray(sq, blockers, west);
}

pub inline fn knight(sq: i32, _: u64) u64 {
    const bb = @as(u64, 1) << @intCast(sq);
    // NB: Zig gives &, ^, | the same precedence (unlike C++), so every
    // masked term is parenthesized explicitly.
    return ((bb << 15 | bb >> 17) & ~@as(u64, 0x8080808080808080)) |
        ((bb << 17 | bb >> 15) & ~@as(u64, 0x101010101010101)) |
        ((bb << 10 | bb >> 6) & 0xFCFCFCFCFCFCFCFC) |
        ((bb << 6 | bb >> 10) & 0x3F3F3F3F3F3F3F3F);
}

pub inline fn king(sq: i32, _: u64) u64 {
    const bb = @as(u64, 1) << @intCast(sq);
    return (bb << 8) | (bb >> 8) |
        ((bb >> 1 | bb >> 9 | bb << 7) & ~@as(u64, 0x8080808080808080)) |
        ((bb << 1 | bb << 9 | bb >> 7) & ~@as(u64, 0x101010101010101));
}

// ---------------------------------------------------------------------------
// Move / position helpers (main.cpp:212-265)
// ---------------------------------------------------------------------------
pub inline fn pieceOn(pos: *const Position, sq: u8) i32 {
    const id = pos.board[sq];
    return if (id == 0xFF) @intCast(None) else @intCast(types.idType(id));
}

// attacker is an absolute colour index (0 White, 1 Black)
pub fn isAttacked(pos: *const Position, sq: i32, attacker: usize) i32 {
    const bb = @as(u64, 1) << @intCast(sq);
    const pawns = pos.colour[attacker] & pos.pieces[Pawn];
    const pawn_attacks = if (attacker == 1) sw(pawns) | se(pawns) else nw(pawns) | ne(pawns);
    if (pawn_attacks & bb != 0) return 1;
    if (pos.colour[attacker] & pos.pieces[Knight] & knight(sq, 0) != 0) return 1;
    if (bishop(sq, pos.colour[0] | pos.colour[1]) & pos.colour[attacker] & (pos.pieces[Bishop] | pos.pieces[Queen]) != 0) return 1;
    if (rook(sq, pos.colour[0] | pos.colour[1]) & pos.colour[attacker] & (pos.pieces[Rook] | pos.pieces[Queen]) != 0) return 1;
    if (king(sq, pos.colour[0] | pos.colour[1]) & pos.colour[attacker] & pos.pieces[King] != 0) return 1;
    return 0;
}

// ---------------------------------------------------------------------------
// make / unmake (main.cpp:267-347) — board mutated in place; the caller
// keeps the NNUE accumulator stack (copy-make, never unmade).
// ---------------------------------------------------------------------------

/// Everything needed to apply a move, gathered from the PRE-move position.
pub const MoveInfo = struct {
    us: usize,
    piece: usize,
    ty_to: usize,
    from: u8,
    to: u8,
    victim_ty: usize, // None if no capture (ep victim carries Pawn)
    victim_sq: u8,
    rook: [2]u8, // {0,0} when not castling
    mf_pre: [2]bool, // pre-move NNUE mirror flags
};

/// State saved to reverse a move exactly.
pub const Undo = struct {
    from_id: u8, // piece id on 'from' before the move (handles promotions)
    captured_id: u8, // 0xFF if none (en-passant victim is derived, not here)
    ep: u64,
    castling: u8, // packed [0]..[3] bits
    hash: u64,
    halfmove: u16,
};

inline fn mirrorFlagsB(pos: *const Position) [2]bool {
    return .{ pos.king_sq[0] % 8 > 3, pos.king_sq[1] % 8 < 4 };
}

pub fn prepareMove(pos: *const Position, move: Move) MoveInfo {
    const us: usize = pos.stm;
    const to_bit = @as(u64, 1) << @as(u6, @intCast(move.to));

    const piece: usize = types.idType(pos.board[move.from]);
    const captured: usize = if (pos.board[move.to] == 0xFF) None else types.idType(pos.board[move.to]);

    var victim_ty: usize = None;
    var victim_sq: u8 = 0;
    if (captured != None) {
        victim_ty = captured;
        victim_sq = move.to;
    } else if (piece == Pawn and pos.ep != 0 and to_bit == pos.ep) {
        victim_ty = Pawn;
        victim_sq = if (us == 0) move.to - 8 else move.to + 8;
    }
    const ty_to: usize = if (piece == Pawn and move.promo != None) move.promo else piece;
    var rook_mv = [2]u8{ 0, 0 };
    if (piece == King) {
        const diff = @as(i32, move.to) - @as(i32, move.from);
        if (us == 0) {
            if (diff == 2) rook_mv = .{ 7, 5 } else if (diff == -2) rook_mv = .{ 0, 3 };
        } else {
            if (diff == 2) rook_mv = .{ 63, 61 } else if (diff == -2) rook_mv = .{ 56, 59 };
        }
    }
    return .{
        .us = us,
        .piece = piece,
        .ty_to = ty_to,
        .from = move.from,
        .to = move.to,
        .victim_ty = victim_ty,
        .victim_sq = victim_sq,
        .rook = rook_mv,
        .mf_pre = mirrorFlagsB(pos),
    };
}

pub fn make(pos: *Position, info: MoveInfo, move: Move) Undo {
    const from_bit = @as(u64, 1) << @as(u6, @intCast(move.from));
    const to_bit = @as(u64, 1) << @as(u6, @intCast(move.to));
    const mask = from_bit | to_bit;

    const us = info.us;
    const them = us ^ 1;
    const piece = info.piece;
    const old_perm = castlingPerm(pos);
    const old_ep = pos.ep;

    const undo = Undo{
        .from_id = pos.board[move.from],
        .captured_id = pos.board[move.to],
        .ep = old_ep,
        .castling = @intCast(pos.castling[0] | pos.castling[1] << 1 | pos.castling[2] << 2 | pos.castling[3] << 3),
        .hash = pos.hash,
        .halfmove = pos.halfmove,
    };

    // Move the piece
    pos.colour[us] ^= mask;
    pos.pieces[piece] ^= mask;
    pos.board[move.from] = 0xFF;
    pos.board[move.to] = @intCast(us * 6 + info.ty_to);

    // Captures
    if (undo.captured_id != 0xFF) {
        pos.colour[them] ^= to_bit;
        pos.pieces[types.idType(undo.captured_id)] ^= to_bit;
    }

    // En passant
    if (info.victim_ty == Pawn and undo.captured_id == 0xFF) {
        const vbit = @as(u64, 1) << @as(u6, @intCast(info.victim_sq));
        pos.colour[them] ^= vbit;
        pos.pieces[Pawn] ^= vbit;
        pos.board[info.victim_sq] = 0xFF;
    }

    pos.ep = 0;

    // Pawn double move
    if (piece == Pawn) {
        const d = @as(i32, move.to) - @as(i32, move.from);
        if (d == 16)
            pos.ep = to_bit >> 8
        else if (d == -16)
            pos.ep = to_bit << 8;
    }

    // Castling
    if (piece == King) {
        const diff = @as(i32, move.to) - @as(i32, move.from);
        const rmask: u64 = if (us == 0)
            (if (diff == 2) @as(u64, 0xa0) else if (diff == -2) @as(u64, 0x9) else 0)
        else
            (if (diff == 2) @as(u64, 0xa000000000000000) else if (diff == -2) @as(u64, 0x0900000000000000) else 0);
        pos.colour[us] ^= rmask;
        pos.pieces[Rook] ^= rmask;
        if (info.rook[0] != info.rook[1]) {
            pos.board[info.rook[0]] = 0xFF;
            pos.board[info.rook[1]] = @intCast(us * 6 + Rook);
        }
        pos.king_sq[us] = move.to;
    }

    // Promotions
    if (piece == Pawn and move.promo != None) {
        pos.pieces[Pawn] ^= to_bit;
        pos.pieces[move.promo] ^= to_bit;
    }

    // Update castling permissions (absolute masks)
    pos.castling[0] &= @intFromBool(mask & 0x90 == 0);
    pos.castling[1] &= @intFromBool(mask & 0x11 == 0);
    pos.castling[2] &= @intFromBool(mask & 0x9000000000000000 == 0);
    pos.castling[3] &= @intFromBool(mask & 0x1100000000000000 == 0);

    pos.stm = @intCast(them);

    // 50-move clock: reset on any pawn move or capture (EP included), +1 else
    pos.halfmove = if (piece == Pawn or info.victim_ty != None) 0 else pos.halfmove + 1;

    // Incremental Zobrist update (piece move, victim, castling rook,
    // ep square change, castling-rights change, stm)
    pos.hash ^= 1;
    pos.hash ^= keyOf(us, piece, move.from) ^ keyOf(us, info.ty_to, move.to);
    if (info.victim_ty != None)
        pos.hash ^= keyOf(them, info.victim_ty, info.victim_sq);
    if (info.rook[0] != info.rook[1])
        pos.hash ^= keyOf(us, Rook, info.rook[0]) ^ keyOf(us, Rook, info.rook[1]);
    if (old_ep != 0)
        pos.hash ^= keys[768 + @as(usize, @intCast(lsb(old_ep)))];
    if (pos.ep != 0)
        pos.hash ^= keys[768 + @as(usize, @intCast(lsb(pos.ep)))];
    pos.hash ^= keys[832 + old_perm] ^ keys[832 + castlingPerm(pos)];

    return undo;
}

pub fn unmake(pos: *Position, move: Move, undo: Undo) void {
    const from_bit = @as(u64, 1) << @as(u6, @intCast(move.from));
    const to_bit = @as(u64, 1) << @as(u6, @intCast(move.to));
    const mask = from_bit | to_bit;

    const us: usize = pos.stm ^ 1; // the mover
    const them: usize = pos.stm;
    const ty_from_orig = types.idType(undo.from_id);
    const ty_at_to = types.idType(pos.board[move.to]); // promo type after make

    // Move the piece back
    pos.colour[us] ^= mask;
    pos.pieces[ty_at_to] ^= to_bit;
    pos.pieces[ty_from_orig] ^= from_bit;
    pos.board[move.from] = undo.from_id;

    // Capture / en-passant restore
    if (undo.captured_id != 0xFF) {
        pos.colour[them] ^= to_bit;
        pos.pieces[types.idType(undo.captured_id)] ^= to_bit;
        pos.board[move.to] = undo.captured_id;
    } else {
        pos.board[move.to] = 0xFF;
        if (ty_from_orig == Pawn) {
            const d = @as(i32, move.to) - @as(i32, move.from);
            if (d == 7 or d == 9 or d == -7 or d == -9) {
                // diagonal pawn move to an empty square: en passant
                const vsq: u8 = if (us == 0) move.to - 8 else move.to + 8;
                const vbit = @as(u64, 1) << @as(u6, @intCast(vsq));
                pos.colour[them] ^= vbit;
                pos.pieces[Pawn] ^= vbit;
                pos.board[vsq] = @intCast(them * 6 + Pawn);
            }
        }
    }

    // Castling rook restore
    if (ty_from_orig == King) {
        const diff = @as(i32, move.to) - @as(i32, move.from);
        if (diff == 2 or diff == -2) {
            const rmask: u64 = if (us == 0)
                (if (diff == 2) @as(u64, 0xa0) else @as(u64, 0x9))
            else
                (if (diff == 2) @as(u64, 0xa000000000000000) else @as(u64, 0x0900000000000000));
            pos.colour[us] ^= rmask;
            pos.pieces[Rook] ^= rmask;
            const rfrom: u8 = if (us == 0) (if (diff == 2) 7 else 0) else (if (diff == 2) 63 else 56);
            const rto: u8 = if (us == 0) (if (diff == 2) 5 else 3) else (if (diff == 2) 61 else 59);
            pos.board[rfrom] = @intCast(us * 6 + Rook);
            pos.board[rto] = 0xFF;
        }
        pos.king_sq[us] = move.from;
    }

    pos.stm = @intCast(us);
    pos.ep = undo.ep;
    pos.halfmove = undo.halfmove;
    pos.castling = .{
        undo.castling & 1,
        (undo.castling >> 1) & 1,
        (undo.castling >> 2) & 1,
        (undo.castling >> 3) & 1,
    };
    pos.hash = undo.hash;
}

// ---------------------------------------------------------------------------
// Movegen (main.cpp:349-416) — fully LEGAL generation via checkmask/pinmask:
// the king's checkers and pinned pieces are computed once per call, and every
// generated move already satisfies the check and pin constraints, so callers
// never need a post-make legality scan. EP captures keep their position in
// the generation order (inside the capture groups) and get an exact
// double-removal discovered-check test.
// ---------------------------------------------------------------------------

/// Squares strictly between two aligned squares (0 when not aligned).
/// Squares strictly between two aligned squares (0 when not aligned).
/// Runtime-built like diag_mask (rank/file/diagonal/anti-diagonal aligned).
var between: [64][64]u64 = undefined;

fn buildBetween() void {
    for (0..64) |a| {
        for (0..64) |b| {
            const ra: i32 = @intCast(a >> 3);
            const fa: i32 = @intCast(a & 7);
            const rb: i32 = @intCast(b >> 3);
            const fb: i32 = @intCast(b & 7);
            const dr = rb - ra;
            const df = fb - fa;
            var m: u64 = 0;
            if ((dr == 0 and df != 0) or (df == 0 and dr != 0) or (dr != 0 and df != 0 and dr * dr == df * df)) {
                const sr: i32 = if (dr > 0) 1 else if (dr < 0) -1 else 0;
                const sf: i32 = if (df > 0) 1 else if (df < 0) -1 else 0;
                const step = sr * 8 + sf;
                var sq: i32 = @as(i32, @intCast(a)) + step;
                while (sq != @as(i32, @intCast(b))) : (sq += step)
                    m |= @as(u64, 1) << @intCast(sq);
            }
            between[a][b] = m;
        }
    }
}

const EpCheck = struct {
    to: u8, // ep target square
    victim_bit: u64,
    all: u64,
    ksq: i32,
    rq: u64, // enemy rooks|queens
    bq: u64, // enemy bishops|queens
};

inline fn genPawns(
    movelist: *[256]Move,
    num_moves: *i32,
    to_mask_in: u64,
    offset: i32,
    black: bool,
    pinned: u64,
    pin_masks: *const [64]u64,
    ep: ?EpCheck,
) void {
    var to_mask = to_mask_in;
    while (to_mask != 0) {
        const to: u8 = @intCast(lsb(to_mask));
        to_mask &= to_mask - 1;
        const from: u8 = @intCast(@as(i32, to) + offset);
        const from_bit = @as(u64, 1) << @as(u6, @intCast(from));
        const to_bit = @as(u64, 1) << @as(u6, @intCast(to));
        if ((pinned & from_bit) != 0 and (pin_masks[from] & to_bit) == 0)
            continue;
        if (ep) |e| {
            if (to == e.to) {
                // exact double-removal test: no enemy slider sees the king
                // with both pawns gone and ours landed on the ep square
                const occ_after = (e.all ^ from_bit ^ e.victim_bit) | to_bit;
                if (rook(e.ksq, occ_after) & e.rq != 0)
                    continue;
                if (bishop(e.ksq, occ_after) & e.bq != 0)
                    continue;
            }
        }
        if (if (black) to < 8 else to > 55) {
            movelist[@intCast(num_moves.*)] = .{ .from = from, .to = to, .promo = @intCast(Queen) };
            num_moves.* += 1;
            movelist[@intCast(num_moves.*)] = .{ .from = from, .to = to, .promo = @intCast(Rook) };
            num_moves.* += 1;
            movelist[@intCast(num_moves.*)] = .{ .from = from, .to = to, .promo = @intCast(Bishop) };
            num_moves.* += 1;
            movelist[@intCast(num_moves.*)] = .{ .from = from, .to = to, .promo = @intCast(Knight) };
            num_moves.* += 1;
        } else {
            movelist[@intCast(num_moves.*)] = .{ .from = from, .to = to, .promo = @intCast(None) };
            num_moves.* += 1;
        }
    }
}

inline fn generatePieceMoves(
    movelist: *[256]Move,
    num_moves: *i32,
    pos: *const Position,
    piece: usize,
    to_mask: u64,
    comptime f: *const fn (i32, u64) callconv(.@"inline") u64,
    pinned: u64,
    pin_masks: *const [64]u64,
) void {
    const us: usize = pos.stm;
    const all = pos.colour[0] | pos.colour[1];
    var copy = pos.colour[us] & pos.pieces[piece];
    while (copy != 0) {
        const fr = lsb(copy);
        copy &= copy - 1;
        var moves = f(fr, all) & to_mask;
        if ((pinned & (@as(u64, 1) << @as(u6, @intCast(fr)))) != 0)
            moves &= pin_masks[@intCast(fr)];
        while (moves != 0) {
            const to = lsb(moves);
            moves &= moves - 1;
            movelist[@intCast(num_moves.*)] = .{ .from = @intCast(fr), .to = @intCast(to), .promo = @intCast(None) };
            num_moves.* += 1;
        }
    }
}

pub fn movegen(pos: *const Position, movelist: *[256]Move, only_captures: bool) i32 {
    var num_moves: i32 = 0;
    const us: usize = pos.stm;
    const them: usize = us ^ 1;
    const all = pos.colour[0] | pos.colour[1];
    const own = pos.colour[us];
    const their = pos.colour[them];
    const ksq: i32 = pos.king_sq[us];
    const king_bit = @as(u64, 1) << @as(u6, @intCast(ksq));

    const their_p = their & pos.pieces[Pawn];
    const their_n = their & pos.pieces[Knight];
    const their_bq = their & (pos.pieces[Bishop] | pos.pieces[Queen]);
    const their_rq = their & (pos.pieces[Rook] | pos.pieces[Queen]);

    // Checkers and check mask (squares that capture/block the single checker;
    // 0 when double-checked: only king moves are legal)
    const checkers = (knight(ksq, 0) & their_n) |
        // their pawn checks our king: shift the KING to the squares an
        // attacking pawn would stand on (opposite of the pawn-attack shift)
        ((if (them == 1) nw(king_bit) | ne(king_bit) else sw(king_bit) | se(king_bit)) & their_p) |
        (bishop(ksq, all) & their_bq) |
        (rook(ksq, all) & their_rq);
    const nch: i32 = @popCount(checkers);
    var checkmask: u64 = 0;
    if (nch == 0)
        checkmask = ~@as(u64, 0)
    else if (nch == 1)
        checkmask = checkers | between[@intCast(ksq)][@intCast(@ctz(checkers))];

    // Pins: enemy sliders that would attack the king through exactly one of
    // our pieces (x-ray with only enemy pieces as blockers).
    var pin_masks: [64]u64 = undefined; // valid only for squares in `pinned`
    var pinned: u64 = 0;
    {
        const snipers = (bishop(ksq, their) & their_bq) | (rook(ksq, their) & their_rq);
        var s = snipers;
        while (s != 0) {
            const ssq: usize = @intCast(@ctz(s));
            s &= s - 1;
            const line = between[@intCast(ksq)][ssq];
            const blockers = line & all;
            if (@popCount(blockers) == 1 and (blockers & own) != 0) {
                pinned |= blockers;
                // allowed squares: the whole pin line plus the pinner itself
                pin_masks[@intCast(@ctz(blockers))] = line | (@as(u64, 1) << @as(u6, @intCast(ssq)));
            }
        }
    }

    // Pawns (pushes filtered to promotions in qsearch; captures include the
    // ep target, which genPawns validates exactly). An ep capture can only
    // resolve a check by capturing the checking pawn or blocking with its
    // landing square — both covered by the check mask.
    const pawns = own & pos.pieces[Pawn];
    var ep_target_mask: u64 = 0;
    var ep_check: ?EpCheck = null;
    if (pos.ep != 0) {
        const epsq: u8 = @intCast(@ctz(pos.ep));
        const vsq: i32 = if (us == 0) @as(i32, epsq) - 8 else @as(i32, epsq) + 8;
        const vbit = @as(u64, 1) << @as(u6, @intCast(vsq));
        if ((checkmask & (pos.ep | vbit)) != 0) {
            ep_target_mask = pos.ep;
            ep_check = .{ .to = epsq, .victim_bit = vbit, .all = all, .ksq = ksq, .rq = their_rq, .bq = their_bq };
        }
    }

    if (us == 0) {
        genPawns(movelist, &num_moves, north(pawns) & ~all & checkmask & (if (only_captures) @as(u64, 0xFF00000000000000) else ~@as(u64, 0)), -8, false, pinned, &pin_masks, ep_check);
        if (!only_captures)
            genPawns(movelist, &num_moves, north(north(pawns & 0xFF00) & ~all) & ~all & checkmask, -16, false, pinned, &pin_masks, ep_check);
        genPawns(movelist, &num_moves, nw(pawns) & ((their & checkmask) | ep_target_mask), -7, false, pinned, &pin_masks, ep_check);
        genPawns(movelist, &num_moves, ne(pawns) & ((their & checkmask) | ep_target_mask), -9, false, pinned, &pin_masks, ep_check);
    } else {
        genPawns(movelist, &num_moves, south(pawns) & ~all & checkmask & (if (only_captures) @as(u64, 0xFF) else ~@as(u64, 0)), 8, true, pinned, &pin_masks, ep_check);
        if (!only_captures)
            genPawns(movelist, &num_moves, south(south(pawns & 0x00FF000000000000) & ~all) & ~all & checkmask, 16, true, pinned, &pin_masks, ep_check);
        genPawns(movelist, &num_moves, sw(pawns) & ((their & checkmask) | ep_target_mask), 9, true, pinned, &pin_masks, ep_check);
        genPawns(movelist, &num_moves, se(pawns) & ((their & checkmask) | ep_target_mask), 7, true, pinned, &pin_masks, ep_check);
    }

    const piece_to_mask = (if (only_captures) their else ~own) & checkmask;
    generatePieceMoves(movelist, &num_moves, pos, Knight, piece_to_mask, knight, pinned, &pin_masks);
    generatePieceMoves(movelist, &num_moves, pos, Bishop, piece_to_mask, bishop, pinned, &pin_masks);
    generatePieceMoves(movelist, &num_moves, pos, Rook, piece_to_mask, rook, pinned, &pin_masks);
    generatePieceMoves(movelist, &num_moves, pos, Queen, piece_to_mask, rook, pinned, &pin_masks);
    generatePieceMoves(movelist, &num_moves, pos, Queen, piece_to_mask, bishop, pinned, &pin_masks);

    // King: exclude squares attacked with our king removed from occupancy
    {
        const occ_nk = all ^ king_bit;
        var danger: u64 = if (them == 1) sw(their_p) | se(their_p) else nw(their_p) | ne(their_p);
        var bbs = their_n;
        while (bbs != 0) {
            danger |= knight(lsb(bbs), 0);
            bbs &= bbs - 1;
        }
        bbs = their_bq;
        while (bbs != 0) {
            danger |= bishop(lsb(bbs), occ_nk);
            bbs &= bbs - 1;
        }
        bbs = their_rq;
        while (bbs != 0) {
            danger |= rook(lsb(bbs), occ_nk);
            bbs &= bbs - 1;
        }
        danger |= king(pos.king_sq[them], 0);

        var moves = king(ksq, 0) & ~own & ~danger & (if (only_captures) their else ~@as(u64, 0));
        while (moves != 0) {
            const to = lsb(moves);
            moves &= moves - 1;
            movelist[@intCast(num_moves)] = .{ .from = @intCast(ksq), .to = @intCast(to), .promo = @intCast(None) };
            num_moves += 1;
        }
    }

    // Castling: rights, empty path, and king start/cross/landing squares all
    // unattacked (landing included — generation is legal, no post-check)
    if (!only_captures) {
        if (us == 0) {
            if (pos.castling[0] != 0 and all & 0x60 == 0 and isAttacked(pos, 4, 1) == 0 and isAttacked(pos, 5, 1) == 0 and isAttacked(pos, 6, 1) == 0) {
                movelist[@intCast(num_moves)] = .{ .from = 4, .to = 6, .promo = @intCast(None) };
                num_moves += 1;
            }
            if (pos.castling[1] != 0 and all & 0xE == 0 and isAttacked(pos, 4, 1) == 0 and isAttacked(pos, 3, 1) == 0 and isAttacked(pos, 2, 1) == 0) {
                movelist[@intCast(num_moves)] = .{ .from = 4, .to = 2, .promo = @intCast(None) };
                num_moves += 1;
            }
        } else {
            if (pos.castling[2] != 0 and all & 0x6000000000000000 == 0 and isAttacked(pos, 60, 0) == 0 and isAttacked(pos, 61, 0) == 0 and isAttacked(pos, 62, 0) == 0) {
                movelist[@intCast(num_moves)] = .{ .from = 60, .to = 62, .promo = @intCast(None) };
                num_moves += 1;
            }
            if (pos.castling[3] != 0 and all & 0x0E00000000000000 == 0 and isAttacked(pos, 60, 0) == 0 and isAttacked(pos, 59, 0) == 0 and isAttacked(pos, 58, 0) == 0) {
                movelist[@intCast(num_moves)] = .{ .from = 60, .to = 58, .promo = @intCast(None) };
                num_moves += 1;
            }
        }
    }
    return num_moves;
}

// ---------------------------------------------------------------------------
// Zobrist hashing. Key layout: white piece p at sq -> keys[p*64 + sq], black
// piece p at sq -> keys[p*64 + sq + 384], ep square -> keys[768 + sq],
// castling permutation -> keys[832 + perm]; the stm contributes the low bit
// of the seed. Colour-fixed absolute rows so the hash is maintained
// incrementally by make/unmake.
// ---------------------------------------------------------------------------
inline fn keyOf(color: usize, ty: usize, sq: u8) u64 {
    return keys[color * 384 + ty * 64 + sq];
}

inline fn castlingPerm(pos: *const Position) usize {
    return @intCast(pos.castling[0] + pos.castling[1] * 2 + pos.castling[2] * 4 + pos.castling[3] * 8);
}

pub fn getHash(pos: *const Position) u64 {
    var hash: u64 = pos.stm;

    for (0..6) |ty| {
        var copy = pos.pieces[ty] & pos.colour[0];
        while (copy != 0) {
            const sq: u8 = @intCast(lsb(copy));
            copy &= copy - 1;
            hash ^= keyOf(0, ty, sq);
        }
        copy = pos.pieces[ty] & pos.colour[1];
        while (copy != 0) {
            const sq: u8 = @intCast(lsb(copy));
            copy &= copy - 1;
            hash ^= keyOf(1, ty, sq);
        }
    }

    // En passant square
    if (pos.ep != 0)
        hash ^= keys[768 + @as(usize, @intCast(lsb(pos.ep)))];

    // Castling permissions
    hash ^= keys[832 + castlingPerm(pos)];

    return hash;
}

/// Recompute all derived board state (king squares, mailbox, hash) after
/// building a position from scratch (FEN parse / startpos reset). The NNUE
/// accumulators are rebuilt separately by the search setup.
pub fn setupPosition(pos: *Position) void {
    pos.king_sq = .{
        @intCast(lsb(pos.colour[0] & pos.pieces[King])),
        @intCast(lsb(pos.colour[1] & pos.pieces[King])),
    };
    @memset(&pos.board, 0xFF); // pos may carry stale mailbox entries from a previous position
    for (0..6) |ty| {
        var bb = pos.pieces[ty];
        while (bb != 0) {
            const sq: u8 = @intCast(lsb(bb));
            bb &= bb - 1;
            const bit = @as(u64, 1) << @as(u6, @intCast(sq));
            pos.board[sq] = @intCast(@as(usize, @intFromBool(pos.colour[1] & bit != 0)) * 6 + ty);
        }
    }
    pos.hash = getHash(pos);
}

// ---------------------------------------------------------------------------
// FEN (main.cpp:1005-1063) — absolute squares, stm field
// ---------------------------------------------------------------------------
pub fn setFen(pos: *Position, fen: []const u8) void {
    if (std.mem.eql(u8, fen, "startpos")) {
        pos.* = Position{};
        setupPosition(pos);
        return;
    }

    // Clear
    pos.colour = .{ 0, 0 };
    pos.pieces = .{ 0, 0, 0, 0, 0, 0 };
    pos.castling = .{ 0, 0, 0, 0 };
    pos.ep = 0;
    pos.stm = 0;
    pos.halfmove = 0;

    var it = std.mem.tokenizeAny(u8, fen, " \t");
    const board = it.next() orelse return;
    var i: i32 = 56;
    for (board) |ch| {
        if (ch >= '1' and ch <= '8') {
            i += @as(i32, ch - '1') + 1;
        } else if (ch == '/') {
            i -= 16;
        } else {
            const side: usize = @intFromBool(ch == 'p' or ch == 'n' or ch == 'b' or ch == 'r' or ch == 'q' or ch == 'k');
            const piece: usize = if (ch == 'p' or ch == 'P') Pawn else if (ch == 'n' or ch == 'N') Knight else if (ch == 'b' or ch == 'B') Bishop else if (ch == 'r' or ch == 'R') Rook else if (ch == 'q' or ch == 'Q') Queen else King;
            pos.colour[side] ^= @as(u64, 1) << @intCast(i);
            pos.pieces[piece] ^= @as(u64, 1) << @intCast(i);
            i += 1;
        }
    }

    // Side to move
    const side_tok = it.next() orelse {
        setupPosition(pos);
        return;
    };
    pos.stm = @intFromBool(std.mem.eql(u8, side_tok, "b"));

    // Castling permissions
    if (it.next()) |cast| {
        for (cast) |ch| {
            pos.castling[0] |= @intFromBool(ch == 'K');
            pos.castling[1] |= @intFromBool(ch == 'Q');
            pos.castling[2] |= @intFromBool(ch == 'k');
            pos.castling[3] |= @intFromBool(ch == 'q');
        }
    }

    // En passant (absolute)
    if (it.next()) |ep_tok| {
        if (!std.mem.eql(u8, ep_tok, "-") and ep_tok.len >= 2) {
            const sq = @as(i32, ep_tok[0] - 'a') + 8 * @as(i32, ep_tok[1] - '1');
            pos.ep = @as(u64, 1) << @intCast(sq);
        }
    }

    // Halfmove clock (FEN field 5; the fullmove number after it is ignored)
    if (it.next()) |hm_tok| {
        if (std.fmt.parseInt(u16, hm_tok, 10)) |hm| {
            pos.halfmove = hm;
        } else |_| {}
    }

    setupPosition(pos);
}

// ---------------------------------------------------------------------------
// Perft (main.cpp:1067-1086) — make/unmake in place
// ---------------------------------------------------------------------------
pub fn perft(pos: *Position, depth: i32) u64 {
    if (depth == 0)
        return 1;

    var nodes: u64 = 0;
    var moves: [256]Move = undefined;
    const num_moves = movegen(pos, &moves, false);

    for (moves[0..@intCast(num_moves)]) |move| {
        const info = prepareMove(pos, move);
        const undo = make(pos, info, move);
        nodes += perft(pos, depth - 1);
        unmake(pos, move, undo);
    }

    return nodes;
}

// ---------------------------------------------------------------------------
// mt19937_64 (std::mt19937_64 default-seeded, main.cpp:1101-1104)
// ---------------------------------------------------------------------------
pub const MT19937_64 = struct {
    mt: [312]u64 = undefined,
    idx: usize = 312,

    fn seed(self: *MT19937_64, seed_val: u64) void {
        self.mt[0] = seed_val;
        var i: usize = 1;
        while (i < 312) : (i += 1) {
            self.mt[i] = 6364136223846793005 *% (self.mt[i - 1] ^ (self.mt[i - 1] >> 62)) +% i;
        }
        self.idx = 312;
    }

    fn next(self: *MT19937_64) u64 {
        if (self.idx == 312) {
            var i: usize = 0;
            while (i < 312) : (i += 1) {
                const x = (self.mt[i] & 0xFFFFFFFF80000000) | (self.mt[(i + 1) % 312] & 0x7FFFFFFF);
                var xa = x >> 1;
                if (x & 1 != 0)
                    xa ^= 0xB5026F5AA96619E9;
                self.mt[i] = self.mt[(i + 156) % 312] ^ xa;
            }
            self.idx = 0;
        }
        var y = self.mt[self.idx];
        self.idx += 1;
        y ^= (y >> 29) & 0x5555555555555555;
        y ^= (y << 17) & 0x71D67FFFEDA60000;
        // libstdc++ uses a LEFT shift here (differs from reference mt19937-64.c)
        y ^= (y << 37) & 0xFFF7EEE000000000;
        y ^= y >> 43;
        return y;
    }
};

// Generate the attack masks, between table, and Zobrist keys (once from main).
pub fn init() void {
    for (0..64) |i| {
        diag_mask[i] = ray(@intCast(i), 0, ne) | ray(@intCast(i), 0, sw);
    }
    buildBetween();

    var mt = MT19937_64{};
    mt.seed(5489);
    for (&keys) |*k|
        k.* = mt.next();
}
