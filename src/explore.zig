const std = @import("std");
const Store = @import("store.zig").Store;
const idx = @import("index.zig");
const WordIndex = idx.WordIndex;

pub const SymbolKind = enum(u8) {
    function,
    struct_def,
    enum_def,
    union_def,
    constant,
    variable,
    import,
    test_decl,
    comment_block,
    trait_def,
    impl_block,
    type_alias,
    macro_def,
    method,
    class_def,
    interface_def,
};

pub const Symbol = struct {
    name: []const u8,
    kind: SymbolKind,
    line_start: u32,
    line_end: u32,
    detail: ?[]const u8 = null,
};

pub const FileOutline = struct {
    path: []const u8,
    language: Language,
    line_count: u32,
    byte_size: u64,
    symbols: std.ArrayList(Symbol) = .{},
    imports: std.ArrayList([]const u8) = .{},
    allocator: std.mem.Allocator,
    owns_path: bool = false,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) FileOutline {
        return .{
            .path = path,
            .language = detectLanguage(path),
            .line_count = 0,
            .byte_size = 0,
            .allocator = allocator,
        };
    }
    pub fn deinit(self: *FileOutline) void {
        if (self.owns_path) self.allocator.free(self.path);
        for (self.symbols.items) |sym| {
            self.allocator.free(sym.name);
            if (sym.detail) |d| self.allocator.free(d);
        }
        self.symbols.deinit(self.allocator);
        for (self.imports.items) |imp| self.allocator.free(imp);
        self.imports.deinit(self.allocator);
    }
};

pub const Language = enum(u8) {
    zig,
    c,
    cpp,
    python,
    javascript,
    typescript,
    rust,
    go_lang,
    php,
    ruby,
    markdown,
    json,
    yaml,
    unknown,
};

pub fn detectLanguage(path: []const u8) Language {
    if (std.mem.endsWith(u8, path, ".zig")) return .zig;
    if (std.mem.endsWith(u8, path, ".c") or std.mem.endsWith(u8, path, ".h")) return .c;
    if (std.mem.endsWith(u8, path, ".cpp") or std.mem.endsWith(u8, path, ".hpp")) return .cpp;
    if (std.mem.endsWith(u8, path, ".py")) return .python;
    if (std.mem.endsWith(u8, path, ".js") or std.mem.endsWith(u8, path, ".jsx")) return .javascript;
    if (std.mem.endsWith(u8, path, ".ts") or std.mem.endsWith(u8, path, ".tsx")) return .typescript;
    if (std.mem.endsWith(u8, path, ".rs")) return .rust;
    if (std.mem.endsWith(u8, path, ".go")) return .go_lang;
    if (std.mem.endsWith(u8, path, ".php")) return .php;
    if (std.mem.endsWith(u8, path, ".rb") or std.mem.endsWith(u8, path, ".rake")) return .ruby;
    if (std.mem.endsWith(u8, path, ".md")) return .markdown;
    if (std.mem.endsWith(u8, path, ".json")) return .json;
    if (std.mem.endsWith(u8, path, ".yaml") or std.mem.endsWith(u8, path, ".yml")) return .yaml;
    return .unknown;
}

pub const SymbolResult = struct {
    path: []const u8,
    symbol: Symbol,
};

pub const SearchResult = struct {
    path: []const u8,
    line_num: u32,
    line_text: []const u8,
};

pub const TreeSort = enum {
    name,
    modified,
    size,
};

pub const TreeOptions = struct {
    path: ?[]const u8 = null,
    depth: ?u32 = null,
    max_nodes: ?u32 = null,
    include: []const []const u8 = &.{},
    sort: TreeSort = .name,
    dirs_first: bool = true,
};

const TreeNode = struct {
    full_path: []const u8,
    depth: u32,
    is_dir: bool,
    line_count: u32,
    symbol_count: usize,
    byte_size: u64,
    modified_ns: i128,
};

pub const IndexBudgetConfig = struct {
    max_ram_mb: u32 = 3800,
    target_seconds: u32 = 60,
    batch_min_files: u32 = 32,
    batch_max_files: u32 = 256,

    pub fn fromEnv() IndexBudgetConfig {
        const posix = std.posix;
        return fromEnvForTest(
            posix.getenv("FFAST_MAX_RAM_MB"),
            posix.getenv("FFAST_INDEX_TARGET_SECONDS"),
            posix.getenv("FFAST_BATCH_MIN_FILES"),
            posix.getenv("FFAST_BATCH_MAX_FILES"),
        );
    }

    pub fn fromEnvForTest(
        max_ram_raw: ?[]const u8,
        target_sec_raw: ?[]const u8,
        batch_min_raw: ?[]const u8,
        batch_max_raw: ?[]const u8,
    ) IndexBudgetConfig {
        var cfg = IndexBudgetConfig{};
        if (max_ram_raw) |v| {
            cfg.max_ram_mb = std.fmt.parseInt(u32, v, 10) catch 3800;
        }
        if (target_sec_raw) |v| {
            cfg.target_seconds = std.fmt.parseInt(u32, v, 10) catch 60;
        }
        if (batch_min_raw) |v| {
            cfg.batch_min_files = std.fmt.parseInt(u32, v, 10) catch 32;
        }
        if (batch_max_raw) |v| {
            cfg.batch_max_files = std.fmt.parseInt(u32, v, 10) catch 256;
        }
        return cfg;
    }
};

