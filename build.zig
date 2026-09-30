const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "aether3",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the engine");
    run_step.dependOn(&run_cmd.step);

    // ── wasm 引擎(协议对齐 AetherChess:worker.js 零导入加载,C ABI)──
    const wasm = b.addExecutable(.{
        .name = "chess",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
            .optimize = .ReleaseFast,
            .strip = true,
        }),
    });
    // freestanding 无 _start:关入口 + 动态导出,否则拿不到 export
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    b.installArtifact(wasm);
}
