// Search tunables: the 4ku-inherited constants exposed for SPSA tuning via
// the A3_SEARCH_PARAMS environment variable — a comma-separated list of
// numbers in `params` order. Values are rounded to i32 and clamped to the
// per-param bounds; anything unparsable or of the wrong count falls back to
// the 4ku defaults (which keep the bench bit-identical at 3,534,745 nodes).
const std = @import("std");

pub const Param = struct { name: []const u8, def: i32, lo: i32, hi: i32 };

pub const Id = enum(usize) {
    rfp_margin, // reverse futility: static_eval - margin*(depth-improving) >= beta
    rfp_max_depth, // RFP only below this depth
    razoring, // static_eval + razoring*depth < alpha -> drop into qsearch
    qs_delta, // qsearch delta pruning margin
    ffp_margin, // forward futility: static_eval + margin*depth + gain < alpha
    ffp_max_depth, // FFP only below this depth
    nmp_base, // null depth = depth - base - depth/nmp_div - min(eval-beta)/nmp_eval_div, nmp_cap)
    nmp_div,
    nmp_eval_div,
    nmp_cap,
    lmr_move_div, // LMR reduction = moves/lmr_move_div + depth/lmr_depth_div + ...
    lmr_depth_div,
    hist_gravity, // history update divisor (depth*depth*hist/gravity)
    lmp_base, // quiet-move count limit = (base + depth*depth) >> !improving
    asp_base, // aspiration window base (window = base + score^2/16384)
};

const defs = [_]Param{
    .{ .name = "rfp_margin", .def = 71, .lo = 30, .hi = 140 },
    .{ .name = "rfp_max_depth", .def = 8, .lo = 4, .hi = 12 },
    .{ .name = "razoring", .def = 238, .lo = 100, .hi = 450 },
    .{ .name = "qs_delta", .def = 50, .lo = 0, .hi = 120 },
    .{ .name = "ffp_margin", .def = 105, .lo = 40, .hi = 220 },
    .{ .name = "ffp_max_depth", .def = 8, .lo = 3, .hi = 12 },
    .{ .name = "nmp_base", .def = 4, .lo = 2, .hi = 7 },
    .{ .name = "nmp_div", .def = 5, .lo = 3, .hi = 8 },
    .{ .name = "nmp_eval_div", .def = 196, .lo = 80, .hi = 400 },
    .{ .name = "nmp_cap", .def = 3, .lo = 1, .hi = 6 },
    .{ .name = "lmr_move_div", .def = 13, .lo = 8, .hi = 22 },
    .{ .name = "lmr_depth_div", .def = 14, .lo = 8, .hi = 24 },
    .{ .name = "hist_gravity", .def = 512, .lo = 256, .hi = 1024 },
    .{ .name = "lmp_base", .def = 1, .lo = 0, .hi = 4 },
    .{ .name = "asp_base", .def = 28, .lo = 10, .hi = 80 },
};

// Current values (defaults until init() overrides them from the env).
pub var val = blk: {
    var v: [defs.len]i32 = undefined;
    for (&v, &defs) |*x, p| x.* = p.def;
    break :blk v;
};

pub inline fn get(id: Id) i32 {
    return val[@intFromEnum(id)];
}

/// Scan the process environment for A3_SEARCH_PARAMS ("v1,v2,..." in
/// `defs` order). On any malformed input the whole set stays/becomes the
/// defaults — never a partial mix.
pub fn init(environ: std.process.Environ) void {
    if (@TypeOf(environ.block) != std.process.Environ.PosixBlock)
        return; // freestanding/WASM: no env, defaults apply
    for (environ.block.view().slice) |entry| {
        const kv = std.mem.span(entry);
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        if (std.mem.eql(u8, kv[0..eq], "A3_SEARCH_PARAMS")) {
            parseSpec(kv[eq + 1 ..]);
            return;
        }
    }
}

fn parseSpec(spec: []const u8) void {
    var it = std.mem.splitScalar(u8, spec, ',');
    var parsed: [defs.len]i32 = undefined;
    var n: usize = 0;
    while (it.next()) |tok| {
        if (n >= defs.len)
            return; // too many values: keep defaults
        const f = std.fmt.parseFloat(f64, std.mem.trim(u8, tok, " ")) catch return;
        const lo: f64 = @floatFromInt(defs[n].lo);
        const hi: f64 = @floatFromInt(defs[n].hi);
        parsed[n] = @intFromFloat(@round(@min(@max(f, lo), hi)));
        n += 1;
    }
    if (n == defs.len)
        val = parsed;
}
