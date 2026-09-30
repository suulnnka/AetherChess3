// wasm 导出层:C ABI,对齐 AetherChess src/zig/engine.zig 的协议(零导入、
// 零分配,浏览器 worker 直接加载)。与 AetherChess 的差异只有引擎本体:
// 本模块背后是 AetherChess3 的 NNUE 搜索 + AetherChess 的开局谱库。
//
// 坐标/编码翻译(协议侧全部保持 AetherChess 约定,引擎侧用 A3 约定):
//   · 格子:AetherChess A8=0 ⇄ A3 a1=0,一律 sq ^ 56;
//   · 棋盘字节:AetherChess (color<<3)|(type+1)、空=0、A8 序;
//     A3 mailbox 是 color*6+type、空=0xFF、a1 序;
//   · 走法码:bit0-5 from / 6-11 to / 12-15 标志 / 16-19 被吃子型号,
//     标志语义与 AetherChess rules.zig 相同(静着0 双步2 易位2/3 吃4 EP5
//     升变6..13);
//   · 线格式(输入序列/合法着法表):(from<<6)|to,升变一律升后。
const std = @import("std");
const types = @import("types.zig");
const board = @import("board.zig");
const nnue = @import("nnue.zig");
const tt = @import("tt.zig");
const search = @import("search.zig");
const book = @import("book.zig");

const Position = types.Position;
const Move = types.Move;
const no_move = types.no_move;
const moveEq = types.moveEq;

var pos: Position = .{};
var inited = false;
var loadedCount: usize = 0;

// ---- 静态资源(全部零分配)----
var ttBuf: [1 << 18]types.TTEntry = undefined; // 512K 桶=8MB 运行时内存(零页,不增产物体积)
var hhTable = std.mem.zeroes([2][2][64][64]i32);
var histBuf: [1024]u64 = undefined; // 对局历史 + 搜索路径(512 对局上限 + 128 深度)
var hist: search.HistList = .{ .items = histBuf[0..0], .len = 0 };
var movesBuf: [256]Move = undefined;
var legalOut = [_]i32{0} ** 256; // 线格式(A8 坐标),升变只留升后
var boardOut = [_]i8{0} ** 64; // AetherChess 棋盘字节
var acc: nnue.Acc = undefined;

// state 回包事实
var legalCount: i32 = 0;
var checkOut: i32 = 0;
var overOut: i32 = 0;
var resultOut: i32 = 0;
var winnerOut: i32 = -1;
var lastNodes: u64 = 0;

fn ensureInit() void {
    if (inited) return;
    pos = .{};
    board.setupPosition(&pos); // 填 mailbox/王位/哈希(Position{} 只给位棋盘)
    board.init(); // 攻击表 + Zobrist
    nnue.init(); // 内嵌网
    tt.bindStatic(ttBuf[0..]);
    hist = .{ .items = histBuf[0..], .len = 0 };
    inited = true;
}

fn resetGame() void {
    pos = .{};
    board.setupPosition(&pos);
    search.cm_table = std.mem.zeroes([2][64][64]Move);
    search.cont_table = std.mem.zeroes([13][64][64]i16);
    hhTable = std.mem.zeroes([2][2][64][64]i32);
    @memset(tt.transposition_table, types.TTEntry{});
    hist.clear();
    loadedCount = 0;
    bookName = null;
}

// ---------- 坐标/编码 ----------
inline fn toA8(sq: u8) u8 {
    return sq ^ 56;
}
inline fn toA3(sq: u8) u8 {
    return sq ^ 56;
}

/// A3 走法 → AetherChess 完整走法码(坐标系翻转 + 标志/被吃子打包)
fn encodeMove(m: Move) i32 {
    const from8: i32 = toA8(m.from);
    const to8: i32 = toA8(m.to);
    const victimId = pos.board[m.to]; // 走子前的盘面(encode 只在走子前调用)
    const isCap = victimId != 0xFF;
    var captured: i32 = 0;
    if (isCap) captured = @as(i32, @intCast(types.idType(victimId))) + 1;
    const moverTy = types.idType(pos.board[m.from]);
    var flag: i32 = 0;
    if (m.promo != types.None) {
        // AetherChess:静升变 6..9,吃+升变 10..13,升变子 = (flag&3)+2
        flag = @as(i32, m.promo) + 5; // A3 promo 1..4(N..Q)→ Aether 6..9(N..Q)
        if (isCap) flag += 4;
    } else if (moverTy == types.King and m.from % 8 == 4 and m.from / 8 == m.to / 8 and
        (m.to % 8 == 6 or m.to % 8 == 2))
    {
        flag = if (m.to % 8 == 6) 2 else 3; // 同一横排上的 e→g / e→c = 易位
    } else if (moverTy == types.Pawn and pos.ep != 0 and
        (@as(u64, 1) << @intCast(m.to)) == pos.ep and !isCap)
    {
        flag = 5; // 吃过路兵
    } else if (moverTy == types.Pawn and
        (@as(i32, m.from) - @as(i32, m.to) == 16 or @as(i32, m.to) - @as(i32, m.from) == 16))
    {
        flag = 1; // 兵双步(同列差 16)
    } else if (isCap) {
        flag = 4;
    }
    return from8 | (to8 << 6) | (flag << 12) | (captured << 16);
}