pub const Explorer = struct {
    outlines: std.StringHashMap(FileOutline),
    dep_graph: std.StringHashMap(std.ArrayList([]const u8)),
    contents: std.StringHashMap([]const u8),
    word_index: WordIndex,
    allocator: std.mem.Allocator,
    mu: std.Thread.RwLock = .{},
    root_dir: ?std.fs.Dir = null,

    pub fn setRoot(self: *Explorer, root_path: []const u8) void {
        self.root_dir = std.fs.cwd().openDir(root_path, .{}) catch null;
    }
    pub fn init(allocator: std.mem.Allocator) Explorer {
        return .{
            .outlines = std.StringHashMap(FileOutline).init(allocator),
            .dep_graph = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),
            .contents = std.StringHashMap([]const u8).init(allocator),
            .word_index = WordIndex.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Explorer) void {
        var iter = self.outlines.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.outlines.deinit();

        var dep_iter = self.dep_graph.iterator();
        while (dep_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.dep_graph.deinit();

        var content_iter = self.contents.iterator();
        while (content_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.contents.deinit();

        self.word_index.deinit();
        if (self.root_dir) |*d| d.close();
    }

    pub fn releaseContents(self: *Explorer) void {
        self.mu.lock();
        defer self.mu.unlock();
        var content_iter = self.contents.iterator();
        while (content_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.contents.clearAndFree();
    }

    /// Fast path: index outline only, skip content storage and word indexes.
    /// Content is loaded lazily from disk when needed for search.
    pub fn indexFileOutlineOnly(self: *Explorer, path: []const u8, content: []const u8) !void {
        return self.indexFileInner(path, content, false, false);
    }

    /// Index outline + word index + content.
    pub fn indexFileSkipTrigram(self: *Explorer, path: []const u8, content: []const u8) !void {
        return self.indexFileInner(path, content, true, true);
    }

    /// Index outline + content + word index (full indexing).
    pub fn indexFile(self: *Explorer, path: []const u8, content: []const u8) !void {
        return self.indexFileInner(path, content, true, true);
    }

    /// indexFileInner: full_index controls word index,
    /// store_content controls whether content is stored in memory (disable for fast scan).
    fn indexFileInner(self: *Explorer, path: []const u8, content: []const u8, full_index: bool, store_content: bool) !void {
        // Parse outline outside the global explorer write lock.
        // This keeps HTTP/MCP readers from being blocked on line-by-line parsing.
        var outline = FileOutline.init(self.allocator, path);
        errdefer outline.deinit();
        outline.byte_size = content.len;

        var line_num: u32 = 0;
        var prev_line_trimmed: []const u8 = "";
        var php_state: PhpParseState = .{};
        var in_py_docstring = false;
        var in_block_comment = false;
        var in_go_import_block = false;
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            line_num += 1;
            var trimmed = std.mem.trim(u8, line, " \t");

            // Track Python triple-quote docstrings (#111)
            if (outline.language == .python) {
                const triple_count = std.mem.count(u8, trimmed, "\"\"\"") + std.mem.count(u8, trimmed, "'''");
                if (in_py_docstring) {
                    if (triple_count > 0) in_py_docstring = false;
                    continue;
                }
                // Detect docstring/triple-quoted string open
                if (triple_count >= 2) {
                    // Single-line: """text""" or x = """text""" — skip, no state change
                    continue;
                }
                if (triple_count == 1) {
                    // Unmatched triple-quote anywhere on line opens multi-line mode
                    // Catches: """text, '''text, x = """, etc.
                    in_py_docstring = true;
                    continue;
                }
            }

            // Track Ruby =begin/=end block comments (must be at column 0 per Ruby spec)
            if (outline.language == .ruby) {
                if (in_py_docstring) {
                    if (startsWith(line, "=end")) in_py_docstring = false;
                    continue;
                }
                if (startsWith(line, "=begin")) {
                    in_py_docstring = true;
                    continue;
                }
            }

            // Track block comments for all languages that use /* */
            if (outline.language == .typescript or outline.language == .javascript or
                outline.language == .go_lang or outline.language == .c or
                outline.language == .cpp or outline.language == .rust or
                outline.language == .zig)
            {
                if (in_block_comment) {
                    if (std.mem.indexOf(u8, trimmed, "*/")) |close_pos| {
                        in_block_comment = false;
                        const after = std.mem.trimLeft(u8, trimmed[close_pos + 2 ..], " \t");
                        if (after.len == 0) continue;
                        trimmed = after; // parse code after */ on the same line
                    } else continue;
                }
                if (std.mem.startsWith(u8, trimmed, "/*")) {
                    if (std.mem.indexOf(u8, trimmed[2..], "*/")) |close_pos| {
                        // Single-line /* ... */ — check for code after it
                        const after = std.mem.trimLeft(u8, trimmed[2 + close_pos + 2 ..], " \t");
                        if (after.len == 0) continue;
                        trimmed = after;
                    } else {
                        in_block_comment = true;
                        continue;
                    }
                }
            }

            if (outline.language == .zig) {
                try self.parseZigLine(trimmed, line_num, &outline);
            } else if (outline.language == .python) {
                try self.parsePythonLine(trimmed, line_num, &outline);
            } else if (outline.language == .typescript or outline.language == .javascript) {
                try self.parseTsLine(trimmed, line_num, &outline);
            } else if (outline.language == .rust) {
                try self.parseRustLine(trimmed, line_num, &outline, prev_line_trimmed);
            } else if (outline.language == .php) {
                try self.parsePhpLine(trimmed, line_num, &outline, &php_state);
            } else if (outline.language == .go_lang) {
                // Handle Go import block: import ( "fmt" \n "net/http" )
                if (in_go_import_block) {
                    if (startsWith(trimmed, ")")) {
                        in_go_import_block = false;
                    } else if (extractStringLiteral(trimmed)) |imp_path| {
                        const import_copy = try self.allocator.dupe(u8, imp_path);
                        errdefer self.allocator.free(import_copy);
                        try outline.imports.append(self.allocator, import_copy);
                        const symbol_copy = try self.allocator.dupe(u8, trimmed);
                        errdefer self.allocator.free(symbol_copy);
                        try outline.symbols.append(self.allocator, .{
                            .name = symbol_copy,
                            .kind = .import,
                            .line_start = line_num,
                            .line_end = line_num,
                        });
                    }
                } else if (std.mem.eql(u8, trimmed, "import (")) {
                    in_go_import_block = true;
                } else {
                    try self.parseGoLine(trimmed, line_num, &outline);
                }
            } else if (outline.language == .ruby) {
                try self.parseRubyLine(trimmed, line_num, &outline);
            }

            prev_line_trimmed = trimmed;
        }
        outline.line_count = line_num;

        self.mu.lock();
        defer self.mu.unlock();

        // Reuse existing key if file was already indexed, else dupe.
        const outline_gop = try self.outlines.getOrPut(path);
        const is_new = !outline_gop.found_existing;
        var prior_outline: ?FileOutline = if (outline_gop.found_existing)
            outline_gop.value_ptr.*
        else
            null;
        const stable_path = if (outline_gop.found_existing) blk: {
            break :blk outline_gop.key_ptr.*;
        } else blk: {
            const duped = try self.allocator.dupe(u8, path);
            outline_gop.key_ptr.* = duped;
            break :blk duped;
        };
        // If we added a new entry but later fail, remove it so the map stays consistent.
        errdefer if (is_new) {
            _ = self.outlines.remove(stable_path);
            self.allocator.free(stable_path);
        };

        // Ensure outline path uses the stable map key.
        outline.path = stable_path;

        // Only store content in memory if store_content is true.
        // This is disabled for fast scan to reduce RAM usage.
        var prior_content: ?[]const u8 = null;
        if (store_content) {
            const duped_content = try self.allocator.dupe(u8, content);
            errdefer self.allocator.free(duped_content);
            const content_gop = try self.contents.getOrPut(stable_path);
            if (content_gop.found_existing) {
                prior_content = content_gop.value_ptr.*;
            } else {
                content_gop.key_ptr.* = stable_path;
            }
            content_gop.value_ptr.* = duped_content;
            errdefer {
                if (content_gop.found_existing) {
                    content_gop.value_ptr.* = prior_content.?;
                } else {
                    _ = self.contents.remove(stable_path);
                }
            }
        }

        // Build search indexes.
        if (full_index) {
            try self.word_index.indexFile(stable_path, content);
        }

        try self.rebuildDepsFor(stable_path, &outline);

        outline_gop.value_ptr.* = outline;
        if (store_content) {
            if (prior_content) |old_content| {
                self.allocator.free(old_content);
            }
        }
        if (prior_outline) |*old_outline| {
            old_outline.deinit();
        }
    }
    pub fn removeFile(self: *Explorer, path: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.dep_graph.getPtr(path)) |deps| {
            deps.deinit(self.allocator);
            _ = self.dep_graph.remove(path);
        }
        if (self.contents.getPtr(path)) |content| {
            self.allocator.free(content.*);
            _ = self.contents.remove(path);
        }
        self.word_index.removeFile(path);

        if (self.outlines.fetchRemove(path)) |kv| {
            var outline = kv.value;
            outline.deinit();
            self.allocator.free(kv.key);
        }
    }

    pub fn getOutline(self: *Explorer, path: []const u8, allocator: std.mem.Allocator) !?FileOutline {
        self.mu.lockShared();
        defer self.mu.unlockShared();

        const outline = self.outlines.getPtr(path) orelse return null;
        return try cloneOutline(outline, allocator);
    }

    /// Return a caller-owned copy of cached file content.
    pub fn getContent(self: *Explorer, path: []const u8, allocator: std.mem.Allocator) !?[]u8 {
        self.mu.lockShared();
        defer self.mu.unlockShared();
        const ref = self.readContentForSearch(path, allocator) orelse return null;
        if (ref.owned) return @constCast(ref.data);
        return try allocator.dupe(u8, ref.data);
    }

    const ContentRef = struct {
        data: []const u8,
        owned: bool, // true = caller must free; false = borrowed from cache
        allocator: std.mem.Allocator,

        fn deinit(self: ContentRef) void {
            if (self.owned) self.allocator.free(self.data);
        }
    };

    /// Get content: zero-copy from cache, or read from disk (caller-owned).
    fn readContentForSearch(self: *Explorer, path: []const u8, allocator: std.mem.Allocator) ?ContentRef {
        if (self.contents.get(path)) |cached| {
            return .{ .data = cached, .owned = false, .allocator = allocator };
        }
        const dir = self.root_dir orelse std.fs.cwd();
        const file = dir.openFile(path, .{}) catch return null;
        defer file.close();
        const data = file.readToEndAlloc(allocator, 512 * 1024) catch return null;
        return .{ .data = data, .owned = true, .allocator = allocator };
    }

    fn cloneOutline(src: *const FileOutline, allocator: std.mem.Allocator) !FileOutline {
        const copied_path = try allocator.dupe(u8, src.path);
        // No errdefer here: dst.deinit() below handles freeing copied_path via owns_path.

        var dst = FileOutline.init(allocator, copied_path);
        dst.owns_path = true;
        errdefer dst.deinit();
        dst.line_count = src.line_count;
        dst.byte_size = src.byte_size;
        for (src.symbols.items) |sym| {
            const copied_name = try allocator.dupe(u8, sym.name);
            errdefer allocator.free(copied_name);

            const copied_detail = if (sym.detail) |d| blk: {
                const detail = try allocator.dupe(u8, d);
                break :blk detail;
            } else null;
            errdefer if (copied_detail) |d| allocator.free(d);

            try dst.symbols.append(allocator, .{
                .name = copied_name,
                .kind = sym.kind,
                .line_start = sym.line_start,
                .line_end = sym.line_end,
                .detail = copied_detail,
            });
        }
        for (src.imports.items) |imp| {
            const copied_import = try allocator.dupe(u8, imp);
            errdefer allocator.free(copied_import);
            try dst.imports.append(allocator, copied_import);
        }

        return dst;
    }

    pub fn getTree(self: *Explorer, allocator: std.mem.Allocator, use_color: bool) ![]u8 {
        return self.getTreeWithOptions(allocator, use_color, .{});
    }

    pub fn getTreeWithOptions(self: *Explorer, allocator: std.mem.Allocator, use_color: bool, options: TreeOptions) ![]u8 {
        const s = @import("style.zig").style(use_color);

        self.mu.lockShared();
        defer self.mu.unlockShared();

        var buf: std.ArrayList(u8) = .{};
        errdefer buf.deinit(allocator);
        const writer = buf.writer(allocator);

        const include = options.include;
        const base_path = if (options.path) |raw| std.mem.trim(u8, raw, " /") else "";

        var nodes: std.ArrayList(TreeNode) = .{};
        defer nodes.deinit(allocator);

        var seen_dirs = std.StringHashMap(void).init(allocator);
        defer seen_dirs.deinit();

        var iter = self.outlines.iterator();
        while (iter.next()) |entry| {
            const path = entry.key_ptr.*;
            const outline = self.outlines.get(path) orelse continue;

            if (!pathMatchesBase(path, base_path)) continue;

            const rel_from_base = if (base_path.len == 0)
                path
            else if (std.mem.eql(u8, path, base_path))
                ""
            else
                path[base_path.len + 1 ..];

            const file_depth: u32 = if (rel_from_base.len == 0)
                0
            else
                @intCast(std.mem.count(u8, rel_from_base, "/"));

            if (options.depth) |max_depth| {
                if (file_depth > max_depth) continue;
            }

            if (include.len > 0 and !matchesAnyInclude(include, rel_from_base, path)) continue;

            // Emit directory nodes we haven't seen yet
            var prefix_end: usize = 0;
            while (std.mem.indexOfScalarPos(u8, path, prefix_end, '/')) |sep| {
                const dir = path[0 .. sep + 1];
                if (!pathMatchesBase(dir[0 .. dir.len - 1], base_path)) {
                    prefix_end = sep + 1;
                    continue;
                }
                if (!seen_dirs.contains(dir)) {
                    try seen_dirs.put(dir, {});

                    const dir_no_trailing = dir[0 .. dir.len - 1];
                    const rel_dir = if (base_path.len == 0)
                        dir_no_trailing
                    else if (std.mem.eql(u8, dir_no_trailing, base_path))
                        ""
                    else
                        dir_no_trailing[base_path.len + 1 ..];

                    const dir_depth: u32 = if (rel_dir.len == 0)
                        0
                    else
                        @intCast(std.mem.count(u8, rel_dir, "/"));

                    if (options.depth) |max_depth| {
                        if (dir_depth > max_depth) {
                            prefix_end = sep + 1;
                            continue;
                        }
                    }

                    const dir_mtime = getMtimeNs(self.root_dir, dir_no_trailing);

                    try nodes.append(allocator, .{
                        .full_path = dir,
                        .depth = dir_depth,
                        .is_dir = true,
                        .line_count = 0,
                        .symbol_count = 0,
                        .byte_size = 0,
                        .modified_ns = dir_mtime,
                    });
                }
                prefix_end = sep + 1;
            }

            const file_mtime = getMtimeNs(self.root_dir, path);
            try nodes.append(allocator, .{
                .full_path = path,
                .depth = file_depth,
                .is_dir = false,
                .line_count = outline.line_count,
                .symbol_count = outline.symbols.items.len,
                .byte_size = outline.byte_size,
                .modified_ns = file_mtime,
            });
        }

        std.mem.sort(TreeNode, nodes.items, options, struct {
            fn lessThan(opts: TreeOptions, a: TreeNode, b: TreeNode) bool {
                const parent_a = parentOf(a.full_path, a.is_dir);
                const parent_b = parentOf(b.full_path, b.is_dir);

                if (opts.sort == .name) {
                    if (opts.dirs_first and std.mem.eql(u8, parent_a, parent_b) and a.is_dir != b.is_dir) {
                        return a.is_dir;
                    }
                    return std.mem.order(u8, a.full_path, b.full_path) == .lt;
                }

                if (opts.dirs_first and a.is_dir != b.is_dir) return a.is_dir;

                if (a.depth != b.depth) return a.depth < b.depth;

                const parent_ord = std.mem.order(u8, parent_a, parent_b);
                if (parent_ord != .eq) return parent_ord == .lt;

                return switch (opts.sort) {
                    .name => unreachable,
                    .modified => if (a.modified_ns == b.modified_ns)
                        std.mem.order(u8, baseName(a.full_path, a.is_dir), baseName(b.full_path, b.is_dir)) == .lt
                    else
                        a.modified_ns > b.modified_ns,
                    .size => if (a.byte_size == b.byte_size)
                        std.mem.order(u8, baseName(a.full_path, a.is_dir), baseName(b.full_path, b.is_dir)) == .lt
                    else
                        a.byte_size > b.byte_size,
                };
            }
        }.lessThan);

        var emitted: u32 = 0;
        for (nodes.items) |node| {
            if (options.max_nodes) |max_nodes| {
                if (emitted >= max_nodes) break;
            }

            for (0..node.depth) |_| try writer.writeAll("  ");

            if (node.is_dir) {
                try writer.print("{s}{s}/{s}\n", .{ s.bold, baseName(node.full_path, true), s.reset });
            } else {
                try writer.print("{s}  {s}{d}L  {d} sym{s}\n", .{
                    baseName(node.full_path, false),
                    s.dim,
                    node.line_count,
                    node.symbol_count,
                    s.reset,
                });
            }

            emitted += 1;
        }

        return buf.toOwnedSlice(allocator);
    }

    fn pathMatchesBase(path: []const u8, base_path: []const u8) bool {
        if (base_path.len == 0) return true;
        if (std.mem.eql(u8, path, base_path)) return true;
        if (!std.mem.startsWith(u8, path, base_path)) return false;
        return path.len > base_path.len and path[base_path.len] == '/';
    }

    fn treeHasSlash(s: []const u8) bool {
        return std.mem.indexOfScalar(u8, s, '/') != null;
    }

    fn wildcardMatch(pattern: []const u8, text: []const u8) bool {
        var pi: usize = 0;
        var ti: usize = 0;
        var star_pi: ?usize = null;
        var star_ti: usize = 0;

        while (ti < text.len) {
            if (pi < pattern.len and pattern[pi] == '*') {
                if (pi + 1 < pattern.len and pattern[pi + 1] == '*') {
                    pi += 1;
                }
                star_pi = pi;
                pi += 1;
                star_ti = ti;
            } else if (pi < pattern.len and pattern[pi] == text[ti]) {
                pi += 1;
                ti += 1;
            } else if (star_pi) |s| {
                pi = s + 1;
                star_ti += 1;
                ti = star_ti;
            } else {
                return false;
            }
        }

        while (pi < pattern.len and pattern[pi] == '*') : (pi += 1) {}
        return pi == pattern.len;
    }

    fn matchesAnyInclude(patterns: []const []const u8, rel_path: []const u8, full_path: []const u8) bool {
        if (patterns.len == 0) return true;
        const rel_base = baseNameFromPath(rel_path);
        const full_base = baseNameFromPath(full_path);

        for (patterns) |pattern| {
            if (pattern.len == 0) continue;
            if (treeHasSlash(pattern)) {
                if (wildcardMatch(pattern, rel_path) or wildcardMatch(pattern, full_path)) return true;
            } else {
                if (wildcardMatch(pattern, rel_base) or wildcardMatch(pattern, full_base)) return true;
            }
        }
        return false;
    }

    fn baseName(path: []const u8, is_dir: bool) []const u8 {
        const stable = if (is_dir and path.len > 0 and path[path.len - 1] == '/') path[0 .. path.len - 1] else path;
        return baseNameFromPath(stable);
    }

    fn baseNameFromPath(path: []const u8) []const u8 {
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |pos| {
            return path[pos + 1 ..];
        }
        return path;
    }

    fn parentOf(path: []const u8, is_dir: bool) []const u8 {
        const stable = if (is_dir and path.len > 0 and path[path.len - 1] == '/') path[0 .. path.len - 1] else path;
        if (std.mem.lastIndexOfScalar(u8, stable, '/')) |pos| {
            return stable[0..pos];
        }
        return "";
    }

    fn getMtimeNs(root_dir: ?std.fs.Dir, path: []const u8) i128 {
        if (path.len == 0) return 0;
        if (root_dir) |dir| {
            const stat = dir.statFile(path) catch return 0;
            return stat.mtime;
        }
        const stat = std.fs.cwd().statFile(path) catch return 0;
        return stat.mtime;
    }

    pub fn findSymbol(self: *Explorer, name: []const u8, allocator: std.mem.Allocator) !?struct { path: []const u8, symbol: Symbol } {
        self.mu.lockShared();
        defer self.mu.unlockShared();

        var iter = self.outlines.iterator();
        while (iter.next()) |entry| {
            for (entry.value_ptr.symbols.items) |sym| {
                if (std.mem.eql(u8, sym.name, name)) {
                    return .{
                        .path = try allocator.dupe(u8, entry.key_ptr.*),
                        .symbol = .{
                            .name = try allocator.dupe(u8, sym.name),
                            .kind = sym.kind,
                            .line_start = sym.line_start,
                            .line_end = sym.line_end,
                            .detail = if (sym.detail) |d| try allocator.dupe(u8, d) else null,
                        },
                    };
                }
            }
        }
        return null;
    }

    pub fn findAllSymbols(self: *Explorer, name: []const u8, allocator: std.mem.Allocator) ![]const SymbolResult {
        self.mu.lockShared();
        defer self.mu.unlockShared();

        var result_list: std.ArrayList(SymbolResult) = .{};
        errdefer result_list.deinit(allocator);
        var iter = self.outlines.iterator();
        while (iter.next()) |entry| {
            for (entry.value_ptr.symbols.items) |sym| {
                if (std.mem.eql(u8, sym.name, name)) {
                    try result_list.append(allocator, .{
                        .path = try allocator.dupe(u8, entry.key_ptr.*),
                        .symbol = .{
                            .name = try allocator.dupe(u8, sym.name),
                            .kind = sym.kind,
                            .line_start = sym.line_start,
                            .line_end = sym.line_end,
                            .detail = if (sym.detail) |d| try allocator.dupe(u8, d) else null,
                        },
                    });
                }
            }
        }
        return result_list.toOwnedSlice(allocator);
    }

    pub fn searchContent(self: *Explorer, query: []const u8, allocator: std.mem.Allocator, max_results: usize) ![]const SearchResult {
        self.mu.lockShared();
        defer self.mu.unlockShared();

        var result_list: std.ArrayList(SearchResult) = .{};
        errdefer result_list.deinit(allocator);

        var iter = self.outlines.keyIterator();
        while (iter.next()) |key_ptr| {
            const ref = self.readContentForSearch(key_ptr.*, allocator) orelse continue;
            defer ref.deinit();
            try searchInContent(key_ptr.*, ref.data, query, allocator, max_results, &result_list);
            if (result_list.items.len >= max_results) break;
        }

        return result_list.toOwnedSlice(allocator);
    }

    /// Search file contents using a regex pattern.
    pub fn searchContentRegex(self: *Explorer, pattern: []const u8, allocator: std.mem.Allocator, max_results: usize) ![]const SearchResult {
        self.mu.lockShared();
        defer self.mu.unlockShared();

        var result_list: std.ArrayList(SearchResult) = .{};
        errdefer result_list.deinit(allocator);

        var iter = self.outlines.keyIterator();
        while (iter.next()) |key_ptr| {
            const ref = self.readContentForSearch(key_ptr.*, allocator) orelse continue;
            defer ref.deinit();
            try searchInContentRegex(key_ptr.*, ref.data, pattern, allocator, max_results, &result_list);
            if (result_list.items.len >= max_results) break;
        }

        return result_list.toOwnedSlice(allocator);
    }

    /// Search for a word using the inverted word index. O(1) lookup.
    pub fn searchWord(self: *Explorer, word: []const u8, allocator: std.mem.Allocator) ![]const idx.WordHit {
        self.mu.lockShared();
        defer self.mu.unlockShared();
        return self.word_index.searchDeduped(word, allocator);
    }

    pub const FuzzyMatch = struct {
        path: []const u8,
        score: f32,
    };

    pub fn fuzzyFindFiles(self: *Explorer, query: []const u8, allocator: std.mem.Allocator, max_results: usize) ![]const FuzzyMatch {
        if (query.len == 0) return &.{};

        self.mu.lockShared();
        defer self.mu.unlockShared();

        // Parse query: split on spaces, extract extension constraints (*.py, *.ts)
        var parts: std.ArrayList([]const u8) = .{};
        defer parts.deinit(allocator);
        var ext_filter: ?[]const u8 = null;

        var tok_iter = std.mem.splitScalar(u8, query, ' ');
        while (tok_iter.next()) |token| {
            if (token.len == 0) continue;
            // Extension constraint: *.py, *.ts, *.zig
            if (token.len >= 2 and token[0] == '*' and token[1] == '.') {
                ext_filter = token[1..]; // ".py", ".ts", etc.
            } else {
                try parts.append(allocator, token);
            }
        }

        if (parts.items.len == 0) return &.{};

        var matches: std.ArrayList(FuzzyMatch) = .{};
        errdefer matches.deinit(allocator);

        var iter = self.outlines.keyIterator();
        while (iter.next()) |key_ptr| {
            const path = key_ptr.*;

            // Extension filter
            if (ext_filter) |ext| {
                if (!std.mem.endsWith(u8, path, ext)) continue;
            }

            // Multi-part scoring: all parts must match, scores sum
            var total_score: f32 = 0;
            var all_matched = true;
            for (parts.items) |part| {
                if (fuzzyScore(part, path)) |s| {
                    total_score += s;
                } else {
                    all_matched = false;
                    break;
                }
            }

            if (all_matched and total_score > 0) {
                try matches.append(allocator, .{ .path = path, .score = total_score });
            }
        }

        // Sort by score descending
        std.mem.sort(FuzzyMatch, matches.items, {}, struct {
            fn lt(_: void, a: FuzzyMatch, b: FuzzyMatch) bool {
                return a.score > b.score;
            }
        }.lt);

        // Truncate to max_results
        if (matches.items.len > max_results) {
            matches.items.len = max_results;
        }

        return matches.toOwnedSlice(allocator) catch {
            matches.deinit(allocator);
            return &.{};
        };
    }

    pub fn getImportedBy(self: *Explorer, path: []const u8, allocator: std.mem.Allocator) ![]const []const u8 {
        self.mu.lockShared();
        defer self.mu.unlockShared();

        // Extract basename for matching against raw import strings
        // e.g., "src/store.zig" -> "store.zig"
        const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |pos| path[pos + 1 ..] else path;

        var result: std.ArrayList([]const u8) = .{};
        errdefer {
            for (result.items) |p| allocator.free(p);
            result.deinit(allocator);
        }

        var iter = self.dep_graph.iterator();
        while (iter.next()) |entry| {
            for (entry.value_ptr.items) |dep| {
                if (std.mem.eql(u8, dep, path) or std.mem.eql(u8, dep, basename)) {
                    const dep_path = try allocator.dupe(u8, entry.key_ptr.*);
                    try result.append(allocator, dep_path);
                    break;
                }
            }
        }
        return result.toOwnedSlice(allocator);
    }

    pub fn getImports(self: *Explorer, path: []const u8, allocator: std.mem.Allocator) ![]const []const u8 {
        self.mu.lockShared();
        defer self.mu.unlockShared();

        const deps = self.dep_graph.get(path) orelse return &.{};
        var result: std.ArrayList([]const u8) = .{};
        errdefer {
            for (result.items) |p| allocator.free(p);
            result.deinit(allocator);
        }
        for (deps.items) |dep| {
            const copy = try allocator.dupe(u8, dep);
            try result.append(allocator, copy);
        }
        return result.toOwnedSlice(allocator);
    }

    pub fn getHotFiles(self: *Explorer, store: *Store, allocator: std.mem.Allocator, limit: usize) ![]const []const u8 {
        // Collect stable path copies under explorer lock.
        var path_list: std.ArrayList([]u8) = .{};
        errdefer {
            for (path_list.items) |path| allocator.free(path);
            path_list.deinit(allocator);
        }
        defer path_list.deinit(allocator);
        {
            self.mu.lockShared();
            defer self.mu.unlockShared();
            var iter = self.outlines.iterator();
            while (iter.next()) |kv| {
                const path_copy = try allocator.dupe(u8, kv.key_ptr.*);
                try path_list.append(allocator, path_copy);
            }
        }

        // Query store seqs without holding explorer lock.
        const Entry = struct { path: []u8, seq: u64 };
        var entries: std.ArrayList(Entry) = .{};
        defer entries.deinit(allocator);
        {
            store.mu.lock();
            defer store.mu.unlock();
            for (path_list.items) |path| {
                const seq = store.getLatestSeqUnlocked(path);
                try entries.append(allocator, .{ .path = path, .seq = seq });
            }
        }

        std.mem.sort(Entry, entries.items, {}, struct {
            fn cmp(_: void, a: Entry, b: Entry) bool {
                return a.seq > b.seq;
            }
        }.cmp);

        const count = @min(limit, entries.items.len);
        const paths = try allocator.alloc([]const u8, count);
        for (entries.items[0..count], 0..) |e, i| {
            paths[i] = e.path;
        }
        for (entries.items[count..]) |e| {
            allocator.free(e.path);
        }
        return paths;
    }
    // ── Language parsers ──────────────────────────────────────

    fn parseZigLine(self: *Explorer, line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;
        if (startsWith(line, "pub fn ") or startsWith(line, "fn ")) {
            const start: usize = if (startsWith(line, "pub fn ")) 7 else 3;
            if (extractIdent(line[start..])) |name| {
                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                const detail_copy = try a.dupe(u8, line);
                errdefer a.free(detail_copy);
                try outline.symbols.append(a, .{
                    .name = name_copy,
                    .kind = .function,
                    .line_start = line_num,
                    .line_end = line_num,
                    .detail = detail_copy,
                });
            }
        } else if (startsWith(line, "pub const ") or startsWith(line, "const ")) {
            const start: usize = if (startsWith(line, "pub const ")) 10 else 6;
            if (extractIdent(line[start..])) |name| {
                const kind: SymbolKind = if (std.mem.indexOf(u8, line, "struct {") != null)
                    .struct_def
                else if (std.mem.indexOf(u8, line, "enum {") != null)
                    .enum_def
                else if (std.mem.indexOf(u8, line, "union {") != null or
                    std.mem.indexOf(u8, line, "union(enum) {") != null)
                    .union_def
                else if (std.mem.indexOf(u8, line, "@import") != null)
                    .import
                else
                    .constant;

                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                const detail_copy = try a.dupe(u8, line);
                errdefer a.free(detail_copy);
                try outline.symbols.append(a, .{
                    .name = name_copy,
                    .kind = kind,
                    .line_start = line_num,
                    .line_end = line_num,
                    .detail = detail_copy,
                });

                if (kind == .import) {
                    if (extractStringLiteral(line)) |import_path| {
                        const import_copy = try a.dupe(u8, import_path);
                        errdefer a.free(import_copy);
                        try outline.imports.append(a, import_copy);
                    }
                }
            }
        } else if (startsWith(line, "test ")) {
            const name_copy = try a.dupe(u8, line);
            errdefer a.free(name_copy);
            try outline.symbols.append(a, .{
                .name = name_copy,
                .kind = .test_decl,
                .line_start = line_num,
                .line_end = line_num,
            });
        }
    }

    fn parsePythonLine(self: *Explorer, line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;
        if (startsWith(line, "def ")) {
            if (extractIdent(line[4..])) |name| {
                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                const detail_copy = try a.dupe(u8, line);
                errdefer a.free(detail_copy);
                try outline.symbols.append(a, .{
                    .name = name_copy,
                    .kind = .function,
                    .line_start = line_num,
                    .line_end = line_num,
                    .detail = detail_copy,
                });
            }
        } else if (startsWith(line, "class ")) {
            if (extractIdent(line[6..])) |name| {
                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                const detail_copy = try a.dupe(u8, line);
                errdefer a.free(detail_copy);
                try outline.symbols.append(a, .{
                    .name = name_copy,
                    .kind = .struct_def,
                    .line_start = line_num,
                    .line_end = line_num,
                    .detail = detail_copy,
                });
            }
        } else if (startsWith(line, "import ") or startsWith(line, "from ")) {
            const symbol_copy = try a.dupe(u8, line);
            errdefer a.free(symbol_copy);
            try outline.symbols.append(a, .{
                .name = symbol_copy,
                .kind = .import,
                .line_start = line_num,
                .line_end = line_num,
            });
            // Extract module path and convert dots to slashes for dep matching.
            // "from mypackage.utils.helpers import X" → "mypackage/utils/helpers.py"
            // "import os.path" → "os/path.py"
            if (extractPythonModulePath(line)) |mod_path| {
                var buf: [512]u8 = undefined;
                var pos: usize = 0;
                for (mod_path) |c| {
                    if (pos >= buf.len - 3) break;
                    buf[pos] = if (c == '.') '/' else c;
                    pos += 1;
                }
                if (pos + 3 <= buf.len) {
                    buf[pos] = '.';
                    buf[pos + 1] = 'p';
                    buf[pos + 2] = 'y';
                    pos += 3;
                }
                const import_copy = try a.dupe(u8, buf[0..pos]);
                errdefer a.free(import_copy);
                try outline.imports.append(a, import_copy);
            }
        }
    }
    fn parseTsLine(self: *Explorer, line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;
        if (startsWith(line, "function ") or
            startsWith(line, "export function ") or
            startsWith(line, "async function ") or
            startsWith(line, "export async function "))
        {
            if (std.mem.indexOf(u8, line, "function ")) |fn_pos| {
                if (extractIdent(line[fn_pos + "function ".len ..])) |name| {
                    const name_copy = try a.dupe(u8, name);
                    errdefer a.free(name_copy);
                    const detail_copy = try a.dupe(u8, line);
                    errdefer a.free(detail_copy);
                    try outline.symbols.append(a, .{
                        .name = name_copy,
                        .kind = .function,
                        .line_start = line_num,
                        .line_end = line_num,
                        .detail = detail_copy,
                    });
                }
            }
        } else if (startsWith(line, "export const ") or startsWith(line, "export let ") or startsWith(line, "export var ")) {
            const ident_start: usize = if (startsWith(line, "export const "))
                "export const ".len
            else if (startsWith(line, "export let "))
                "export let ".len
            else
                "export var ".len;
            if (extractIdent(line[ident_start..])) |name| {
                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                const detail_copy = try a.dupe(u8, line);
                errdefer a.free(detail_copy);
                try outline.symbols.append(a, .{
                    .name = name_copy,
                    .kind = .constant,
                    .line_start = line_num,
                    .line_end = line_num,
                    .detail = detail_copy,
                });
            }
        }
        if (containsAny(line, &.{ "import ", "require(" })) {
            const symbol_copy = try a.dupe(u8, line);
            errdefer a.free(symbol_copy);
            try outline.symbols.append(a, .{
                .name = symbol_copy,
                .kind = .import,
                .line_start = line_num,
                .line_end = line_num,
            });
            if (extractStringLiteral(line)) |path| {
                const import_copy = try a.dupe(u8, path);
                errdefer a.free(import_copy);
                try outline.imports.append(a, import_copy);
            }
        }
    }

    fn parseRustLine(self: *Explorer, line: []const u8, line_num: u32, outline: *FileOutline, prev_line: []const u8) !void {
        const a = self.allocator;

        // fn / pub fn / pub(crate) fn / async fn / pub async fn / unsafe fn
        if (containsAny(line, &.{"fn "})) {
            const is_decl = startsWith(line, "fn ") or
                startsWith(line, "pub fn ") or
                startsWith(line, "pub(crate) fn ") or
                startsWith(line, "pub(super) fn ") or
                startsWith(line, "async fn ") or
                startsWith(line, "pub async fn ") or
                startsWith(line, "unsafe fn ") or
                startsWith(line, "pub unsafe fn ") or
                startsWith(line, "pub(crate) async fn ") or
                startsWith(line, "pub(crate) unsafe fn ") or
                startsWith(line, "pub unsafe extern ");
            if (is_decl) {
                if (std.mem.indexOf(u8, line, "fn ")) |fn_pos| {
                    if (extractIdent(line[fn_pos + 3 ..])) |name| {
                        const is_test = std.mem.eql(u8, prev_line, "#[test]") or
                            startsWith(prev_line, "#[tokio::test");
                        const kind: SymbolKind = if (is_test) .test_decl else .function;
                        const name_copy = try a.dupe(u8, name);
                        errdefer a.free(name_copy);
                        const detail_copy = try a.dupe(u8, line);
                        errdefer a.free(detail_copy);
                        try outline.symbols.append(a, .{
                            .name = name_copy,
                            .kind = kind,
                            .line_start = line_num,
                            .line_end = line_num,
                            .detail = detail_copy,
                        });
                    }
                }
            }
        }

        // struct
        if (startsWith(line, "struct ") or startsWith(line, "pub struct ") or startsWith(line, "pub(crate) struct ")) {
            if (std.mem.indexOf(u8, line, "struct ")) |pos| {
                if (extractIdent(line[pos + 7 ..])) |name| {
                    const name_copy = try a.dupe(u8, name);
                    errdefer a.free(name_copy);
                    const detail_copy = try a.dupe(u8, line);
                    errdefer a.free(detail_copy);
                    try outline.symbols.append(a, .{
                        .name = name_copy,
                        .kind = .struct_def,
                        .line_start = line_num,
                        .line_end = line_num,
                        .detail = detail_copy,
                    });
                }
            }
        }

        // enum
        if (startsWith(line, "enum ") or startsWith(line, "pub enum ") or startsWith(line, "pub(crate) enum ")) {
            if (std.mem.indexOf(u8, line, "enum ")) |pos| {
                if (extractIdent(line[pos + 5 ..])) |name| {
                    const name_copy = try a.dupe(u8, name);
                    errdefer a.free(name_copy);
                    const detail_copy = try a.dupe(u8, line);
                    errdefer a.free(detail_copy);
                    try outline.symbols.append(a, .{
                        .name = name_copy,
                        .kind = .enum_def,
                        .line_start = line_num,
                        .line_end = line_num,
                        .detail = detail_copy,
                    });
                }
            }
        }

        // trait
        if (startsWith(line, "trait ") or startsWith(line, "pub trait ") or startsWith(line, "pub(crate) trait ") or startsWith(line, "unsafe trait ") or startsWith(line, "pub unsafe trait ")) {
            if (std.mem.indexOf(u8, line, "trait ")) |pos| {
                if (extractIdent(line[pos + 6 ..])) |name| {
                    const name_copy = try a.dupe(u8, name);
                    errdefer a.free(name_copy);
                    const detail_copy = try a.dupe(u8, line);
                    errdefer a.free(detail_copy);
                    try outline.symbols.append(a, .{
                        .name = name_copy,
                        .kind = .trait_def,
                        .line_start = line_num,
                        .line_end = line_num,
                        .detail = detail_copy,
                    });
                }
            }
        }

        // impl
        if (startsWith(line, "impl ") or startsWith(line, "impl<") or startsWith(line, "unsafe impl ")) {
            const impl_start: usize = if (startsWith(line, "unsafe impl ")) 12 else if (startsWith(line, "impl<")) blk: {
                if (std.mem.indexOf(u8, line, "> ")) |gt| {
                    break :blk gt + 2;
                } else break :blk 5;
            } else 5;
            if (extractIdent(line[impl_start..])) |name| {
                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                const detail_copy = try a.dupe(u8, line);
                errdefer a.free(detail_copy);
                try outline.symbols.append(a, .{
                    .name = name_copy,
                    .kind = .impl_block,
                    .line_start = line_num,
                    .line_end = line_num,
                    .detail = detail_copy,
                });
            }
        }

        // type alias
        if (startsWith(line, "type ") or startsWith(line, "pub type ") or startsWith(line, "pub(crate) type ")) {
            if (std.mem.indexOf(u8, line, "type ")) |pos| {
                if (extractIdent(line[pos + 5 ..])) |name| {
                    const name_copy = try a.dupe(u8, name);
                    errdefer a.free(name_copy);
                    const detail_copy = try a.dupe(u8, line);
                    errdefer a.free(detail_copy);
                    try outline.symbols.append(a, .{
                        .name = name_copy,
                        .kind = .type_alias,
                        .line_start = line_num,
                        .line_end = line_num,
                        .detail = detail_copy,
                    });
                }
            }
        }

        // const / static
        if (startsWith(line, "const ") or startsWith(line, "pub const ") or startsWith(line, "pub(crate) const ") or
            startsWith(line, "static ") or startsWith(line, "pub static ") or startsWith(line, "pub(crate) static "))
        {
            const keyword = if (std.mem.indexOf(u8, line, "static ")) |_| "static " else "const ";
            if (std.mem.indexOf(u8, line, keyword)) |pos| {
                if (extractIdent(line[pos + keyword.len ..])) |name| {
                    const name_copy = try a.dupe(u8, name);
                    errdefer a.free(name_copy);
                    const detail_copy = try a.dupe(u8, line);
                    errdefer a.free(detail_copy);
                    try outline.symbols.append(a, .{
                        .name = name_copy,
                        .kind = .constant,
                        .line_start = line_num,
                        .line_end = line_num,
                        .detail = detail_copy,
                    });
                }
            }
        }

        // macro_rules!
        if (startsWith(line, "macro_rules!")) {
            if (extractIdent(line[13..])) |name| {
                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                const detail_copy = try a.dupe(u8, line);
                errdefer a.free(detail_copy);
                try outline.symbols.append(a, .{
                    .name = name_copy,
                    .kind = .macro_def,
                    .line_start = line_num,
                    .line_end = line_num,
                    .detail = detail_copy,
                });
            }
        }

        // use / mod
        if (startsWith(line, "use ") or startsWith(line, "pub use ") or startsWith(line, "pub(crate) use ")) {
            const symbol_copy = try a.dupe(u8, line);
            errdefer a.free(symbol_copy);
            try outline.symbols.append(a, .{
                .name = symbol_copy,
                .kind = .import,
                .line_start = line_num,
                .line_end = line_num,
            });
            const import_copy = try a.dupe(u8, line);
            errdefer a.free(import_copy);
            try outline.imports.append(a, import_copy);
        } else if (startsWith(line, "mod ") or startsWith(line, "pub mod ") or startsWith(line, "pub(crate) mod ")) {
            if (std.mem.indexOf(u8, line, "mod ")) |pos| {
                if (extractIdent(line[pos + 4 ..])) |name| {
                    const name_copy = try a.dupe(u8, name);
                    errdefer a.free(name_copy);
                    try outline.symbols.append(a, .{
                        .name = name_copy,
                        .kind = .import,
                        .line_start = line_num,
                        .line_end = line_num,
                    });
                    const import_copy = try a.dupe(u8, name);
                    errdefer a.free(import_copy);
                    try outline.imports.append(a, import_copy);
                }
            }
        }
    }

    const PhpParseState = struct {
        in_class: bool = false,
        brace_depth: i32 = 0,
        class_brace_depth: i32 = 0,
        in_block_comment: bool = false,
    };

    fn parsePhpLine(self: *Explorer, raw_line: []const u8, line_num: u32, outline: *FileOutline, state: *PhpParseState) !void {
        const a = self.allocator;

        var line = raw_line;
        if (line.len == 0) return;
        if (state.in_block_comment) {
            if (std.mem.indexOf(u8, line, "*/")) |end| {
                state.in_block_comment = false;
                line = std.mem.trim(u8, line[end + 2 ..], " \t");
                if (line.len == 0) return;
            } else return;
        }
        if (startsWith(line, "<?php")) return;
        if (startsWith(line, "//") or startsWith(line, "#")) return;
        if (startsWith(line, "/*")) {
            if (std.mem.indexOf(u8, line, "*/") == null) state.in_block_comment = true;
            return;
        }

        if (startsWith(line, "use ") and std.mem.indexOf(u8, line, "\\") != null) {
            try self.parsePhpUseImport(a, line, line_num, outline);
            return;
        }

        if (self.phpMatchClassLike(line)) |match| {
            const name_copy = try a.dupe(u8, match.name);
            errdefer a.free(name_copy);
            const detail_copy = try a.dupe(u8, line);
            errdefer a.free(detail_copy);
            try outline.symbols.append(a, .{
                .name = name_copy,
                .kind = match.kind,
                .line_start = line_num,
                .line_end = line_num,
                .detail = detail_copy,
            });
            state.in_class = true;
            state.class_brace_depth = state.brace_depth;
        } else if (self.phpMatchConstant(line)) |name| {
            const name_copy = try a.dupe(u8, name);
            errdefer a.free(name_copy);
            const detail_copy = try a.dupe(u8, line);
            errdefer a.free(detail_copy);
            try outline.symbols.append(a, .{
                .name = name_copy,
                .kind = .constant,
                .line_start = line_num,
                .line_end = line_num,
                .detail = detail_copy,
            });
        } else if (std.mem.indexOf(u8, line, "function ")) |fn_pos| {
            const after_fn = line[fn_pos + 9 ..];
            if (extractIdent(after_fn)) |name| {
                const kind: SymbolKind = if (state.in_class) .method else .function;
                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                const detail_copy = try a.dupe(u8, line);
                errdefer a.free(detail_copy);
                try outline.symbols.append(a, .{
                    .name = name_copy,
                    .kind = kind,
                    .line_start = line_num,
                    .line_end = line_num,
                    .detail = detail_copy,
                });
            }
        }

        var in_string: u8 = 0;
        var escaped: bool = false;
        for (line) |ch| {
            if (in_string != 0) {
                if (escaped) {
                    escaped = false;
                } else if (ch == '\\') {
                    escaped = true;
                } else if (ch == in_string) {
                    in_string = 0;
                }
                continue;
            }
            if (ch == '\'' or ch == '"') {
                in_string = ch;
            } else if (ch == '{') {
                state.brace_depth += 1;
            } else if (ch == '}') {
                state.brace_depth -= 1;
                if (state.in_class and state.brace_depth <= state.class_brace_depth) {
                    state.in_class = false;
                }
            }
        }
    }

    fn parsePhpUseImport(_: *Explorer, a: std.mem.Allocator, line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const semi = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
        const use_body = std.mem.trim(u8, line[4..semi], " \t");
        if (use_body.len == 0) return;

        if (std.mem.indexOfScalar(u8, use_body, '{')) |brace_start| {
            const brace_end = std.mem.indexOfScalar(u8, use_body, '}') orelse use_body.len;
            const base = use_body[0..brace_start];
            const items_str = use_body[brace_start + 1 .. brace_end];

            const symbol_copy = try a.dupe(u8, line[0..semi]);
            errdefer a.free(symbol_copy);
            try outline.symbols.append(a, .{
                .name = symbol_copy,
                .kind = .import,
                .line_start = line_num,
                .line_end = line_num,
            });

            var items = std.mem.splitScalar(u8, items_str, ',');
            while (items.next()) |item| {
                const raw_item = std.mem.trim(u8, item, " \t");
                if (raw_item.len == 0) continue;
                const trimmed_item = phpStripAlias(raw_item);
                const full_ns = try a.alloc(u8, base.len + trimmed_item.len);
                defer a.free(full_ns);
                @memcpy(full_ns[0..base.len], base);
                @memcpy(full_ns[base.len..], trimmed_item);
                const path_copy = try phpNamespaceToPath(a, full_ns);
                errdefer a.free(path_copy);
                try outline.imports.append(a, path_copy);
            }
        } else {
            const symbol_copy = try a.dupe(u8, line[0..semi]);
            errdefer a.free(symbol_copy);
            try outline.symbols.append(a, .{
                .name = symbol_copy,
                .kind = .import,
                .line_start = line_num,
                .line_end = line_num,
            });
            const ns = phpStripAlias(use_body);
            const path_copy = try phpNamespaceToPath(a, ns);
            errdefer a.free(path_copy);
            try outline.imports.append(a, path_copy);
        }
    }

    fn phpStripAlias(s: []const u8) []const u8 {
        if (s.len < 4) return s;
        for (0..s.len - 3) |i| {
            if (s[i] == ' ' and (s[i + 1] == 'a' or s[i + 1] == 'A') and (s[i + 2] == 's' or s[i + 2] == 'S') and s[i + 3] == ' ') return s[0..i];
        }
        return s;
    }

    fn phpMatchConstant(_: *Explorer, line: []const u8) ?[]const u8 {
        const prefixes = [_][]const u8{
            "const ",
            "public const ",
            "protected const ",
            "private const ",
        };
        for (prefixes) |prefix| {
            if (startsWith(line, prefix)) {
                if (extractIdent(line[prefix.len..])) |name| {
                    if (!std.mem.eql(u8, name, "class")) return name;
                }
            }
        }
        return null;
    }

    const PhpClassMatch = struct {
        name: []const u8,
        kind: SymbolKind,
    };

    fn phpMatchClassLike(_: *Explorer, line: []const u8) ?PhpClassMatch {
        const class_keywords = [_]struct { prefix: []const u8, kind: SymbolKind }{
            .{ .prefix = "interface ", .kind = .interface_def },
            .{ .prefix = "trait ", .kind = .trait_def },
            .{ .prefix = "enum ", .kind = .enum_def },
            .{ .prefix = "class ", .kind = .class_def },
            .{ .prefix = "abstract class ", .kind = .class_def },
            .{ .prefix = "final class ", .kind = .class_def },
            .{ .prefix = "readonly class ", .kind = .class_def },
        };

        for (class_keywords) |kw| {
            if (startsWith(line, kw.prefix)) {
                if (extractIdent(line[kw.prefix.len..])) |name| {
                    return .{ .name = name, .kind = kw.kind };
                }
            }
        }
        return null;
    }

    fn parseGoLine(self: *Explorer, line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;
        // func name( or func (receiver) name(
        if (startsWith(line, "func ")) {
            // Skip "func (" for function literals
            const rest = line[5..];
            // Method with receiver: func (r *Type) Name(
            var name_start = rest;
            if (rest.len > 0 and rest[0] == '(') {
                // Skip past receiver: find ") "
                if (std.mem.indexOf(u8, rest, ") ")) |close| {
                    name_start = rest[close + 2 ..];
                }
            }
            if (extractIdent(name_start)) |name| {
                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                const detail_copy = try a.dupe(u8, line);
                errdefer a.free(detail_copy);
                try outline.symbols.append(a, .{
                    .name = name_copy,
                    .kind = .function,
                    .line_start = line_num,
                    .line_end = line_num,
                    .detail = detail_copy,
                });
            }
        } else if (startsWith(line, "type ")) {
            const rest = line[5..];
            if (extractIdent(rest)) |name| {
                const kind: SymbolKind = .struct_def;
                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                const detail_copy = try a.dupe(u8, line);
                errdefer a.free(detail_copy);
                try outline.symbols.append(a, .{
                    .name = name_copy,
                    .kind = kind,
                    .line_start = line_num,
                    .line_end = line_num,
                    .detail = detail_copy,
                });
            }
        } else if (startsWith(line, "import ")) {
            if (extractStringLiteral(line)) |path| {
                const import_copy = try a.dupe(u8, path);
                errdefer a.free(import_copy);
                try outline.imports.append(a, import_copy);
            }
            const symbol_copy = try a.dupe(u8, line);
            errdefer a.free(symbol_copy);
            try outline.symbols.append(a, .{
                .name = symbol_copy,
                .kind = .import,
                .line_start = line_num,
                .line_end = line_num,
            });
        } else if (startsWith(line, "const ") or startsWith(line, "var ")) {
            const skip = if (startsWith(line, "const ")) @as(usize, 6) else 4;
            if (extractIdent(line[skip..])) |name| {
                const kind: SymbolKind = if (startsWith(line, "const ")) .constant else .variable;
                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                const detail_copy = try a.dupe(u8, line);
                errdefer a.free(detail_copy);
                try outline.symbols.append(a, .{
                    .name = name_copy,
                    .kind = kind,
                    .line_start = line_num,
                    .line_end = line_num,
                    .detail = detail_copy,
                });
            }
        }
    }

    fn parseRubyLine(self: *Explorer, line: []const u8, line_num: u32, outline: *FileOutline) !void {
        const a = self.allocator;
        if (startsWith(line, "def ")) {
            // Handle "def self.method_name" — skip past "self."
            var name_start = line[4..];
            if (startsWith(name_start, "self.")) {
                name_start = name_start[5..];
            }
            if (extractRubyMethodName(name_start)) |name| {
                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                const detail_copy = try a.dupe(u8, line);
                errdefer a.free(detail_copy);
                try outline.symbols.append(a, .{
                    .name = name_copy,
                    .kind = .function,
                    .line_start = line_num,
                    .line_end = line_num,
                    .detail = detail_copy,
                });
            }
        } else if (startsWith(line, "class ")) {
            if (extractIdent(line[6..])) |name| {
                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                const detail_copy = try a.dupe(u8, line);
                errdefer a.free(detail_copy);
                try outline.symbols.append(a, .{
                    .name = name_copy,
                    .kind = .struct_def,
                    .line_start = line_num,
                    .line_end = line_num,
                    .detail = detail_copy,
                });
            }
        } else if (startsWith(line, "module ")) {
            if (extractIdent(line[7..])) |name| {
                const name_copy = try a.dupe(u8, name);
                errdefer a.free(name_copy);
                const detail_copy = try a.dupe(u8, line);
                errdefer a.free(detail_copy);
                try outline.symbols.append(a, .{
                    .name = name_copy,
                    .kind = .struct_def,
                    .line_start = line_num,
                    .line_end = line_num,
                    .detail = detail_copy,
                });
            }
        } else if (startsWith(line, "require ") or startsWith(line, "require_relative ")) {
            if (extractStringLiteral(line)) |path| {
                const import_copy = try a.dupe(u8, path);
                errdefer a.free(import_copy);
                try outline.imports.append(a, import_copy);
            }
            const symbol_copy = try a.dupe(u8, line);
            errdefer a.free(symbol_copy);
            try outline.symbols.append(a, .{
                .name = symbol_copy,
                .kind = .import,
                .line_start = line_num,
                .line_end = line_num,
            });
        }
    }

    fn rebuildDepsFor(self: *Explorer, path: []const u8, outline: *FileOutline) !void {
        var deps: std.ArrayList([]const u8) = .{};
        errdefer deps.deinit(self.allocator);

        for (outline.imports.items) |imp| {
            // Skip imports with path traversal sequences
            if (std.mem.indexOf(u8, imp, "..") != null) continue;
            try deps.append(self.allocator, imp);
        }

        const gop = try self.dep_graph.getOrPut(path);
        if (gop.found_existing) {
            var old = gop.value_ptr.*;
            gop.value_ptr.* = deps;
            old.deinit(self.allocator);
        } else {
            gop.key_ptr.* = path;
            gop.value_ptr.* = deps;
        }
    }

    /// Return the source body for a symbol given its file path and line range.
    /// Caller owns the returned slice.
    pub fn getSymbolBody(self: *Explorer, path: []const u8, line_start: u32, line_end: u32, allocator: std.mem.Allocator) !?[]u8 {
        self.mu.lockShared();
        defer self.mu.unlockShared();
        const ref = self.readContentForSearch(path, allocator) orelse return null;
        defer ref.deinit();
        return try extractLines(ref.data, line_start, line_end, true, false, .unknown, allocator);
    }

    /// Find the smallest enclosing symbol for a given line in a file.
    /// Must be called while holding at least a shared lock.
    fn findEnclosingSymbolLocked(self: *Explorer, path: []const u8, line_num: u32) ?Symbol {
        const outline = self.outlines.getPtr(path) orelse return null;
        var best: ?Symbol = null;
        var best_span: u32 = std.math.maxInt(u32);
        for (outline.symbols.items) |sym| {
            if (sym.line_start <= line_num and sym.line_end >= line_num) {
                const span = sym.line_end - sym.line_start;
                if (span < best_span) {
                    best = sym;
                    best_span = span;
                }
            }
        }
        if (best != null) return best;
        // Fallback: nearest preceding symbol
        var nearest: ?Symbol = null;
        var nearest_dist: u32 = std.math.maxInt(u32);
        for (outline.symbols.items) |sym| {
            if (sym.line_start <= line_num) {
                const dist = line_num - sym.line_start;
                if (dist < nearest_dist) {
                    nearest = sym;
                    nearest_dist = dist;
                }
            }
        }
        return nearest;
    }

    pub const ScopedSearchResult = struct {
        path: []const u8,
        line_num: u32,
        line_text: []const u8,
        scope_name: ?[]const u8 = null,
        scope_kind: ?SymbolKind = null,
        scope_start: u32 = 0,
        scope_end: u32 = 0,
    };

    /// Search content and annotate results with the enclosing symbol scope.
    pub fn searchContentWithScope(self: *Explorer, query: []const u8, allocator: std.mem.Allocator, max_results: usize) ![]const ScopedSearchResult {
        self.mu.lockShared();
        defer self.mu.unlockShared();

        var result_list: std.ArrayList(ScopedSearchResult) = .{};
        errdefer {
            for (result_list.items) |r| {
                allocator.free(r.line_text);
                allocator.free(r.path);
                if (r.scope_name) |n| allocator.free(n);
            }
            result_list.deinit(allocator);
        }

        var iter = self.outlines.keyIterator();
        while (iter.next()) |key_ptr| {
            const ref = self.readContentForSearch(key_ptr.*, allocator) orelse continue;
            defer ref.deinit();
            try self.searchInContentWithScope(key_ptr.*, ref.data, query, allocator, max_results, &result_list);
            if (result_list.items.len >= max_results) break;
        }

        return result_list.toOwnedSlice(allocator);
    }

    fn searchInContentWithScope(self: *Explorer, path: []const u8, content: []const u8, query: []const u8, allocator: std.mem.Allocator, max_results: usize, result_list: *std.ArrayList(ScopedSearchResult)) !void {
        var line_num: u32 = 0;
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            line_num += 1;
            if (indexOfCaseInsensitive(line, query) != null) {
                const line_text = try allocator.dupe(u8, line);
                errdefer allocator.free(line_text);
                const path_copy = try allocator.dupe(u8, path);
                errdefer allocator.free(path_copy);

                const scope = self.findEnclosingSymbolLocked(path, line_num);
                const scope_name = if (scope) |s| try allocator.dupe(u8, s.name) else null;
                errdefer if (scope_name) |n| allocator.free(n);

                try result_list.append(allocator, .{
                    .path = path_copy,
                    .line_num = line_num,
                    .line_text = line_text,
                    .scope_name = scope_name,
                    .scope_kind = if (scope) |s| s.kind else null,
                    .scope_start = if (scope) |s| s.line_start else 0,
                    .scope_end = if (scope) |s| s.line_end else 0,
                });
                if (result_list.items.len >= max_results) return;
            }
        }
    }
};

