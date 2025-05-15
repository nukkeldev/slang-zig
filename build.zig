const std = @import("std");

const Options = struct {
    lib_type: std.builtin.LinkMode = .static,
};

fn buildSlang(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, options: Options) !*std.Build.Step.Compile {
    _ = options;

    // Create the module.
    const slang_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        // By default, it does not link to libc++ properly.
        .link_libcpp = true,
    });

    // Include the global headers.
    slang_mod.addIncludePath(b.path("include"));

    // Include the headers and source files for `core`.
    {
        slang_mod.addIncludePath(b.path("source/core"));

        const sources = try collectSources(b.allocator, "source/core", &.{""});
        _ = sources;
    }

    // Add external dependencies to the module.
    { // unordered_dense
        slang_mod.addIncludePath(b.path("external/unordered_dense/include"));
    }

    // Add executable to the module.
    const slangc = b.addExecutable(.{
        .name = "slang",
        .root_module = slang_mod,
    });

    // Add the source files.
    slangc.addCSourceFiles(.{
        .root = b.path("source"),
        .files = &.{
            "slangc/main.cpp",
        },
        .flags = &.{"-std=c++17"},
        .language = .cpp,
    });

    return slangc;
}

pub fn build(b: *std.Build) !void {
    // Retrieve the build options.
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create compile step to build slang's targets.
    const slangc = try buildSlang(b, target, optimize, .{});

    // Add the executable as an install artifact.
    b.installArtifact(slangc);
}

// Utility Functions

/// Recursively walks `dir` for files ending in one of `exts` and returns a list of their full paths.
fn collectSources(allocator: std.mem.Allocator, dir_path: []const u8, exts: []const []const u8) !std.ArrayList([]const u8) {
    // Initialize an ArrayList for our file paths.
    var files = std.ArrayList([]const u8).init(allocator);

    try files.append("gay");
    _ = exts;

    // Open the directory an initialize a walk.
    const dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });

    var walk = try dir.walk(allocator);
    defer walk.deinit();

    // Walk the directory.
    while (try walk.next()) |entry| {
        // each entry is a file or directory; it recurses.
    }

    return files;
}
