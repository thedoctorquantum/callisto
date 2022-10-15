const std = @import("std");

const packages = struct 
{
    const clap = std.build.Pkg {
        .name = "clap",
        .source = .{ .path = "lib/zig-clap/clap.zig" }
    };

    const callisto = std.build.Pkg {
        .name = "callisto",
        .source = .{ .path = "callisto/src/main.zig" },
        .dependencies = &.{

        },
    };

    const casm = std.build.Pkg {
        .name = "casm",
        .source = .{ .path = "casm/src/main.zig" },
        .dependencies = &.{
            callisto
        },
    };
};

pub fn build(builder: *std.build.Builder) void 
{
    const target = builder.standardTargetOptions(.{});
    const mode = builder.standardReleaseOptions();

    const callisto = builder.addExecutable("callisto", "callisto/src/main.zig");

    callisto.setTarget(target);
    callisto.setBuildMode(mode);
    callisto.install();
    callisto.addPackage(packages.clap);
    callisto.addPackage(packages.casm);
    callisto.linkLibC();

    const casm = builder.addExecutable("casm", "casm/src/main.zig");

    casm.setTarget(target);
    casm.setBuildMode(mode);
    casm.install();
    casm.addPackage(packages.clap);
    casm.addPackage(packages.callisto);

    const callisto_run_cmd = callisto.run();

    callisto_run_cmd.step.dependOn(builder.getInstallStep());

    if (builder.args) |args| 
    {
        callisto_run_cmd.addArgs(args);
    }

    const casm_run_cmd = casm.run();

    casm_run_cmd.step.dependOn(builder.getInstallStep());

    if (builder.args) |args| 
    {
        casm_run_cmd.addArgs(args);
    }
    
    const run_callisto_step = builder.step("run_callisto", "Run callisto");
    run_callisto_step.dependOn(&callisto_run_cmd.step);

    const run_casm_step = builder.step("run_casm", "Run casm");
    run_casm_step.dependOn(&casm_run_cmd.step);

    // const exe_tests = builder.addTest("src/main.zig");

    // exe_tests.setTarget(target);
    // exe_tests.setBuildMode(mode);

    // const test_step = builder.step("test", "Run unit tests");
    // test_step.dependOn(&exe_tests.step);
}