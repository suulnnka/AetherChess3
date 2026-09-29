// Transposition table: 16-byte entries in two-tier buckets — slot [0] is
// depth-preferred (a shallower store spills to slot [1], the always-replace
// tier), so deep entries survive the churn that verification searches and
// iterative deepening create (main.cpp:110-117, 1110-1121).
const types = @import("types.zig");

const TTEntry = types.TTEntry;
const Move = types.Move;
const page_alloc = types.page_alloc;

pub var num_tt_entries: u64 = 64 << 16; // total entries (two per bucket)
pub var transposition_table: []TTEntry = &.{};
pub var no_entry = TTEntry{}; // stand-in for a miss (key 0)

pub fn allocTT(entries: u64) void {
    if (transposition_table.len > 0)
        page_alloc.free(transposition_table);
    transposition_table = page_alloc.alloc(TTEntry, @intCast(entries)) catch @panic("oom");
    @memset(transposition_table, TTEntry{});
}

pub fn allocTTIfEmpty() void {
    if (transposition_table.len == 0)
        allocTT(num_tt_entries);
}

inline fn buckets() u64 {
    return transposition_table.len / 2;
}

/// Slot for the key: depth-preferred first, then always-replace.
pub fn probe(key: u64) ?*TTEntry {
    const b = key % buckets();
    const d = &transposition_table[@intCast(b * 2)];
    if (d.key == key)
        return d;
    const r = &transposition_table[@intCast(b * 2 + 1)];
    if (r.key == key)
        return r;
    return null;
}

/// Two-tier store: the same key or a depth >= the depth-tier entry takes
/// slot [0] (demoting the old depth entry to the replace tier); a shallower
/// store for a different position spills to the replace tier, so deep
/// entries survive the churn of verification searches and iterative
/// deepening.
pub fn store(key: u64, move: Move, flag: u8, score: i32, depth: i32) void {
    const b = key % buckets();
    const d = &transposition_table[@intCast(b * 2)];
    const r = &transposition_table[@intCast(b * 2 + 1)];
    const e = TTEntry{
        .key = key,
        .move = move,
        .flag = flag,
        .score = @truncate(score),
        .depth = @truncate(depth),
    };
    if (d.key == key or depth >= d.depth) {
        r.* = d.*;
        d.* = e;
    } else {
        r.* = e;
    }
}
