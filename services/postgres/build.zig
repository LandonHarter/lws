const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const version_str = b.option([]const u8, "version", "Release version (semver)") orelse "0.0.0-dev";
    const opts = b.addOptions();
    opts.addOption([]const u8, "version", version_str);

    const exe = b.addExecutable(.{
        .name = "lws-postgres",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addOptions("build_options", opts);

    const config_dep = b.dependency("config", .{ .target = target, .optimize = optimize });
    exe.root_module.addImport("config", config_dep.module("config"));

    const core_dep = b.dependency("core", .{ .target = target, .optimize = optimize });
    exe.root_module.addImport("core", core_dep.module("core"));

    b.installArtifact(exe);

    const test_step = b.step("test", "Run tests");

    const deps_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/deps.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(deps_tests).step);

    const config_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/config.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(config_tests).step);

    const main_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    main_tests.root_module.addImport("core", core_dep.module("core"));
    main_tests.root_module.addImport("config", config_dep.module("config"));
    main_tests.root_module.addOptions("build_options", opts);
    test_step.dependOn(&b.addRunArtifact(main_tests).step);

    const run_step = b.step("run", "Run the postgres service");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
