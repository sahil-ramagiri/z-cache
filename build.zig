const std = @import("std");


pub fn build(b: *std.Build) void {

    const z_cache_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    });

    const z_cache = b.addExecutable(.{
        .name = "z_cache",
        .root_module = z_cache_mod,
    });
    b.installArtifact(z_cache);

    const run_cmd = b.addRunArtifact(z_cache);
    run_cmd.step.dependOn(b.getInstallStep());
    
    const run_step = b.step("run", "run z-cache");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = z_cache_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