fn phpNamespaceToPath(allocator: std.mem.Allocator, ns: []const u8) ![]u8 {
    var parts: std.ArrayList(u8) = .{};
    errdefer parts.deinit(allocator);

    var first_segment = true;
    var iter = std.mem.splitScalar(u8, ns, '\\');
    while (iter.next()) |segment| {
        if (parts.items.len > 0) {
            try parts.append(allocator, '/');
        }
        if (first_segment) {
            for (segment) |ch| {
                try parts.append(allocator, std.ascii.toLower(ch));
            }
            first_segment = false;
        } else {
            try parts.appendSlice(allocator, segment);
        }
    }
    try parts.appendSlice(allocator, ".php");
    return try parts.toOwnedSlice(allocator);
}

/// Extract lines from content string as a range [start..end] (1-indexed, inclusive).
/// When line_numbers is true, prepends "{d:>5} | " prefix. When compact is true,
/// skips comment/blank lines based on language.
pub fn extractLines(content: []const u8, start: u32, end: u32, line_numbers: bool, compact: bool, language: Language, allocator: std.mem.Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    var line_num: u32 = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        line_num += 1;
        if (line_num < start) continue;
        if (line_num > end) break;
        if (compact and isCommentOrBlank(line, language)) continue;
        if (line_numbers) {
            try w.print("{d:>5} | {s}\n", .{ line_num, line });
        } else {
            try w.print("{s}\n", .{line});
        }
    }
    return buf.toOwnedSlice(allocator);
}

