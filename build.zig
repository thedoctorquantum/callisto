const std = @import("std");

const packages = struct 
{
    const clap = std.build.Pkg {
        .name = "clap",
        .source = .{ .path = "lib/zig-clap/clap.zig" }
    };

    const zyte = std.build.Pkg {
        .name = "zyte",
        .source = .{ .path = "zyte/src/main.zig" },
        .dependencies = &.{

        },
    };

    const zasm = std.build.Pkg {
        .name = "zasm",
        .source = .{ .path = "zasm/src/main.zig" },
        .dependencies = &.{
            zyte
        },
    };
};

pub fn build(builder: *std.build.Builder) void 
{
    const target = builder.standardTargetOptions(.{});
    const mode = builder.standardReleaseOptions();

    const zyte = builder.addExecutable("zyte", "zyte/src/main.zig");

    zyte.setTarget(target);
    zyte.setBuildMode(mode);
    zyte.install();
    zyte.addPackage(packages.clap);
    zyte.addPackage(packages.zasm);
    zyte.linkLibC();

    const zasm = builder.addExecutable("zasm", "zasm/src/main.zig");

    zasm.setTarget(target);
    zasm.setBuildMode(mode);
    zasm.install();
    zasm.addPackage(packages.clap);
    zasm.addPackage(packages.zyte);

    const zyte_run_cmd = zyte.run();

    zyte_run_cmd.step.dependOn(builder.getInstallStep());

    if (builder.args) |args| 
    {
        zyte_run_cmd.addArgs(args);
    }

    const zasm_run_cmd = zasm.run();

    zasm_run_cmd.step.dependOn(builder.getInstallStep());

    if (builder.args) |args| 
    {
        zasm_run_cmd.addArgs(args);
    }
    
    const run_zyte_step = builder.step("run_zyte", "Run zyte");
    run_zyte_step.dependOn(&zyte_run_cmd.step);

    const run_zasm_step = builder.step("run_zasm", "Run zasm");
    run_zasm_step.dependOn(&zasm_run_cmd.step);

    // const exe_tests = builder.addTest("src/main.zig");

    // exe_tests.setTarget(target);
    // exe_tests.setBuildMode(mode);

    // const test_step = builder.step("test", "Run unit tests");
    // test_step.dependOn(&exe_tests.step);
}