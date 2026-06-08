const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const version_str = b.option([]const u8, "version", "Release version (semver)") orelse "0.0.0-dev";
    const opts = b.addOptions();
    opts.addOption([]const u8, "version", version_str);

    const mod = b.addModule("cli", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    mod.addOptions("build_options", opts);

    const exe = b.addExecutable(.{
        .name = "cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
           .target = target,
            .optimize = optimize,
            .imports = &.{
               .{ .name = "cli", .module = mod },
            },
        }),
    });

    const zli_dep = b.dependency("zli", .{ .target = target, .optimize = optimize });
    exe.root_module.addImport("zli", zli_dep.module("zli"));
    exe.root_module.addOptions("build_options", opts);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
