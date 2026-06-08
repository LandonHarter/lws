const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "lws-dynamodb",
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

    const registry_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/registry.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    registry_tests.root_module.addImport("core", core_dep.module("core"));
    test_step.dependOn(&b.addRunArtifact(registry_tests).step);

    const types_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/types.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(types_tests).step);

    const store_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/store_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    store_tests.root_module.addImport("core", core_dep.module("core"));
    test_step.dependOn(&b.addRunArtifact(store_tests).step);

    const persist_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/persist_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    persist_tests.root_module.addImport("core", core_dep.module("core"));
    test_step.dependOn(&b.addRunArtifact(persist_tests).step);

    const wire_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wire_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    wire_tests.root_module.addImport("server", server_dep.module("server"));
    wire_tests.root_module.addImport("core", core_dep.module("core"));
    test_step.dependOn(&b.addRunArtifact(wire_tests).step);

    const expr_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/expr_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    expr_tests.root_module.addImport("core", core_dep.module("core"));
    test_step.dependOn(&b.addRunArtifact(expr_tests).step);

    const run_step = b.step("run", "Run the dynamodb service");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
