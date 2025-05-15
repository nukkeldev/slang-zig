const std = @import("std");

const Options = struct {
    lib_type: std.builtin.LinkMode = .static,
};

fn buildSlang(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, options: Options) *std.Build.Step.Compile {
    // Create the module.
    const slang_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });

    // Add library to the module.
    const slang = b.addLibrary(.{
        .name = "slang",
        .root_module = slang_mod,
        .linkage = options.lib_type,
    });

    // Link against the required dependencies.
    slang.linkLibCpp(); // TODO: This may or may not be required.

    // Add the source files.
    var cpp_source_files = try std.ArrayList([]const u8).init(b.allocator);
}

pub fn build(b: *std.Build) void {
    // Options

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---

    _ = target;
    _ = optimize;
}
