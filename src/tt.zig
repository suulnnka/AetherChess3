// Transposition table: 16-byte entries, always-replace
// (main.cpp:110-117, 1110-1121).
const types = @import("types.zig");

const TTEntry = types.TTEntry;
const page_alloc = types.page_alloc;

pub var num_tt_entries: u64 = 64 << 16; // The first value is the size in megabytes
pub var transposition_table: []TTEntry = &.{};

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
