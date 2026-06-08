const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "lws-s3",
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

    const test_step = b.step("test", "Run tests");

    const bucket_config_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bucket_config.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(bucket_config_tests).step);

    // registry.zig is the test root for the storage layer; it transitively
    // imports persist/* and store/*, so their tests run here too. The subdir
    // files cannot be standalone roots because their `../` imports escape the
    // module path rooted at the file's own directory.
    const registry_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/registry.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    registry_tests.root_module.addImport("core", core_dep.module("core"));
    test_step.dependOn(&b.addRunArtifact(registry_tests).step);

    const wire_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wire_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    wire_tests.root_module.addImport("server", server_dep.module("server"));
    wire_tests.root_module.addImport("core", core_dep.module("core"));
    test_step.dependOn(&b.addRunArtifact(wire_tests).step);

    const run_step = b.step("run", "Run the s3 service");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
