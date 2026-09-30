// 开局谱库(AetherChess 移植,2026-09-30):blob 与游走/加权抽取逻辑与
// AetherChess src/zig/book.zig 逐位一致(含 Mulberry32 内联副本,保证同种子
// 同选着);坐标系为 AetherChess 的 A8=0,wasm 层负责 ^56 翻译到本引擎的 a1=0。
// blob 由 AetherChess 的 tools/gen-book.mjs 生成,单一事实源在 AetherChess。
// 二进制开局谱库(zig 通道)。blob 由 tools/gen-book.mjs 从 src/book.js
// (单一事实源:ECO 谱树 + 族名表)生成,布局见该脚本头注释:
//   名字区(u16 count + 每族 u16 len + UTF-8)→ u32 nodeCount → u8 rootKids
//   → 前序节点,每个 6 字节(from, to, w16, fam(255=无名), nKids)。
//
// 设计要点:
//   · **零拷贝零分配**:直接在 blob 字节上按偏移游走,头部名字偏移表首次
//     使用时建一次(静态数组)。blob 本体 @embedFile 进 wasm 数据段。
//   · 前序布局下"找兄弟"要跳子树:skipTree 用递归,深度 = 谱树深度
//     (实测 ≤ 36),栈开销可忽略;整树游走一次的完整性由 selftest 校验。
//   · 节点是变长的(3B 起步,fam 是可选第 4 字节):跳子树/下钻都要按
//     flags 的 hasFam 位步进,见 nodeSize。
//   · 语义与 JS 版 book.js 对齐的部分:walk 按线序列(from,to)逐层匹配;
//     名字取**被选中的着法所在节点**的 fam —— 即"这步棋进入了哪个开局族",
//     与 bookResponse 的 name 口径一致。**有意近似**的部分:权重等比量化
//     成 2 位流行度档,档位权 1:10:100:1000(n=10,全谱拟合,根分布几乎
//     无损);legacy_js 的 JS 版用精确谱线数,两边开局分布近似而非逐位相同。
const std = @import("std");

// Mulberry32 — verbatim copy of AetherChess rules.zig's PRNG so book picks
// stay bit-identical to the AetherChess wasm for the same seed.
pub const Mulberry32 = struct {
    s: u32,
    pub fn next(m: *Mulberry32) u32 {
        m.s +%= 0x6D2B79F5;
        var t: u32 = m.s ^ (m.s >> 15);
        t *%= 1 | m.s;
        const t2: u32 = t ^ (t >> 7);
        t = (t +% (t2 *% (61 | t))) ^ t;
        return t ^ (t >> 14);
    }
};

pub const blob = @embedFile("book.bin");

pub const FAM_NONE: u16 = 0xFFFF;

var famEnOff: [255]u32 = undefined; // 每族英文名的字节偏移(名字区解析一次)
var famEnLen: [255]u16 = undefined;
var famZhOff: [255]u32 = undefined; // 每族中文名的字节偏移
var famZhLen: [255]u16 = undefined;

/// 族名语言(blob 每族存英/中两条 UTF-8)
pub const Lang = enum(u8) { en = 0, zh = 1 };
var nodesBase: usize = 0;
var rootKidsV: u8 = 0;
var famCountV: u16 = 0;
var inited = false;

inline fn rd16(off: usize) u16 {
    return @as(u16, blob[off]) | (@as(u16, blob[off + 1]) << 8);
}
inline fn rd32(off: usize) u32 {
    return @as(u32, blob[off]) | (@as(u32, blob[off + 1]) << 8) | (@as(u32, blob[off + 2]) << 16) | (@as(u32, blob[off + 3]) << 24);
}

fn init() void {
    if (inited) return;
    var off: usize = 2;
    const n = rd16(0);
    for (0..n) |i| {
        const enLen = rd16(off);
        famEnOff[i] = @intCast(off + 2);
        famEnLen[i] = enLen;
        off += 2 + enLen;
        const zhLen = rd16(off);
        famZhOff[i] = @intCast(off + 2);
        famZhLen[i] = zhLen;
        off += 2 + zhLen;
    }
    // off 此刻指向 nodeCount(u32),其后是 rootKids,再后是首个节点
    nodesBase = off + 5;
    rootKidsV = blob[off + 4];
    famCountV = n;
    inited = true;
}

pub fn famCount() u16 {
    init();
    return famCountV;
}
pub fn nodeCount() u32 {
    init();
    return rd32(nodesBase - 5);
}
pub fn rootKids() u8 {
    init();
    return rootKidsV;
}

/// 族下标 → 指定语言的族名(fam ≥ famCount 或 255 → null,对应"无名谱着")
pub fn famName(fam: u16, lang: Lang) ?[]const u8 {
    init();
    if (fam == 255 or fam >= famCountV) return null;
    const i: usize = fam;
    return switch (lang) {
        .en => blob[famEnOff[i]..][0..famEnLen[i]],
        .zh => blob[famZhOff[i]..][0..famZhLen[i]],
    };
}

pub const Node = struct {
    from: u8,
    to: u8,
    fam: u8, // 255 = 无名(且该字节在 blob 里不存在)
    pop: u2, // 流行度档,采样权 = POP_LEVELS[pop]
    nKids: u5,
};

