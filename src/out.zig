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
    const out_slice = std.fmt.bufPrint(line_buf[line_len..], "{d}", .{v}) catch unreachable;
    line_len += out_slice.len;
}

pub fn appendMoveStr(move: Move) void {
    line_buf[line_len] = 'a' + move.from % 8;
    line_buf[line_len + 1] = '1' + move.from / 8;
    line_buf[line_len + 2] = 'a' + move.to % 8;
    line_buf[line_len + 3] = '1' + move.to / 8;
    line_len += 4;
    if (move.promo != None) {
        const promos = "nbrq";
        line_buf[line_len] = promos[move.promo - @as(u8, Knight)];
        line_len += 1;
    }
}