/// (from,to)(A8 坐标)绑定到当前局面的合法着法(升变取升后;协议约定)
fn bindLine(from8: i32, to8: i32) ?Move {
    const n = board.movegen(&pos, &movesBuf, false);
    const from: u8 = @intCast(toA3(@intCast(from8 & 63)));
    const to: u8 = @intCast(toA3(@intCast(to8 & 63)));
    for (movesBuf[0..@intCast(n)]) |m| {
        if (m.from != from or m.to != to) continue;
        if (m.promo != types.None and m.promo != types.Queen) continue;
        return m;
    }
    return null;
}

// ---------- 生命周期 ----------
export fn engineInit() i32 {
    ensureInit();
    resetGame();
    return 0;
}
export fn engineNew() i32 {
    ensureInit();
    resetGame();
    return 0;
}

var inBuf = [_]i32{0} ** 512; // 输入走法序列(A8 线格式)
export fn engineMovesBuf() i32 {
    ensureInit();
    return @intCast(@intFromPtr(&inBuf));
}

/// 从初始局面重演 n 步(升变一律升后)。1=成功 0=序列非法。
/// 对局历史按 A3 UCI 同语义维护:可逆着 push 当前哈希,不可逆(兵动/吃子)
/// 清空 —— 搜索里的重复检测靠它。
export fn engineLoad(n: i32) i32 {
    ensureInit();
    pos = .{};
    board.setupPosition(&pos);
    hist.clear();
    const cnt: usize = @intCast(@max(n, 0));
    if (cnt > inBuf.len) {
        loadedCount = 0;
        return 0;
    }
    for (inBuf[0..cnt]) |line| {
        const mv = bindLine(line >> 6, line & 63) orelse {
            loadedCount = 0;
            hist.clear();
            return 0;
        };
        // 4ku quirk 保留:目标空且动子非兵 → push,否则(兵动/吃子/易位外的一切
        // 不可逆)清空。易位按原实现归入 push 分支。
        const victim = types.idType(pos.board[mv.to]);
        const mover = types.idType(pos.board[mv.from]);
        if (victim == types.None and mover != types.Pawn)
            hist.push(pos.hash)
        else
            hist.clear();
        const minfo = board.prepareMove(&pos, mv);
        _ = board.make(&pos, minfo, mv);
    }
    loadedCount = cnt;
    return 1;
}

// ---------- state ----------
fn insufficientMaterial() bool {
    var minor = [2]i32{ 0, 0 };
    for (0..64) |sq| {
        const id = pos.board[sq];
        if (id == 0xFF) continue;
        const ty = types.idType(id);
        if (ty == types.King) continue;
        if (ty == types.Pawn or ty == types.Rook or ty == types.Queen) return false;
        minor[types.idColor(id)] += 1;
    }
    return minor[0] <= 1 and minor[1] <= 1;
}

fn threefold() bool {
    var c: usize = 0;
    for (histBuf[0..hist.len]) |h| {
        if (h == pos.hash) c += 1;
    }
    return c >= 2; // 历史 2 次 + 当前 = 三次重复
}

export fn engineState() i32 {
    ensureInit();
    const n = board.movegen(&pos, &movesBuf, false);
    var w: usize = 0;
    for (movesBuf[0..@intCast(n)]) |m| {
        if (m.promo != types.None and m.promo != types.Queen) continue;
        legalOut[w] = (@as(i32, toA8(m.from)) << 6) | toA8(m.to); // 线格式 (from<<6)|to
        w += 1;
    }
    legalCount = @intCast(w);
    const stm: usize = pos.stm;
    checkOut = if (board.isAttacked(&pos, pos.king_sq[stm], stm ^ 1) != 0) 1 else 0;
    overOut = 0;
    resultOut = 0;
    winnerOut = -1;
    if (w == 0) {
        overOut = 1;
        if (checkOut == 1) {
            resultOut = 1; // 将死:行棋方负
            winnerOut = @intCast(1 - stm);
        } else {
            resultOut = 2; // 逼和
        }
    } else if (insufficientMaterial()) {
        overOut = 1;
        resultOut = 3;
    } else if (threefold()) {
        overOut = 1;
        resultOut = 4;
    }
    return 1;
}

