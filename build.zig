const std = @import("std");
const builtin = @import("builtin");

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

        b.getInstallStep().dependOn(&build_miniz.step);

        // Add amalgamated files to the module.
        mod.addIncludePath(b.path("external/miniz/_build/amalgamation"));
        mod.addCSourceFiles(.{
            .root = b.path("external/miniz/_build/amalgamation"),
            .files = &.{"miniz.c"},
        });
    }
};

fn registerSlangCapabilityGenerator(b: *std.Build, slang_mod: *std.Build.Module) !void {
    const root_file = b.path("tools/slang-capability-generator/capability-generator-main.cpp");

    const slang_capability_generator = b.addExecutable(.{
        .name = "slang-capability-generator",
        .root_source_file = root_file,
        .target = slang_mod.resolved_target,
        .optimize = slang_mod.optimize orelse .Debug,
    });

    _ = try collectIncludes(b.allocator, root_file.src_path.sub_path);

    slang_capability_generator.addIncludePath(b.path("tools/slang-capability-generator"));

    const run_slang_capability_generator = b.addRunArtifact(slang_capability_generator);
    run_slang_capability_generator.addArgs(&.{
        "source/slang/slang-capabilities.capdef",
        "--target-directory",
        "source/slang/capability",
    });

    // Register this as a top-level step.
    const tls = b.step("generate-capabilities", "Generate capability files.");
    tls.* = run_slang_capability_generator.step;
}

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

        // Find all .cpp files in the directory.
        // TODO: Write files to an index that can be embed.
        var sources = try collectSources(b.allocator, "source/core", &.{".cpp"});
        defer {
            for (sources.items) |item| b.allocator.free(item);
            sources.deinit();
        }

        // Add platform-specific source files.
        switch (builtin.os.tag) {
            .windows => try sources.append(try b.allocator.dupe(u8, "windows/slang-win-process.cpp")),
            .linux => try sources.append(try b.allocator.dupe(u8, "unix/slang-unix-process.cpp")),
            else => {},
        }

        // Add the source files to the module.
        slang_mod.addCSourceFiles(.{
            .root = b.path("source/core"),
            .files = sources.items,
            .flags = &.{"-std=c++17"},
        });
    }

    // Include the headers and source files for `compiler-core`.
    {
        slang_mod.addIncludePath(b.path("source/compiler-core"));

        // Find all .cpp files in the directory.
        // TODO: Write files to an index that can be embed.
        var sources = try collectSources(b.allocator, "source/compiler-core", &.{".cpp"});
        defer {
            for (sources.items) |item| b.allocator.free(item);
            sources.deinit();
        }

        // Add platform-specific source files.
        switch (builtin.os.tag) {
            .windows => {
                slang_mod.addIncludePath(b.path("source/compiler-core/windows"));
                try sources.append(try b.allocator.dupe(u8, "windows/slang-win-visual-studio-util.cpp"));
            },
            else => {},
        }

        // Add the source files to the module.
        slang_mod.addCSourceFiles(.{
            .root = b.path("source/compiler-core"),
            .files = sources.items,
            .flags = &.{"-std=c++17"},
        });
    }

    // Include the headers and source files for `slang`.
    {
        slang_mod.addIncludePath(b.path("source/slang"));

        // Find all .cpp files in the directory.
        // TODO: Write files to an index that can be embed.
        var sources = try collectSources(b.allocator, "source/slang", &.{".cpp"});
        defer {
            for (sources.items) |item| b.allocator.free(item);
            sources.deinit();
        }

        // Add the source files to the module.
        slang_mod.addCSourceFiles(.{
            .root = b.path("source/slang"),
            .files = sources.items,
            .flags = &.{"-std=c++17"},
        });
    }

    // Add external dependencies to the module.
    ExternalDependencies.unordered_dense(b, slang_mod);
    ExternalDependencies.lz4(b, slang_mod);
    ExternalDependencies.miniz(b, slang_mod);

    // Register generators.
    try registerSlangCapabilityGenerator(b, slang_mod);

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

/// Iterates the files in `dir_path` for files ending in one of `exts` and returns a list of their relative paths.
/// Each item must be free'd individually in addition to deinit'ing the list.
fn collectSources(allocator: std.mem.Allocator, dir_path: []const u8, exts: []const []const u8) !std.ArrayList([]const u8) {
    // Initialize an ArrayList for our file paths.
    var files = std.ArrayList([]const u8).init(allocator);
    errdefer files.deinit();

    // Open the directory an initialize a walk.
    const dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });

    // Iterate through the files in the directory.
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        // Skip entries that aren't files.
        if (entry.kind != .file) continue;

        // Check if the file extension is specified, if so add it to the files list.
        for (exts) |ext| {
            if (std.mem.endsWith(u8, entry.name, ext)) {
                try files.append(try allocator.dupe(u8, entry.name));
            }
        }
    }

    return files;
}

const IncludeGraph = struct {
    // Member Variables
    arena: std.heap.ArenaAllocator,
    root: *Node,

    // Type Definitions
    const Self = @This();

    const Node = struct {
        parent: ?*Node,
        include: Include,
        children: []Node,

        pub fn deinit(self: *Node, owner: std.mem.Allocator) void {
            for (self.children) |node| node.deinit();
            owner.free(self);
        }
    };

    const Include = union(enum) {
        Relative: struct {
            resolved_path: std.fs.path,
        },
        System: []const u8,
    };

    // Functions

    /// Constructs an include graph off of the `root_file_path`.
    pub fn init(allocator: std.mem.Allocator, root_file_path: std.fs.path) Self {
        var self = Self{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .root = undefined,
        };

        const alloc = self.arena.allocator();
        self.root = try alloc.create(Node);

        return self;
    }

    pub fn deinit(self: Self) void {}
};