/// Returns true if a line is blank or a single-line comment for the given language.
pub fn isCommentOrBlank(line: []const u8, language: Language) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return true;
    return switch (language) {
        .zig, .rust, .go_lang => std.mem.startsWith(u8, trimmed, "//"),
        .python, .ruby => std.mem.startsWith(u8, trimmed, "#"),
        .javascript, .typescript, .c, .cpp => std.mem.startsWith(u8, trimmed, "//") or std.mem.startsWith(u8, trimmed, "/*") or std.mem.startsWith(u8, trimmed, "*"),
        else => false,
    };
}

fn searchInContent(path: []const u8, content: []const u8, query: []const u8, allocator: std.mem.Allocator, max_results: usize, result_list: *std.ArrayList(SearchResult)) !void {
    var line_num: u32 = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        line_num += 1;
        if (indexOfCaseInsensitive(line, query) != null) {
            const line_text = try allocator.dupe(u8, line);
            errdefer allocator.free(line_text);
            const path_copy = try allocator.dupe(u8, path);
            errdefer allocator.free(path_copy);
            try result_list.append(allocator, .{
                .path = path_copy,
                .line_num = line_num,
                .line_text = line_text,
            });
            if (result_list.items.len >= max_results) return;
        }
    }
}

fn searchInContentRegex(path: []const u8, content: []const u8, pattern: []const u8, allocator: std.mem.Allocator, max_results: usize, result_list: *std.ArrayList(SearchResult)) !void {
    var line_num: u32 = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        line_num += 1;
        if (regexMatch(line, pattern)) {
            const line_text = try allocator.dupe(u8, line);
            errdefer allocator.free(line_text);
            const path_copy = try allocator.dupe(u8, path);
            errdefer allocator.free(path_copy);
            try result_list.append(allocator, .{
                .path = path_copy,
                .line_num = line_num,
                .line_text = line_text,
            });
            if (result_list.items.len >= max_results) return;
        }
    }
}

