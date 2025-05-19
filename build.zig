const std = @import("std");
const builtin = @import("builtin");

const IncludeGraph = @import("include_graph").IncludeGraph;
const INCLUDE_DIRS: []const []const u8 = &.{
    "include#",
    "source#",
    "prelude#",
    // "source/core#core",
    // "source/slang-rt#slang-rt",
    // "source/compiler-core#compiler-core",
    // "source/slang-wasm#slang-wasm",
    // "source/slang-glslang#slang-glslang",
    // "source/slang-core-module#slang-core-module",
    // "source/slang-glsl-module#slang-glsl-module",
    "source/slang#slang",
    // "source/slangc#slangc",
};

const Options = struct {
    lib_type: std.builtin.LinkMode = .static,
};

const ExternalDependencies = struct {
    pub fn unordered_dense(b: *std.Build, mod: *std.Build.Module) void {
        mod.addIncludePath(b.path("external/unordered_dense/include"));
    }

    pub fn lz4(b: *std.Build, mod: *std.Build.Module) void {
        mod.addIncludePath(b.path("external/lz4/lib"));
        mod.addCSourceFiles(.{
            .root = b.path("external/lz4/lib"),
            .files = &.{
                "lz4.c",
                "lz4file.c",
                "lz4frame.c",
                "lz4hc.c",
                "xxhash.c",
            },
        });
    }

    pub fn miniz(b: *std.Build, mod: *std.Build.Module) void {
        // We currently delegate the build process to CMake,
        // which we like want to keep doing for external dependencies.

        var build_miniz = b.addSystemCommand(&.{
            "cmake",
            "-H.",
            "-B_build",
            "-DBUILD_EXAMPLES=OFF",
            "-DINSTALL_PROJECT=OFF",
            "-DAMALGAMATE_SOURCES=ON",
            "-GUnix Makefiles",
            "-Wno-deprecated",
        });
        build_miniz.setCwd(b.path("external/miniz"));
        _ = build_miniz.captureStdOut(); // Suppress output.

        // TODO: This needs to be fixed lol
        b.getInstallStep().dependOn(&build_miniz.step);

        // Add amalgamated files to the module.
        mod.addIncludePath(b.path("external/miniz/_build/amalgamation"));
        mod.addCSourceFiles(.{
            .root = b.path("external/miniz/_build/amalgamation"),
            .files = &.{"miniz.c"},
        });
    }
};

const ModuleOptions = struct {
    root_source_file: []const u8,
    flags: []const []const u8 = &.{},

    additional_source_files: []const []const u8 = &.{},
    additional_include_dirs: []const []const u8 = &.{},

    platform_specific_sources: []const PlatformSpecificPaths = &.{},

    link_libcpp: bool = false,
    link_libc: bool = false,
    sanitize_c: bool = true,

    pre_processors: []const struct {
        func: fn (*std.Build, *std.Build.Module) void,
    },

    debug: bool = false,

    pub const PlatformSpecificPaths = struct {
        platform: std.Target.Os.Tag,
        source_files: []const []const u8 = &.{},
        include_dirs: []const []const u8 = &.{},
    };
};

fn buildModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, comptime options: ModuleOptions) !*std.Build.Module {
    // Create the module.
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = options.link_libc,
        .link_libcpp = options.link_libcpp,
        .sanitize_c = options.sanitize_c,
    });

    // Enable debugging if set.
    IncludeGraph.DEBUG = options.debug;

    // Construct a source graph off of the root source file.
    const source_graph = try IncludeGraph.init(b.allocator, options.root_source_file, options.additional_include_dirs);
    defer source_graph.deinit();

    if (options.debug) std.debug.print("{}\n", .{source_graph});

    // Add the sources and include directories to the module.
    mod.addCSourceFiles(.{
        .flags = options.flags,
        .files = source_graph.get_sources(),
    });
    mod.addCSourceFiles(.{
        .flags = options.flags,
        .files = options.additional_source_files,
    });

    for (source_graph.get_include_paths()) |path| {
        mod.addIncludePath(b.path(path));
    }

    // Add platform-specific source files and include directories.
    for (options.platform_specific_sources) |source| {
        if (source.platform == builtin.os.tag) {
            mod.addCSourceFiles(.{
                .files = source.source_files,
                .flags = options.flags,
            });

            for (source.include_dirs) |path| {
                mod.addIncludePath(b.path(path));
            }
        }
    }

    // Execute the module preprocessors.
    inline for (options.pre_processors) |pre_processor| {
        pre_processor.func(b, mod);
    }

    return mod;
}