/// 流行度档位权(与 tools/gen-book.mjs 的 POP_N 拟合结论同步)
pub const POP_LEVELS = [4]u32{ 1, 10, 100, 1000 };

pub fn nodeAt(off: usize) Node {
    const flags = blob[off + 2];
    return .{
        .from = blob[off],
        .to = blob[off + 1],
        .fam = if (flags & 0x80 != 0) blob[off + 3] else 255,
        .pop = @truncate((flags >> 5) & 3),
        .nKids = @truncate(flags & 31),
    };
}

/// 节点字节数:fam 可选字节(84% 的节点无名,3B;带名 4B)
inline fn nodeSize(fam: u8) usize {
    return if (fam == 255) 3 else 4;
}

/// 跳过一个节点(头在 off)的整棵子树,返回子树结束后的偏移
fn skipTree(off: usize, nKids: u8) usize {
    var o = off;
    for (0..nKids) |_| {
        const n = nodeAt(o);
        o = skipTree(o + nodeSize(n.fam), n.nKids);
    }
    return o;
}

/// 一个节点的孩子区(孩子节点头连续排列,兄弟间靠 skipTree 推进)
pub const Kids = struct {
    start: usize,
    count: u8,
    pub fn empty(self: Kids) bool {
        return self.count == 0;
    }
};

/// 按线序列 (from<<6|to) 从根走到谱内节点,返回其孩子区;
/// 序列任一步不在谱内 → null(JS bookResponse 的"无谱可循")。
pub fn walk(seq: []const i32) ?Kids {
    init();
    var kids = Kids{ .start = nodesBase, .count = rootKidsV };
    for (seq) |line| {
        const u: u32 = @bitCast(line);
        const from: u8 = @truncate(u >> 6);
        const to: u8 = @truncate(u & 63);
        var off = kids.start;
        var found: ?usize = null;
        var foundNode: Node = undefined;
        for (0..kids.count) |_| {
            const n = nodeAt(off);
            if (n.from == from and n.to == to) {
                found = off;
                foundNode = n;
                break;
            }
            off = skipTree(off + nodeSize(n.fam), n.nKids);
        }
        const f = found orelse return null;
        kids = .{ .start = f + nodeSize(foundNode.fam), .count = foundNode.nKids };
    }
    return kids;
}

pub const Cand = struct {
    line: u32, // (from<<6)|to
    pop: u8, // 流行度档 0..3(探针按同一量化公式与 JS 的 w 对拍)
    fam: u16, // FAM_NONE = 无名
};

/// 枚举孩子区全部候选(顺序 = blob 内兄弟顺序 = JS Object.entries 顺序)
pub fn candidates(kids: Kids, out: []Cand) usize {
    var off = kids.start;
    for (0..kids.count) |i| {
        const n = nodeAt(off);
        out[i] = .{
            .line = (@as(u32, n.from) << 6) | n.to,
            .pop = n.pop,
            .fam = if (n.fam == 255) FAM_NONE else n.fam,
        };
        off = skipTree(off + nodeSize(n.fam), n.nKids);
    }
    return kids.count;
}

pub const Pick = struct {
    from: u8,
    to: u8,
    fam: u16, // FAM_NONE = 无名
};

/// 按流行度档位加权随机抽一个孩子(权 = POP_LEVELS[pop];种子由调用方
/// 播种。与 legacy_js 的精确权重抽样近似而非逐位相同,见文件头)
pub fn pick(kids: Kids, seed: u32) ?Pick {
    if (kids.count == 0) return null;
    var sum: u32 = 0;
    {
        var off = kids.start;
        for (0..kids.count) |_| {
            const n = nodeAt(off);
            sum += POP_LEVELS[n.pop];
            off = skipTree(off + nodeSize(n.fam), n.nKids);
        }
    }
    if (sum == 0) return null;
    var prng = Mulberry32{ .s = seed };
    var t: i64 = @intCast(prng.next() % sum);
    var off = kids.start;
    for (0..kids.count) |_| {
        const n = nodeAt(off);
        t -= POP_LEVELS[n.pop];
        if (t < 0) return .{ .from = n.from, .to = n.to, .fam = if (n.fam == 255) FAM_NONE else n.fam };
        off = skipTree(off + nodeSize(n.fam), n.nKids);
    }
    // 取模边界兜底(理论到不了):取最后一个孩子
    off = kids.start;
    for (0..kids.count - 1) |_| {
        const n = nodeAt(off);
        off = skipTree(off + nodeSize(n.fam), n.nKids);
    }
    const last = nodeAt(off);
    return .{ .from = last.from, .to = last.to, .fam = if (last.fam == 255) FAM_NONE else last.fam };
}

/// 结构完整性:根孩子的子树首尾相接拼起来必须恰好耗尽 blob
/// (前序布局串得对不对、生成器与解析器对 6 字节节点的理解一致,一次验完)
pub fn verifyIntegrity() bool {
    init();
    var off = nodesBase;
    for (0..rootKidsV) |_| {
        const n = nodeAt(off);
        off = skipTree(off + nodeSize(n.fam), n.nKids);
    }
    // 允许尾部 padding(当前生成器不加,留余量)
    return off == blob.len;
}