/// Simple regex matcher — supports: . \s \w \d \S \W \D [chars] [^chars]
/// * + ? ^ $ | () and escaped literals.
/// Uses backtracking. Searches for a match anywhere in the string (unanchored).
pub fn regexMatch(haystack: []const u8, pattern: []const u8) bool {
    // Iterate through top-level | separators to prevent stack overflow with
    // many alternation branches.  No recursion; no fixed-size buffer needed.
    var prev: usize = 0;
    var i: usize = 0;
    var depth: usize = 0;
    var in_bracket = false;
    while (i < pattern.len) {
        const c = pattern[i];
        if (c == '\\' and i + 1 < pattern.len) {
            i += 2;
            continue;
        }
        if (c == '[') {
            in_bracket = true;
            i += 1;
            continue;
        }
        if (c == ']') {
            in_bracket = false;
            i += 1;
            continue;
        }
        if (in_bracket) {
            i += 1;
            continue;
        }
        if (c == '(') {
            depth += 1;
            i += 1;
            continue;
        }
        if (c == ')') {
            if (depth > 0) depth -= 1;
            i += 1;
            continue;
        }
        if (c == '|' and depth == 0) {
            if (regexMatchSingle(haystack, pattern[prev..i])) return true;
            prev = i + 1;
        }
        i += 1;
    }
    return regexMatchSingle(haystack, pattern[prev..]);
}

