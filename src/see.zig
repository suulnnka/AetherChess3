// Static exchange evaluation — swap algorithm with incremental x-ray
// reveals, ported from AetherChess2's bug-fixed see.rs (one attackers_to up
// front, then each removal only opens the ray behind the removed piece).
const types = @import("types.zig");
const board = @import("board.zig");

const Position = types.Position;
const Move = types.Move;
const Pawn = types.Pawn;
const Knight = types.Knight;
const Bishop = types.Bishop;
const Rook = types.Rook;
const Queen = types.Queen;
const King = types.King;

// SEE piece values (AetherChess2 scale — the pruning thresholds in search
// are tuned against these).
pub const piece_val = [6]i32{ 100, 320, 330, 500, 900, 20000 };

inline fn bit(s: u8) u64 {
    return @as(u64, 1) << @as(u6, @intCast(s));
}

const Pick = struct { sq: u8, ty: usize };

fn lvaIndex(pos: *const Position, attackers: u64, side: usize) ?Pick {
    const types_order = [6]usize{ Pawn, Knight, Bishop, Rook, Queen, King };
    inline for (types_order) |ty| {
        const b = attackers & pos.colour[side] & pos.pieces[ty];
        if (b != 0) return .{ .sq = @intCast(@ctz(b)), .ty = ty };
    }
    return null;
}

/// All pieces of `side` attacking `to` under the given occupancy.
fn attackersTo(pos: *const Position, to: u8, occ: u64, side: usize) u64 {
    const tb = bit(to);
    const pawns = pos.colour[side] & pos.pieces[Pawn];
    // white pawns attack `to` from sw/se of it, black from nw/ne
    var a = if (side == 0) (board.sw(tb) | board.se(tb)) & pawns else (board.nw(tb) | board.ne(tb)) & pawns;
    a |= pos.colour[side] & pos.pieces[Knight] & board.knight(to, 0);
    a |= pos.colour[side] & (pos.pieces[Bishop] | pos.pieces[Queen]) & board.bishop(to, occ);
    a |= pos.colour[side] & (pos.pieces[Rook] | pos.pieces[Queen]) & board.rook(to, occ);
    a |= pos.colour[side] & pos.pieces[King] & board.king(to, 0);
    return a;
}

/// Attackers of `to` revealed on the ray through the just-removed `sq`;
/// non-aligned removals (knight / adjacent pawn / king) reveal nothing.
fn xrayBehind(pos: *const Position, occ: u64, to: u8, sq: u8) u64 {
    const tf: i32 = @as(i32, to % 8);
    const tr: i32 = @as(i32, to / 8);
    const sf: i32 = @as(i32, sq % 8);
    const sr: i32 = @as(i32, sq / 8);
    const df = sf - tf;
    const dr = sr - tr;
    if (!(df == 0 or dr == 0 or df * df == dr * dr))
        return 0;
    const stepf: i32 = if (df > 0) 1 else if (df < 0) -1 else 0;
    const stepr: i32 = if (dr > 0) 1 else if (dr < 0) -1 else 0;
    var f = sf + stepf;
    var r = sr + stepr;
    while (f >= 0 and f < 8 and r >= 0 and r < 8) {
        const s: u8 = @intCast(r * 8 + f);
        const b = bit(s);
        if (occ & b != 0) {
            const t = types.idType(pos.board[s]);
            const diag = stepf != 0 and stepr != 0;
            if ((diag and (t == Bishop or t == Queen)) or (!diag and (t == Rook or t == Queen)))
                return b;
            return 0;
        }
        f += stepf;
        r += stepr;
    }
    return 0;
}

pub fn see(pos: *const Position, move: Move) i32 {
    const from = move.from;
    const to = move.to;

    const from_ty = types.idType(pos.board[from]);
    const is_ep = pos.board[to] == 0xFF and pos.ep != 0 and bit(to) == pos.ep and from_ty == Pawn;

    var occ = (pos.colour[0] | pos.colour[1]) & ~bit(from);
    var gain: [32]i32 = undefined;

    const victim0: usize = if (is_ep) Pawn else types.idType(pos.board[to]);
    gain[0] = piece_val[victim0];
    if (move.promo != types.None)
        gain[0] += piece_val[move.promo] - piece_val[Pawn];
    var attacker_ty = from_ty;
    var side: usize = pos.stm ^ 1;

    var attackers = attackersTo(pos, to, occ, 0) | attackersTo(pos, to, occ, 1);

    var d: usize = 0;
    while (d < 31) {
        const pick = lvaIndex(pos, attackers, side) orelse break;
        d += 1;
        gain[d] = piece_val[attacker_ty] - gain[d - 1];
        if (d == 1 and move.promo != types.None)
            gain[d] += piece_val[move.promo] - piece_val[Pawn];
        attacker_ty = pick.ty;
        occ &= ~bit(pick.sq);
        attackers &= ~bit(pick.sq);
        attackers |= xrayBehind(pos, occ, to, pick.sq);
        side ^= 1;
    }
    while (d > 0) {
        gain[d - 1] = -@max(-gain[d - 1], gain[d]);
        d -= 1;
    }
    return gain[0];
}
