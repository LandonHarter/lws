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
            .root_source_file = b.path("src/queue.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    queue_tests.root_module.addImport("config", config_dep.module("config"));

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(attrs_tests).step);
    test_step.dependOn(&b.addRunArtifact(queue_tests).step);

    const run_step = b.step("run", "Run the sqs service");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