fn regexMatchSingle(haystack: []const u8, pattern: []const u8) bool {
    if (pattern.len > 0 and pattern[0] == '^') {
        return matchHere(haystack, pattern[1..], 0);
    }
    // Try match at every position (unanchored search)
    for (0..haystack.len + 1) |start| {
        if (matchHere(haystack, pattern, start)) return true;
    }
    return false;
}

fn matchHere(haystack: []const u8, pattern: []const u8, pos: usize) bool {
    var p: usize = 0;
    var h: usize = pos;

    while (p < pattern.len) {
        // End anchor
        if (pattern[p] == '$' and p + 1 == pattern.len) {
            return h == haystack.len;
        }

        // Alternation handled at top level in regexMatch
        if (pattern[p] == '|') return false;

        // Grouping with parens — handle alternation inside groups
        if (pattern[p] == '(') {
            // Find matching closing paren
            var depth: usize = 1;
            var end = p + 1;
            while (end < pattern.len and depth > 0) {
                if (pattern[end] == '\\' and end + 1 < pattern.len) {
                    end += 2;
                    continue;
                }
                if (pattern[end] == '(') depth += 1;
                if (pattern[end] == ')') depth -= 1;
                if (depth > 0) end += 1;
            }
            // end now points at ')' (or pattern.len if unmatched)
            const group_end = if (end < pattern.len) end else pattern.len;
            const group_content = pattern[p + 1 .. group_end];
            const after_group = if (group_end + 1 <= pattern.len) pattern[group_end + 1 ..] else "";

            // Split group content on top-level | within this group
            var branch_start: usize = 0;
            var d: usize = 0;
            var i: usize = 0;
            while (i < group_content.len) {
                if (group_content[i] == '\\' and i + 1 < group_content.len) {
                    i += 2;
                    continue;
                }
                if (group_content[i] == '(') d += 1;
                if (group_content[i] == ')') {
                    if (d > 0) d -= 1;
                }
                if (group_content[i] == '|' and d == 0) {
                    // Try this branch
                    if (matchGroupBranch(haystack, group_content[branch_start..i], after_group, h)) return true;
                    branch_start = i + 1;
                }
                i += 1;
            }
            // Try last branch
            return matchGroupBranch(haystack, group_content[branch_start..], after_group, h);
        }

        if (pattern[p] == ')') {
            p += 1;
            continue;
        }

        // Check for quantifier following current element
        const elem_end = elementEnd(pattern, p);
        if (elem_end < pattern.len) {
            const qc = pattern[elem_end];
            if (qc == '*') {
                return matchQuantified(haystack, pattern, p, elem_end, elem_end + 1, 0, h);
            }
            if (qc == '+') {
                return matchQuantified(haystack, pattern, p, elem_end, elem_end + 1, 1, h);
            }
            if (qc == '?') {
                // Try with one match
                if (h < haystack.len and matchElement(haystack[h], pattern, p, elem_end)) {
                    if (matchHere(haystack, pattern[elem_end + 1 ..], h + 1)) return true;
                }
                // Try without
                return matchHere(haystack, pattern[elem_end + 1 ..], h);
            }
            if (qc == '{') {
                // Parse {n}, {n,}, {n,m}
                var qi = elem_end + 1;
                var min_rep: usize = 0;
                while (qi < pattern.len and pattern[qi] >= '0' and pattern[qi] <= '9') {
                    min_rep = min_rep * 10 + (pattern[qi] - '0');
                    qi += 1;
                }
                var max_rep: usize = min_rep; // default {n} = exactly n
                if (qi < pattern.len and pattern[qi] == ',') {
                    qi += 1;
                    if (qi < pattern.len and pattern[qi] >= '0' and pattern[qi] <= '9') {
                        max_rep = 0;
                        while (qi < pattern.len and pattern[qi] >= '0' and pattern[qi] <= '9') {
                            max_rep = max_rep * 10 + (pattern[qi] - '0');
                            qi += 1;
                        }
                    } else {
                        max_rep = 256; // {n,} = at least n, cap at 256
                    }
                }
                if (qi < pattern.len and pattern[qi] == '}') {
                    qi += 1; // skip '}'
                    return matchQuantifiedRange(haystack, pattern, p, elem_end, qi, min_rep, max_rep, h);
                }
                // Malformed {…} — treat as literal
            }
        }

        // No quantifier — must match exactly one char
        if (h >= haystack.len) return false;
        if (!matchElement(haystack[h], pattern, p, elem_end)) return false;
        h += 1;
        p = elem_end;
    }

    return true; // pattern exhausted — match
}

