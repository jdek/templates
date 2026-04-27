const std = @import("std");
const lb = @import("lazy_build.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    var arena_state = std.heap.ArenaAllocator.init(b.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // -- scan src/ -------------------------------------------------------------
    var infos_list = std.ArrayListUnmanaged(lb.ModuleInfo).empty;
    lb.scanTree(b.graph.io, arena, "src", &infos_list) catch |e|
        std.debug.panic("scan src/ failed: {s}", .{@errorName(e)});
    const infos = infos_list.items;

    var lazy = lb.LazyBuilder.init(b, arena, infos, target, optimize);

    // If your project uses @import("build_options"), uncomment and populate:
    //
    //   const opts = b.addOptions();
    //   opts.addOption(bool, "feature_x", b.option(bool, "feature-x", "Enable X") orelse false);
    //   lazy.build_options_mod = opts.createModule();

    // -- executables -----------------------------------------------------------
    // Replace the root segments with the path to your entry point under src/.
    // &.{"main"} resolves to src/main.zig; &.{"cli", "main"} → src/cli/main.zig.
    const ExeSpec = struct {
        name: []const u8,
        root: []const []const u8,
    };
    const exes = [_]ExeSpec{
        .{ .name = "myapp", .root = &.{"main"} },
    };
    for (exes) |spec| {
        const resolved = lb.resolveRoot(infos, spec.root) catch |e|
            std.debug.panic("resolve root for {s}: {s}", .{ spec.name, @errorName(e) });
        const exe_mod = lazy.getOrCreate(resolved) catch |e|
            std.debug.panic("build module for {s}: {s}", .{ spec.name, @errorName(e) });
        const exe = b.addExecutable(.{ .name = spec.name, .root_module = exe_mod });
        b.installArtifact(exe);
    }

    lazy.checkMissingImports();

    // -- tests -----------------------------------------------------------------
    const test_step = b.step("test", "Run tests");
    const test_roots = [_][]const []const u8{
        &.{"main"},
    };
    for (test_roots) |root_segs| {
        const resolved = lb.resolveRoot(infos, root_segs) catch continue;
        const mod = lazy.getOrCreate(resolved) catch continue;
        const t = b.addTest(.{ .root_module = mod });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
