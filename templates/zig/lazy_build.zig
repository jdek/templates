// lazy_build.zig — drop this next to build.zig and @import("lazy_build.zig").
//
// Scans src/ (or any directory you choose) and treats every .zig file as its
// own named module. @import("foo") in any source file is resolved by finding
// the closest matching file by directory distance — no manual addImport wiring.
//
// Usage:
//
//   var arena_state = std.heap.ArenaAllocator.init(b.allocator);
//   defer arena_state.deinit();
//   const arena = arena_state.allocator();
//
//   var infos_list = std.ArrayListUnmanaged(lazy_build.ModuleInfo).empty;
//   lazy_build.scanTree(b.graph.io, arena, "src", &infos_list) catch |e|
//       std.debug.panic("scan src/ failed: {s}", .{@errorName(e)});
//   const infos = infos_list.items;
//
//   var lazy = lazy_build.LazyBuilder.init(b, arena, infos, target, optimize);
//   // optional: lazy.build_options_mod = my_options.createModule();
//
//   const root_segs = try lazy_build.resolveRoot(infos, &.{ "sub", "main" });
//   const mod = try lazy.getOrCreate(root_segs);
//
//   lazy.checkMissingImports(); // panics with a list if anything was unresolved

const std = @import("std");

pub const ModuleInfo = struct {
    segs: []const []const u8,
};

pub fn scanTree(
    io: std.Io,
    arena: std.mem.Allocator,
    root: []const u8,
    infos: *std.ArrayListUnmanaged(ModuleInfo),
) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(arena);
    defer walker.deinit();

    while (try walker.next(io)) |ent| {
        if (ent.kind != .file) continue;
        if (!std.mem.endsWith(u8, ent.path, ".zig")) continue;

        const rel = try arena.dupe(u8, ent.path);
        const rel_no_ext = rel[0 .. rel.len - ".zig".len];

        const segs = try splitOn(arena, rel_no_ext, '/');
        if (segs.len == 0) continue;

        try infos.append(arena, .{ .segs = segs });
    }
}

// Finds the shortest path in infos whose segments end with root_segs.
// Returns error.RootNotFound or error.AmbiguousRoot when the match is not unique.
pub fn resolveRoot(
    infos: []const ModuleInfo,
    root_segs: []const []const u8,
) ![]const []const u8 {
    var best: ?[]const []const u8 = null;
    var best_len: usize = std.math.maxInt(usize);
    var best_count: usize = 0;

    for (infos) |cand| {
        if (!endsWithSegments(cand.segs, root_segs)) continue;

        if (cand.segs.len < best_len) {
            best_len = cand.segs.len;
            best = cand.segs;
            best_count = 1;
        } else if (cand.segs.len == best_len) {
            best_count += 1;
        }
    }

    if (best == null) return error.RootNotFound;
    if (best_count > 1) return error.AmbiguousRoot;
    return best.?;
}

pub const LazyBuilder = struct {
    b: *std.Build,
    io: std.Io,
    arena: std.mem.Allocator,
    infos: []const ModuleInfo,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    src_dir: []const u8 = "src",

    // Set after init if your project uses @import("build_options").
    build_options_mod: ?*std.Build.Module = null,

    name_to_mod: std.StringHashMapUnmanaged(*std.Build.Module) = .{},
    missing_imports: std.ArrayListUnmanaged(MissingImport) = .empty,

    const MissingImport = struct {
        import_name: []const u8,
        from_module: []const u8,
    };

    pub fn init(
        b: *std.Build,
        arena: std.mem.Allocator,
        infos: []const ModuleInfo,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
    ) LazyBuilder {
        return .{
            .b = b,
            .io = b.graph.io,
            .arena = arena,
            .infos = infos,
            .target = target,
            .optimize = optimize,
        };
    }

    // Lazily create (or return cached) the Build.Module for the given path segments.
    // Recursively resolves and wires all @import("...") dependencies.
    pub fn getOrCreate(self: *LazyBuilder, segs: []const []const u8) !*std.Build.Module {
        const name = try joinWith(self.arena, segs, '.');
        if (self.name_to_mod.get(name)) |m| return m;

        const path = try pathFromSegs(self.arena, self.src_dir, segs);
        const m = self.b.createModule(.{
            .root_source_file = self.b.path(path),
            .target = self.target,
            .optimize = self.optimize,
        });
        try self.name_to_mod.put(self.arena, name, m);

        const data = try std.Io.Dir.cwd().readFileAlloc(self.io, path, self.arena, .limited(32 * 1024 * 1024));

        var it_imp = ImportIter.init(data);
        while (it_imp.next()) |imp_raw| {
            if (std.mem.eql(u8, imp_raw, "std") or
                std.mem.eql(u8, imp_raw, "builtin") or
                std.mem.eql(u8, imp_raw, "root"))
            {
                continue;
            }

            if (std.mem.eql(u8, imp_raw, "build_options")) {
                if (self.build_options_mod) |bom| m.addImport("build_options", bom);
                continue;
            }

            // Path-style imports (.zig suffix or slashes) are not supported.
            if (std.mem.endsWith(u8, imp_raw, ".zig") or
                std.mem.indexOfScalar(u8, imp_raw, '/') != null)
            {
                try self.missing_imports.append(self.arena, .{
                    .import_name = imp_raw,
                    .from_module = name,
                });
                continue;
            }

            // .zon imports are resolved natively by Zig relative to the file.
            if (std.mem.endsWith(u8, imp_raw, ".zon")) continue;

            const imp_segs = try splitOn(self.arena, imp_raw, '.');
            if (imp_segs.len == 0) continue;

            const dep_segs = resolveByDistance(self.infos, segs, imp_segs) catch |e| {
                if (e == error.ImportNotFound or e == error.AmbiguousImport) {
                    try self.missing_imports.append(self.arena, .{
                        .import_name = imp_raw,
                        .from_module = name,
                    });
                    continue;
                }
                return e;
            };

            const dep_mod = self.getOrCreate(dep_segs) catch |e| {
                if (e == error.ImportNotFound) continue;
                return e;
            };
            m.addImport(imp_raw, dep_mod);
        }

        return m;
    }

    // Call after wiring up all executables/tests.
    // Prints every unresolved import and panics if any were found.
    pub fn checkMissingImports(self: *const LazyBuilder) void {
        if (self.missing_imports.items.len == 0) return;
        std.debug.print("Unresolved imports ({}):\n", .{self.missing_imports.items.len});
        for (self.missing_imports.items) |m| {
            std.debug.print("  {s}  (from {s})\n", .{ m.import_name, m.from_module });
        }
        std.debug.panic("Build failed: unresolved imports", .{});
    }
};