/// Try matching a group branch followed by the rest of the pattern.
fn matchGroupBranch(haystack: []const u8, branch: []const u8, after: []const u8, pos: usize) bool {
    // Concatenate branch + after conceptually by matching branch first,
    // then continuing with after at the new position.
    // matchHere on branch tells us how far it consumes.
    // We need to try every possible consumption length of the branch.
    return matchBranchThenRest(haystack, branch, after, pos);
}

fn matchBranchThenRest(haystack: []const u8, branch: []const u8, rest: []const u8, pos: usize) bool {
    // If branch is empty, just try matching the rest
    if (branch.len == 0) return matchHere(haystack, rest, pos);

    // We need to find how many chars the branch consumes, then match rest.
    // Build a temporary combined pattern: branch + rest
    // This is safe because both are slices of the same original pattern string,
    // but they may not be adjacent. Use a simple approach: match branch, track position.
    var buf: [4096]u8 = undefined;
    if (branch.len + rest.len > buf.len) return false;
    @memcpy(buf[0..branch.len], branch);
    @memcpy(buf[branch.len .. branch.len + rest.len], rest);
    return matchHere(haystack, buf[0 .. branch.len + rest.len], pos);
}

/// Match a quantified element (greedy).
fn matchQuantified(haystack: []const u8, pattern: []const u8, elem_start: usize, elem_end: usize, rest_start: usize, min_count: usize, start_pos: usize) bool {
    // Count max matches
    var count: usize = 0;
    var h = start_pos;
    while (h < haystack.len and matchElement(haystack[h], pattern, elem_start, elem_end)) {
        count += 1;
        h += 1;
    }
    // Greedy: try from max matches down to min
    var c: usize = count + 1;
    while (c > min_count) {
        c -= 1;
        if (matchHere(haystack, pattern[rest_start..], start_pos + c)) return true;
    }
    return false;
}

/// Match a {n,m} quantified element (greedy).
fn matchQuantifiedRange(haystack: []const u8, pattern: []const u8, elem_start: usize, elem_end: usize, rest_start: usize, min_count: usize, max_count: usize, start_pos: usize) bool {
    // Count max matches up to max_count
    var count: usize = 0;
    var h = start_pos;
    while (h < haystack.len and count < max_count and matchElement(haystack[h], pattern, elem_start, elem_end)) {
        count += 1;
        h += 1;
    }
    if (count < min_count) return false;
    // Greedy: try from max matches down to min
    var c: usize = count + 1;
    while (c > min_count) {
        c -= 1;
        if (matchHere(haystack, pattern[rest_start..], start_pos + c)) return true;
    }
    return false;
}

/// Return the index past the current element in the pattern.
fn elementEnd(pattern: []const u8, p: usize) usize {
    if (p >= pattern.len) return p;
    if (pattern[p] == '\\' and p + 1 < pattern.len) return p + 2;
    if (pattern[p] == '[') {
        var i = p + 1;
        if (i < pattern.len and pattern[i] == '^') i += 1;
        if (i < pattern.len and pattern[i] == ']') i += 1;
        while (i < pattern.len and pattern[i] != ']') : (i += 1) {}
        if (i < pattern.len) i += 1;
        return i;
    }
    if (pattern[p] == '.') return p + 1;
    return p + 1;
}