export fn engineBoardPtr() i32 {
    ensureInit();
    for (0..64) |i| {
        const id = pos.board[i ^ 56]; // A8 序输出
        boardOut[i] = if (id == 0xFF)
            0
        else
            @intCast((types.idColor(id) << 3) | (types.idType(id) + 1));
    }
    return @intCast(@intFromPtr(&boardOut));
}
export fn engineStm() i32 {
    ensureInit();
    return pos.stm;
}
export fn engineLegalPtr() i32 {
    return @intCast(@intFromPtr(&legalOut));
}
export fn engineLegalCount() i32 {
    return legalCount;
}
export fn engineCheck() i32 {
    return checkOut;
}
export fn engineOver() i32 {
    return overOut;
}
export fn engineResult() i32 {
    return resultOut;
}
export fn engineWinner() i32 {
    return winnerOut;
}

export fn engineEvalCp() i32 {
    ensureInit();
    nnue.refreshAcc(&pos, &acc);
    return nnue.evalAcc(&pos, &acc);
}

// ---------- 搜索 ----------
export fn engineThink(depthMax: i32, nodeLimit: i32, jitter: i32, seed: i32) i32 {
    ensureInit();
    _ = jitter; // A3 搜索无 jitter 概念:难度由 depth/nodes 表达
    _ = seed;
    search.limits = .{ .depth = @max(depthMax, 0), .nodes = 0, .soft = false };
    if (nodeLimit > 0) search.limits.nodes = @intCast(nodeLimit);
    search.hard_stop = std.math.maxInt(u64); // 无墙钟:节点/深度是唯一上限
    var dummy: u64 = 0;
    const mv = search.iterativelyDeepen(&pos, &hist, &hhTable, 0, &dummy, 1 << 30, types.now());
    lastNodes = search.last_nodes; // 迭代加深内部累计(实搜节点)
    if (moveEq(mv, no_move)) return 0;
    return encodeMove(mv);
}
export fn engineScore() i32 {
    return search.last_score;
}
export fn engineDepth() i32 {
    return search.last_depth;
}
export fn engineNodesLo() i32 {
    return @bitCast(@as(u32, @truncate(lastNodes)));
}
export fn engineNodesHi() i32 {
    return @bitCast(@as(u32, @truncate(lastNodes >> 32)));
}

export fn engineBind(from: i32, to: i32) i32 {
    ensureInit();
    const mv = bindLine(from, to) orelse return 0;
    return encodeMove(mv);
}

// ---------- 开局库(协议与 AetherChess engine.zig 一致;blob/PRNG 逐位同源)----------
var bookName: ?[]const u8 = null;
var candBuf = [_]i32{0} ** (256 * 3);

export fn engineBookMove(seed: i32, lang: i32) i32 {
    ensureInit();
    bookName = null;
    const kids = book.walk(inBuf[0..loadedCount]) orelse return 0;
    const p = book.pick(kids, @bitCast(seed)) orelse return 0;
    const mv = bindLine(p.from, p.to) orelse return 0; // blob 即 A8 坐标,直接绑定
    const lg: book.Lang = if (lang != 0) .zh else .en;
    bookName = if (p.fam == book.FAM_NONE) null else book.famName(p.fam, lg);
    return encodeMove(mv);
}
export fn engineBookNamePtr() i32 {
    const nm = bookName orelse return 0;
    return @intCast(@intFromPtr(nm.ptr));
}
export fn engineBookNameLen() i32 {
    const nm = bookName orelse return 0;
    return @intCast(nm.len);
}

pub var famNameCache: ?[]const u8 = null;
export fn engineBookFamName(fam: i32, lang: i32) i32 {
    const lg: book.Lang = if (lang != 0) .zh else .en;
    const nm = book.famName(@intCast(@max(fam, 0)), lg) orelse {
        famNameCache = null;
        return 0;
    };
    famNameCache = nm;
    return @intCast(@intFromPtr(nm.ptr));
}
export fn engineBookFamNameLen() i32 {
    const nm = famNameCache orelse return 0;
    return @intCast(nm.len);
}

export fn engineBookCands() i32 {
    ensureInit();
    const kids = book.walk(inBuf[0..loadedCount]) orelse return 0;
    var out: [256]book.Cand = undefined;
    const n = book.candidates(kids, &out);
    for (0..n) |i| {
        candBuf[i * 3] = @bitCast(out[i].line);
        candBuf[i * 3 + 1] = out[i].pop;
        candBuf[i * 3 + 2] = if (out[i].fam == book.FAM_NONE) -1 else @intCast(out[i].fam);
    }
    return @intCast(n);
}
export fn engineBookCandPtr() i32 {
    return @intCast(@intFromPtr(&candBuf));
}

// ---------- perft ----------
var lastPerft: u64 = 0;
export fn enginePerft(depth: i32) i32 {
    ensureInit();
    lastPerft = board.perft(&pos, @max(depth, 0));
    return @bitCast(@as(u32, @truncate(lastPerft)));
}
export fn enginePerftHi() i32 {
    return @bitCast(@as(u32, @truncate(lastPerft >> 32)));
}
