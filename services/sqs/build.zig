const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "lws-sqs",
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
    runtime_tests.root_module.addImport("config", config_dep.module("config"));

    const queue_value_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/queue.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    queue_value_tests.root_module.addImport("config", config_dep.module("config"));

    // registry.zig is the test root for the persistence layer; it transitively
    // imports persist/queue_dir.zig, so those tests run here too. Using the
    // subdir files as standalone roots fails (their `../` imports escape the
    // module path rooted at the file's own directory).
    const registry_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/registry.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    registry_tests.root_module.addImport("config", config_dep.module("config"));
    registry_tests.root_module.addImport("core", core_dep.module("core"));

    const store_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/store_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    store_tests.root_module.addImport("config", config_dep.module("config"));
    store_tests.root_module.addImport("core", core_dep.module("core"));

    const wire_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wire_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    wire_tests.root_module.addImport("server", server_dep.module("server"));
    wire_tests.root_module.addImport("core", core_dep.module("core"));
    wire_tests.root_module.addImport("config", config_dep.module("config"));

    const batch_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/batch_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    batch_tests.root_module.addImport("core", core_dep.module("core"));
    batch_tests.root_module.addImport("config", config_dep.module("config"));

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(attrs_tests).step);
    test_step.dependOn(&b.addRunArtifact(queue_tests).step);
    test_step.dependOn(&b.addRunArtifact(receipt_tests).step);
    test_step.dependOn(&b.addRunArtifact(runtime_tests).step);
    test_step.dependOn(&b.addRunArtifact(queue_value_tests).step);
    test_step.dependOn(&b.addRunArtifact(registry_tests).step);
    test_step.dependOn(&b.addRunArtifact(store_tests).step);
    test_step.dependOn(&b.addRunArtifact(wire_tests).step);
    test_step.dependOn(&b.addRunArtifact(batch_tests).step);

    const module_test_files = [_][]const u8{
        "src/arn.zig",
        "src/errors.zig",
        "src/policy.zig",
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
