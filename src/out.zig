// Output helpers (buffered writes to stdout)
const std = @import("std");
const linux = std.os.linux;
const types = @import("types.zig");

const Move = types.Move;
const None = types.None;
const Knight = types.Knight;

var line_buf: [16384]u8 = undefined;
var line_len: usize = 0;

pub fn flushLine() void {
    if (line_len > 0) {
        posixWrite(line_buf[0..line_len]);
        line_len = 0;
    }
}

fn posixWrite(bytes: []const u8) void {
    if (@import("builtin").target.cpu.arch == .wasm32)
        return; // wasm build has no stdout consumer; search output is discarded
    var off: usize = 0;
    while (off < bytes.len) {
        const n = linux.write(1, bytes.ptr + off, bytes.len - off);
        if (@as(isize, @bitCast(n)) <= 0) return;
        off += n;
    }
}

pub fn append(str: []const u8) void {
    @memcpy(line_buf[line_len..][0..str.len], str);
    line_len += str.len;
}

pub fn appendInt(v: anytype) void {
    // Hand-rolled integer formatting (4ku heritage) — std.fmt.bufPrint drags
    // ~1-2KB of formatting machinery into the wasm closure for lines that are
    // discarded there anyway.
    var tmp: [24]u8 = undefined;
    var n: usize = 0;
    var mag: u64 = 0;
    var neg = false;
    if (@typeInfo(@TypeOf(v)).int.signedness == .signed) {
        if (v < 0) {
            neg = true;
            mag = @intCast(-@as(i64, v));
        } else mag = @intCast(v);
    } else mag = @intCast(v);
    while (true) {
        tmp[n] = @intCast('0' + mag % 10);
        n += 1;
        mag /= 10;
        if (mag == 0) break;
    }
    if (neg) append("-");
    while (n > 0) {
        n -= 1;
        append(tmp[n .. n + 1]);
    }
}

pub fn appendMoveStr(move: Move) void {
    line_buf[line_len] = 'a' + move.from % 8;
    line_buf[line_len + 1] = '1' + move.from / 8;
    line_buf[line_len + 2] = 'a' + move.to % 8;
    line_buf[line_len + 3] = '1' + move.to / 8;
    line_len += 4;
    // promo==Pawn (0) is no_move's encoding — never a real promotion, and
    // indexing "nbrq"[0-1] would underflow (this is how "a1a1r" was born)
    if (move.promo != None and move.promo > types.Pawn) {
        const promos = "nbrq";
        line_buf[line_len] = promos[move.promo - @as(u8, Knight)];
        line_len += 1;
    }
}