/// Match a single character against a pattern element.
fn matchElement(c: u8, pattern: []const u8, start: usize, end: usize) bool {
    if (start >= end) return false;

    // Dot matches any char
    if (pattern[start] == '.' and end == start + 1) return true;

    // Escape sequences
    if (pattern[start] == '\\' and end == start + 2) {
        return switch (pattern[start + 1]) {
            'd' => std.ascii.isDigit(c),
            'D' => !std.ascii.isDigit(c),
            'w' => std.ascii.isAlphanumeric(c) or c == '_',
            'W' => !(std.ascii.isAlphanumeric(c) or c == '_'),
            's' => c == ' ' or c == '\t' or c == '\n' or c == '\r',
            'S' => !(c == ' ' or c == '\t' or c == '\n' or c == '\r'),
            'b', 'B' => false, // word boundary — not a char match
            else => c == pattern[start + 1],
        };
    }

    // Character class [...]
    if (pattern[start] == '[') {
        var i = start + 1;
        var negate = false;
        if (i < end and pattern[i] == '^') {
            negate = true;
            i += 1;
        }
        var matched = false;
        // Handle literal ] at start of class (e.g. []] or [^]])
        if (i < end and pattern[i] == ']') {
            if (c == ']') matched = true;
            i += 1;
        }
        while (i < end and pattern[i] != ']') {
            // Range: a-z, but only if '-' is not at end of class
            if (i + 2 < end and pattern[i + 1] == '-' and pattern[i + 2] != ']') {
                if (c >= pattern[i] and c <= pattern[i + 2]) matched = true;
                i += 3;
            } else {
                if (c == pattern[i]) matched = true;
                i += 1;
            }
        }
        return if (negate) !matched else matched;
    }

    // Literal
    return c == pattern[start];
}

fn indexOfCaseInsensitive(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    for (0..haystack.len - needle.len + 1) |i| {
        var match = true;
        for (0..needle.len) |j| {
            const hc = if (haystack[i + j] >= 'A' and haystack[i + j] <= 'Z') haystack[i + j] + 32 else haystack[i + j];
            const nc = if (needle[j] >= 'A' and needle[j] <= 'Z') needle[j] + 32 else needle[j];
            if (hc != nc) {
                match = false;
                break;
            }
        }
        if (match) return i;
    }
    return null;
}

fn startsWith(haystack: []const u8, needle: []const u8) bool {
    return std.mem.startsWith(u8, haystack, needle);
}

fn extractIdent(s: []const u8) ?[]const u8 {
    const max_ident_len: usize = 256;
    var end: usize = 0;
    for (s) |ch| {
        if (end >= max_ident_len) break;
        if (std.ascii.isAlphanumeric(ch) or ch == '_') {
            end += 1;
        } else break;
    }
    return if (end > 0) s[0..end] else null;
}

/// Extract a Ruby method name — supports trailing ?, !, = characters
fn extractRubyMethodName(s: []const u8) ?[]const u8 {
    const max_len: usize = 256;
    var end: usize = 0;
    for (s) |ch| {
        if (end >= max_len) break;
        if (std.ascii.isAlphanumeric(ch) or ch == '_') {
            end += 1;
        } else break;
    }
    if (end > 0 and end < s.len) {
        const suffix = s[end];
        if (suffix == '?' or suffix == '!' or suffix == '=') end += 1;
    }
    return if (end > 0) s[0..end] else null;
}

fn extractStringLiteral(s: []const u8) ?[]const u8 {
    const quote_chars = [_]u8{ '"', '\'' };
    for (quote_chars) |q| {
        if (std.mem.indexOfScalar(u8, s, q)) |start_pos| {
            if (std.mem.indexOfScalarPos(u8, s, start_pos + 1, q)) |end_pos| {
                return s[start_pos + 1 .. end_pos];
            }
        }
    }
    return null;
}

fn containsAny(s: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.mem.indexOf(u8, s, needle) != null) return true;
    }
    return false;
}

/// Extract the module path from a Python import line.
/// "from mypackage.utils.helpers import X" → "mypackage.utils.helpers"
/// "import os.path" → "os.path"
/// "from . import foo" / "from .rel import bar" → null (relative imports too ambiguous)
fn extractPythonModulePath(line: []const u8) ?[]const u8 {
    if (startsWith(line, "from ")) {
        const rest = std.mem.trimLeft(u8, line[5..], " \t");
        // Skip relative imports (start with dot)
        if (rest.len > 0 and rest[0] == '.') return null;
        // "from module.path import ..." — extract up to " import"
        if (std.mem.indexOf(u8, rest, " import")) |imp_pos| {
            const mod = std.mem.trimRight(u8, rest[0..imp_pos], " \t");
            if (mod.len > 0) return mod;
        }
        return null;
    } else if (startsWith(line, "import ")) {
        const rest = std.mem.trimLeft(u8, line[7..], " \t");
        // "import os.path" or "import foo" — take up to comma or space
        var end: usize = 0;
        while (end < rest.len and rest[end] != ' ' and rest[end] != ',' and rest[end] != '\t') : (end += 1) {}
        if (end > 0) return rest[0..end];
        return null;
    }
    return null;
}

// ── Fuzzy file matching ─────────────────────────────────────────

fn toLowerByte(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn isWordBoundary(path: []const u8, pi: usize) bool {
    if (pi == 0) return true;
    const prev = path[pi - 1];
    return prev == '/' or prev == '_' or prev == '-' or prev == '.' or prev == '\\';
}

fn isSpecialEntryPoint(filename: []const u8) bool {
    const specials = [_][]const u8{
        "main.zig",     "lib.zig",     "root.zig",
        "main.rs",      "lib.rs",      "mod.rs",
        "main.go",      "main.c",      "main.cpp",
        "index.ts",     "index.tsx",   "index.js",
        "index.jsx",    "index.mjs",   "index.cjs",
        "index.vue",    "index.php",   "main.rb",
        "index.rb",     "__init__.py", "__main__.py",
        "Makefile",     "build.zig",   "Cargo.toml",
        "package.json",
    };
    for (specials) |s| {
        if (std.mem.eql(u8, filename, s)) return true;
    }
    return false;
}

fn getFilename(path: []const u8) []const u8 {
    var i: usize = path.len;
    while (i > 0) : (i -= 1) {
        if (path[i - 1] == '/') return path[i..];
    }
    return path;
}

pub fn fuzzyScore(query: []const u8, path: []const u8) ?f32 {
    if (query.len == 0 or path.len == 0) return null;
    if (query.len > 128 or path.len > 512) return null;

    const MATCH_SCORE: f32 = 16.0;
    const MISMATCH_PENALTY: f32 = -8.0;
    const GAP_OPEN: f32 = -3.0;
    const GAP_EXTEND: f32 = -1.0;
    const DELIMITER_BONUS: f32 = 8.0;
    const FILENAME_BONUS: f32 = 6.0;
    const CONSECUTIVE_BONUS: f32 = 4.0;
    const CASE_BONUS: f32 = 2.0;
    const PREFIX_BONUS: f32 = 6.0;

    // Find filename start
    var fname_start: usize = 0;
    for (0..path.len) |i| {
        if (path[path.len - 1 - i] == '/') {
            fname_start = path.len - i;
            break;
        }
    }

    // Smith-Waterman-style DP with affine gaps
    // H[i][j] = best alignment score ending with query[0..i] aligned to path[0..j]
    // We use two rows to save memory: prev and curr
    const MAX_PATH = 512;
    var prev_h: [MAX_PATH + 1]f32 = undefined;
    var curr_h: [MAX_PATH + 1]f32 = undefined;
    var prev_gap: [MAX_PATH + 1]f32 = undefined; // gap in query (deletion from path)
    var curr_gap: [MAX_PATH + 1]f32 = undefined;

    // Init
    for (0..path.len + 1) |j| {
        prev_h[j] = 0;
        prev_gap[j] = GAP_OPEN;
    }

    var best_score: f32 = 0;
    var matched_chars: usize = 0;

    for (0..query.len) |i| {
        curr_h[0] = 0;
        curr_gap[0] = GAP_OPEN;
        var query_gap: f32 = GAP_OPEN; // gap in path (deletion from query)

        for (0..path.len) |j| {
            const qc = toLowerByte(query[i]);
            const pc = toLowerByte(path[j]);

            // Match/mismatch score
            var match_score: f32 = if (qc == pc) MATCH_SCORE else MISMATCH_PENALTY;

            // Bonuses for matches
            if (qc == pc) {
                // Exact case bonus
                if (query[i] == path[j]) match_score += CASE_BONUS;
                // Word boundary bonus
                if (isWordBoundary(path, j)) match_score += DELIMITER_BONUS;
                // Filename bonus
                if (j >= fname_start) match_score += FILENAME_BONUS;
                // Prefix bonus (match at start of path or filename)
                if (j == 0 or j == fname_start) match_score += PREFIX_BONUS;
                // Consecutive match bonus
                if (i > 0 and j > 0 and prev_h[j] > prev_h[j + 1] * 0.5) {
                    match_score += CONSECUTIVE_BONUS;
                }
            }

            const diag = prev_h[j] + match_score;

            // Affine gap penalties
            curr_gap[j + 1] = @max(prev_h[j + 1] + GAP_OPEN, prev_gap[j + 1] + GAP_EXTEND);
            query_gap = @max(curr_h[j] + GAP_OPEN, query_gap + GAP_EXTEND);

            // Smith-Waterman: take max of all options, floor at 0
            curr_h[j + 1] = @max(0, @max(diag, @max(curr_gap[j + 1], query_gap)));

            if (i == query.len - 1 and curr_h[j + 1] > best_score) {
                best_score = curr_h[j + 1];
            }
        }

        // Count matched chars (check if any cell in this row is positive)
        for (1..path.len + 1) |j| {
            if (curr_h[j] > 0) {
                matched_chars = i + 1;
                break;
            }
        }

        // Swap rows
        @memcpy(prev_h[0 .. path.len + 1], curr_h[0 .. path.len + 1]);
        @memcpy(prev_gap[0 .. path.len + 1], curr_gap[0 .. path.len + 1]);
    }

    // Require at least 60% of query chars to contribute to score
    if (best_score <= 0 or matched_chars < (query.len + 1) / 2) return null;

    // Minimum score threshold based on query length
    const min_threshold = @as(f32, @floatFromInt(query.len)) * MATCH_SCORE * 0.3;
    if (best_score < min_threshold) return null;

    // Special entry point bonus (like fff: main.go, index.ts, lib.rs rank higher)
    const fname = getFilename(path);
    if (isSpecialEntryPoint(fname)) best_score += best_score * 0.05;

    // Normalize by path length (shorter paths rank higher)
    const len_factor = @sqrt(@as(f32, @floatFromInt(path.len)));
    return best_score / len_factor;
}