fn runSlangCapabilityGenerator(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) !*std.Build.Step.Run {
    const mod = try buildModule(
        b,
        target,
        optimize,
        .{
            .root_source_file = "tools/slang-capability-generator/capability-generator-main.cpp",
            .flags = &.{"-std=c++17"},
            .additional_include_dirs = INCLUDE_DIRS,
            .platform_specific_sources = &.{
                .{
                    .platform = .windows,
                    .source_files = &.{ "source/core/windows/slang-win-process.cpp", "source/compiler-core/windows/slang-win-visual-studio-util.cpp" },
                },
                .{
                    .platform = .linux,
                    .source_files = &.{"source/core/unix/slang-unix-process.cpp"},
                },
            },
            .link_libcpp = true,
            .sanitize_c = false,
            .pre_processors = &.{
                .{ .func = ExternalDependencies.lz4 },
                .{ .func = ExternalDependencies.unordered_dense },
                .{ .func = ExternalDependencies.miniz },
            },
        },
    );

    // Create the executable compile step.
    const exe = b.addExecutable(.{
        .name = "slang-capability-generator",
        .root_module = mod,
    });

    // Create the run step.
    const run = b.addRunArtifact(exe);
    run.addArgs(&.{ "source/slang/slang-capabilities.capdef", "--target-directory", "zig-out/generated/source/slang/capability", "--doc", "docs/user-guide/a3-02-reference-capability-atoms.md" });

    // Make the directory for the generated files.
    run.step.dependOn(&b.addSystemCommand(&.{ "mkdir", "-p", "zig-out/generated/source/slang/capability" }).step);

    return run;
}

fn buildSlangc(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) !*std.Build.Step.Compile {
    const mod = try buildModule(
        b,
        target,
        optimize,
        .{
            .root_source_file = "source/slangc/main.cpp",
            .flags = &.{"-std=c++17"},
            .additional_include_dirs = INCLUDE_DIRS,
            .additional_source_files = &.{ "source/slang/slang-api.cpp", "zig-out/generated/source/slang/capability/slang-lookup-capability-defs.cpp" },
            .platform_specific_sources = &.{
                .{
                    .platform = .windows,
                    .source_files = &.{ "source/core/windows/slang-win-process.cpp", "source/compiler-core/windows/slang-win-visual-studio-util.cpp" },
                },
                .{
                    .platform = .linux,
                    .source_files = &.{"source/core/unix/slang-unix-process.cpp"},
                },
            },
            .link_libcpp = true,
            .sanitize_c = false,
            .pre_processors = &.{
                .{ .func = ExternalDependencies.lz4 },
                .{ .func = ExternalDependencies.unordered_dense },
                .{ .func = ExternalDependencies.miniz },
            },
            .debug = true,
        },
    );

    // Add additional include directories that might not exist yet.
    mod.addIncludePath(b.path("zig-out/generated/source/slang/capability"));

    // Add pre-processor definitions.
    mod.addCMacro("SLANG_DYNAMIC", "");

    // Create the executable compile step.
    const exe = b.addExecutable(.{
        .name = "slangc",
        .root_module = mod,
    });

    return exe;
}

pub fn build(b: *std.Build) !void {
    // Retrieve the build options.
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create compile step to build slang's targets.
    const run_slang_capability_generator = try runSlangCapabilityGenerator(b, target, optimize);

    const slangc = try buildSlangc(b, target, optimize);
    slangc.step.dependOn(&run_slang_capability_generator.step);

    // Add the executable as an install artifact.
    b.installArtifact(slangc);
}
