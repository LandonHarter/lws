const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "sqs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const server_dep = b.dependency("server", .{ .target = target, .optimize = optimize });
    exe.root_module.addImport("server", server_dep.module("server"));

    const config_dep = b.dependency("config", .{ .target = target, .optimize = optimize });
    exe.root_module.addImport("config", config_dep.module("config"));

    const core_dep = b.dependency("core", .{ .target = target, .optimize = optimize });
    exe.root_module.addImport("core", core_dep.module("core"));

    b.installArtifact(exe);

    const attrs_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/attrs.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    attrs_tests.root_module.addImport("config", config_dep.module("config"));

    const queue_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/queue_config.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    queue_tests.root_module.addImport("config", config_dep.module("config"));

    const receipt_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/receipt.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    receipt_tests.root_module.addImport("core", core_dep.module("core"));

    const runtime_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/runtime.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    runtime_tests.root_module.addImport("core", core_dep.module("core"));

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(attrs_tests).step);
    test_step.dependOn(&b.addRunArtifact(queue_tests).step);
    test_step.dependOn(&b.addRunArtifact(receipt_tests).step);
    test_step.dependOn(&b.addRunArtifact(runtime_tests).step);

    const module_test_files = [_][]const u8{
        "src/arn.zig",
        "src/errors.zig",
    };
    for (module_test_files) |path| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(path),
                .target = target,
                .optimize = optimize,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    const run_step = b.step("run", "Run the sqs service");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