// -- private helpers -----------------------------------------------------------

fn resolveByDistance(
    infos: []const ModuleInfo,
    from_segs: []const []const u8,
    imp_segs: []const []const u8,
) ![]const []const u8 {
    var best: ?[]const []const u8 = null;
    var best_dist: usize = std.math.maxInt(usize);
    var best_count: usize = 0;

    const from_dir = dirSegs(from_segs);

    for (infos) |cand| {
        if (!endsWithSegments(cand.segs, imp_segs)) continue;
        const cand_dir = dirSegs(cand.segs);
        const dist = dirDistance(from_dir, cand_dir);
        if (dist < best_dist) {
            best_dist = dist;
            best = cand.segs;
            best_count = 1;
        } else if (dist == best_dist) {
            best_count += 1;
        }
    }

    if (best == null) return error.ImportNotFound;
    if (best_count > 1) return error.AmbiguousImport;
    return best.?;
}

fn dirSegs(segs: []const []const u8) []const []const u8 {
    if (segs.len <= 1) return &[_][]const u8{};
    return segs[0 .. segs.len - 1];
}

fn endsWithSegments(full: []const []const u8, suffix: []const []const u8) bool {
    if (suffix.len == 0 or suffix.len > full.len) return false;
    const start = full.len - suffix.len;
    for (suffix, 0..) |seg, i| {
        if (!std.mem.eql(u8, seg, full[start + i])) return false;
    }
    return true;
}

fn dirDistance(a: []const []const u8, b: []const []const u8) usize {
    const lcp = lcpSegments(a, b);
    return (a.len - lcp) + (b.len - lcp);
}

fn lcpSegments(a: []const []const u8, b: []const []const u8) usize {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (!std.mem.eql(u8, a[i], b[i])) break;
    }
    return i;
}

fn splitOn(arena: std.mem.Allocator, s: []const u8, sep: u8) ![]const []const u8 {
    var list = std.ArrayListUnmanaged([]const u8).empty;
    var it = std.mem.splitScalar(u8, s, sep);
    while (it.next()) |seg| {
        if (seg.len != 0) try list.append(arena, seg);
    }
    return list.toOwnedSlice(arena);
}

fn joinWith(arena: std.mem.Allocator, segs: []const []const u8, sep: u8) ![]const u8 {
    var len: usize = 0;
    for (segs) |s| len += s.len;
    if (segs.len > 0) len += segs.len - 1;
    const buf = try arena.alloc(u8, len);
    var i: usize = 0;
    for (segs, 0..) |s, idx| {
        std.mem.copyForwards(u8, buf[i..], s);
        i += s.len;
        if (idx + 1 < segs.len) {
            buf[i] = sep;
            i += 1;
        }
    }
    return buf;
}

fn pathFromSegs(arena: std.mem.Allocator, src_dir: []const u8, segs: []const []const u8) ![]const u8 {
    var len: usize = src_dir.len + 1 + ".zig".len; // "src/" + ".zig"
    for (segs) |s| len += s.len;
    if (segs.len > 0) len += segs.len - 1;
    const buf = try arena.alloc(u8, len);
    var i: usize = 0;
    std.mem.copyForwards(u8, buf[i..], src_dir);
    i += src_dir.len;
    buf[i] = '/';
    i += 1;
    for (segs, 0..) |s, idx| {
        std.mem.copyForwards(u8, buf[i..], s);
        i += s.len;
        if (idx + 1 < segs.len) {
            buf[i] = '/';
            i += 1;
        }
    }
    std.mem.copyForwards(u8, buf[i..], ".zig");
    return buf;
}

const ImportIter = struct {
    data: []const u8,
    i: usize,

    pub fn init(data: []const u8) ImportIter {
        return .{ .data = data, .i = 0 };
    }

    pub fn next(self: *ImportIter) ?[]const u8 {
        const needle = "@import(\"";
        while (self.i + needle.len <= self.data.len) : (self.i += 1) {
            if (!std.mem.eql(u8, self.data[self.i .. self.i + needle.len], needle)) continue;
            if (isCommented(self.data, self.i)) continue;
            const start = self.i + needle.len;
            var j = start;
            while (j < self.data.len and self.data[j] != '"') : (j += 1) {}
            if (j >= self.data.len) return null;
            self.i = j + 1;
            return self.data[start..j];
        }
        return null;
    }

    fn isCommented(data: []const u8, pos: usize) bool {
        var line_start = pos;
        while (line_start > 0 and data[line_start - 1] != '\n') : (line_start -= 1) {}
        var i = line_start;
        while (i < pos) : (i += 1) {
            if (i + 1 < data.len and data[i] == '/' and data[i + 1] == '/') return true;
        }
        return false;
    }
};
