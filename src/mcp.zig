const std = @import("std");
const mcp_lib = @import("mcp");
const mcpj = mcp_lib.json;
const explore_mod = @import("explore.zig");
const Explorer = explore_mod.Explorer;
const TreeSort = explore_mod.TreeSort;
const Store = @import("store.zig").Store;
const snapshot_mod = @import("snapshot.zig");
const watcher = @import("watcher.zig");

pub const Tool = enum {
    ffast_tree,
    ffast_outline,
    ffast_search,
    ffast_deps,
    ffast_index,
    ffast_status,
    ffast_snapshot,
    ffast_changes,
};

const tools_list =
    \\{"tools":[
    \\{"name":"ffast_tree","description":"Project file tree (compact nested arrays)","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"Optional subtree path relative to project root"},"depth":{"type":"integer","description":"Maximum depth (0 = files directly under path)"},"max_nodes":{"type":"integer","description":"Maximum number of emitted nodes"},"include":{"description":"Optional include glob(s)","oneOf":[{"type":"string"},{"type":"array","items":{"type":"string"}}]},"sort":{"type":"string","enum":["name","modified","size"],"description":"Sort order for siblings"},"dirs_first":{"type":"boolean","description":"Whether directories sort before files (default: true)"}},"required":[]}},
    \\{"name":"ffast_outline","description":"File symbol outline","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"File path relative to project root"}},"required":["path"]}},
    \\{"name":"ffast_search","description":"Codebase text search","inputSchema":{"type":"object","properties":{"query":{"type":"string","description":"Query text or regex pattern"},"max_results":{"type":"integer","description":"Maximum matches to return (default: 50)"},"regex":{"type":"boolean","description":"Treat query as regex (default: false)"},"path":{"type":"string","description":"Optional path filter"}},"required":["query"]}},
    \\{"name":"ffast_deps","description":"Dependency graph: which files import this file (reverse deps) and what this file imports (forward deps)","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"File path relative to project root"}},"required":["path"]}},
    \\{"name":"ffast_index","description":"Index refresh","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"ffast_status","description":"Indexer status","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"ffast_snapshot","description":"Snapshot metadata/write","inputSchema":{"type":"object","properties":{"write":{"type":"boolean","description":"Write snapshot file before reporting metadata"}},"required":[]}},
    \\{"name":"ffast_changes","description":"Changes since sequence","inputSchema":{"type":"object","properties":{"since":{"type":"integer","description":"Sequence number to query from (default: 0)"}},"required":[]}}
    \\]}
;

pub fn toolsListForTest(alloc: std.mem.Allocator) ![]u8 {
    return try alloc.dupe(u8, tools_list);
}

pub fn writeToolError(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    code: []const u8,
    message: []const u8,
    hint: ?[]const u8,
) void {
    const w = out.writer(alloc);
    if (hint) |h| {
        w.writeAll("{\"error\":{\"code\":\"") catch return;
        mcpj.writeEscaped(alloc, out, code);
        w.writeAll("\",\"message\":\"") catch return;
        mcpj.writeEscaped(alloc, out, message);
        w.writeAll("\",\"hint\":\"") catch return;
        mcpj.writeEscaped(alloc, out, h);
        w.writeAll("\"}}") catch return;
    } else {
        w.writeAll("{\"error\":{\"code\":\"") catch return;
        mcpj.writeEscaped(alloc, out, code);
        w.writeAll("\",\"message\":\"") catch return;
        mcpj.writeEscaped(alloc, out, message);
        w.writeAll("\"}}") catch return;
    }
}

pub fn run(allocator: std.mem.Allocator) !void {
    const stdin = std.fs.File.stdin();
    const stdout = std.fs.File.stdout();
    var store = Store.init(allocator);
    defer store.deinit();
    var explorer = Explorer.init(allocator);
    defer explorer.deinit();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const project_root = std.fs.cwd().realpath(".", &root_buf) catch ".";
    var watcher_runtime = WatcherRuntime{};
    defer stopWatcher(&watcher_runtime);

    bootstrapIndex(&store, &explorer, project_root, allocator) catch |err| {
        std.log.warn("mcp bootstrap index failed: {}", .{err});
    };
    startWatcher(&store, &explorer, project_root, &watcher_runtime) catch |err| {
        std.log.warn("mcp watcher start failed: {}", .{err});
    };

    while (true) {
        const msg = mcpj.readLine(allocator, stdin) orelse break;
        defer allocator.free(msg);

        const input = std.mem.trim(u8, msg, " \t\r\n");
        if (input.len == 0) continue;

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, input, .{}) catch {
            writeError(allocator, stdout, null, -32700, "Parse error");
            continue;
        };
        defer parsed.deinit();

        if (parsed.value != .object) {
            writeError(allocator, stdout, null, -32600, "Invalid Request");
            continue;
        }

        const root = &parsed.value.object;
        const method = getStr(root, "method") orelse {
            if (root.contains("id")) writeError(allocator, stdout, root.get("id"), -32600, "Invalid Request");
            continue;
        };
        const id = root.get("id");
        const is_notification = !root.contains("id");

        if (mcpj.eql(method, "initialize")) {
            if (!is_notification) writeResult(allocator, stdout, id,
                \\{"protocolVersion":"2025-06-18","capabilities":{"tools":{"listChanged":false}},"serverInfo":{"name":"ffast","version":"0.4.4"}}
            );
        } else if (mcpj.eql(method, "notifications/initialized")) {
            continue;
        } else if (mcpj.eql(method, "tools/list")) {
            if (!is_notification) writeResult(allocator, stdout, id, tools_list);
        } else if (mcpj.eql(method, "tools/call")) {
            if (!is_notification) handleCall(allocator, stdout, id, root, &explorer, &store, project_root, watcher_runtime.running.load(.acquire));
        } else if (mcpj.eql(method, "ping")) {
            if (!is_notification) writeResult(allocator, stdout, id, "{}");
        } else {
            if (!is_notification) writeError(allocator, stdout, id, -32601, "Method not found");
        }
    }
}

pub const WatcherRuntime = struct {
    queue: watcher.EventQueue = .{},
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    scan_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn watcherThreadMain(store: *Store, explorer: *Explorer, root: []const u8, runtime: *WatcherRuntime) void {
    watcher.incrementalLoop(store, explorer, &runtime.queue, root, &runtime.shutdown, &runtime.scan_done);
    runtime.running.store(false, .release);
}

fn startWatcher(store: *Store, explorer: *Explorer, root: []const u8, runtime: *WatcherRuntime) !void {
    if (runtime.thread != null) return;
    runtime.shutdown.store(false, .release);
    runtime.scan_done.store(true, .release);
    runtime.running.store(true, .release);
    const t = try std.Thread.spawn(.{}, watcherThreadMain, .{ store, explorer, root, runtime });
    runtime.thread = t;
}

fn stopWatcher(runtime: *WatcherRuntime) void {
    runtime.shutdown.store(true, .release);
    if (runtime.thread) |t| {
        t.join();
        runtime.thread = null;
    }
    runtime.running.store(false, .release);
}

pub fn startWatcherForTest(store: *Store, explorer: *Explorer, root: []const u8, runtime: *WatcherRuntime) !void {
    return startWatcher(store, explorer, root, runtime);
}

pub fn stopWatcherForTest(runtime: *WatcherRuntime) void {
    stopWatcher(runtime);
}

fn bootstrapIndex(store: *Store, explorer: *Explorer, project_root: []const u8, allocator: std.mem.Allocator) !void {
    explorer.setRoot(project_root);
    try watcher.initialScanFast(store, explorer, project_root, allocator);
}

pub fn bootstrapIndexForTest(store: *Store, explorer: *Explorer, project_root: []const u8, allocator: std.mem.Allocator) !void {
    try bootstrapIndex(store, explorer, project_root, allocator);
}

fn handleCall(
    alloc: std.mem.Allocator,
    stdout: std.fs.File,
    id: ?std.json.Value,
    root: *const std.json.ObjectMap,
    explorer: *Explorer,
    store: *Store,
    project_root: []const u8,
    watcher_running: bool,
) void {
    const params_val = root.get("params") orelse {
        writeError(alloc, stdout, id, -32602, "Missing params");
        return;
    };
    if (params_val != .object) {
        writeError(alloc, stdout, id, -32602, "params must be object");
        return;
    }

    const params = &params_val.object;
    const name = getStr(params, "name") orelse {
        writeError(alloc, stdout, id, -32602, "Missing tool name");
        return;
    };

    const tool = std.meta.stringToEnum(Tool, name) orelse {
        writeError(alloc, stdout, id, -32602, "Unknown tool");
        return;
    };

    const args: *const std.json.ObjectMap = blk: {
        if (params.get("arguments")) |arguments| {
            if (arguments != .object) {
                writeError(alloc, stdout, id, -32602, "arguments must be object");
                return;
            }
            break :blk &arguments.object;
        }
        break :blk params;
    };

    const result = buildToolCallResult(alloc, tool, args, explorer, store, project_root, watcher_running) catch {
        writeError(alloc, stdout, id, -32603, "Internal error");
        return;
    };
    defer alloc.free(result);
    writeResult(alloc, stdout, id, result);
}

pub fn dispatchForTest(
    alloc: std.mem.Allocator,
    tool: Tool,
    args: *const std.json.ObjectMap,
    explorer: *Explorer,
) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(alloc);
    dispatch(alloc, tool, args, &out, explorer);
    return try alloc.dupe(u8, out.items);
}

pub fn dispatchForTestRuntime(
    alloc: std.mem.Allocator,
    tool: Tool,
    args: *const std.json.ObjectMap,
    explorer: *Explorer,
    store: *Store,
    project_root: []const u8,
    watcher_running: bool,
) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(alloc);
    dispatchRuntime(alloc, tool, args, &out, explorer, store, project_root, watcher_running);
    return try alloc.dupe(u8, out.items);
}

pub fn callToolForTestRuntime(
    alloc: std.mem.Allocator,
    tool: Tool,
    args: *const std.json.ObjectMap,
    explorer: *Explorer,
    store: *Store,
    project_root: []const u8,
    watcher_running: bool,
) ![]u8 {
    return try buildToolCallResult(alloc, tool, args, explorer, store, project_root, watcher_running);
}

fn dispatch(
    alloc: std.mem.Allocator,
    tool: Tool,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
    explorer: *Explorer,
) void {
    switch (tool) {
        .ffast_tree => handleTree(alloc, args, out, explorer),
        .ffast_outline => handleOutline(alloc, args, out, explorer),
        .ffast_search => handleSearch(alloc, args, out, explorer),
        .ffast_deps => handleDeps(alloc, args, out, explorer),
        else => writeToolError(alloc, out, "INTERNAL", "tool handler not implemented", null),
    }
}

fn dispatchRuntime(
    alloc: std.mem.Allocator,
    tool: Tool,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
    explorer: *Explorer,
    store: *Store,
    project_root: []const u8,
    watcher_running: bool,
) void {
    switch (tool) {
        .ffast_tree => handleTree(alloc, args, out, explorer),
        .ffast_outline => handleOutline(alloc, args, out, explorer),
        .ffast_search => handleSearch(alloc, args, out, explorer),
        .ffast_deps => handleDeps(alloc, args, out, explorer),
        .ffast_status => handleStatus(alloc, out, store, explorer, project_root, watcher_running),
        .ffast_changes => handleChanges(alloc, args, out, store),
        .ffast_index => handleIndex(alloc, out, store, explorer, project_root),
        .ffast_snapshot => handleSnapshot(alloc, args, out, explorer, project_root),
    }
}

fn handleSnapshot(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
    explorer: *Explorer,
    root: []const u8,
) void {
    const write = getBool(args, "write");
    const path = std.fmt.allocPrint(alloc, "{s}/ffast.snapshot", .{root}) catch {
        writeToolError(alloc, out, "INTERNAL", "snapshot path allocation failed", null);
        return;
    };
    defer alloc.free(path);

    if (write) {
        snapshot_mod.writeSnapshot(explorer, root, path, alloc) catch {
            writeToolError(alloc, out, "INTERNAL", "snapshot write failed", null);
            return;
        };
    }

    const stat = std.fs.cwd().statFile(path) catch {
        const w_missing = out.writer(alloc);
        w_missing.writeAll("{\"exists\":false,\"path\":\"") catch return;
        mcpj.writeEscaped(alloc, out, path);
        w_missing.print("\",\"wrote\":{s}}}", .{if (write) "true" else "false"}) catch return;
        return;
    };

    const w = out.writer(alloc);
    w.writeAll("{\"exists\":true,\"path\":\"") catch return;
    mcpj.writeEscaped(alloc, out, path);
    w.print("\",\"size_bytes\":{d},\"updated_at\":{d},\"wrote\":{s}}}", .{
        stat.size,
        stat.mtime,
        if (write) "true" else "false",
    }) catch return;
}

fn handleStatus(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    store: *Store,
    explorer: *Explorer,
    project_root: []const u8,
    watcher_running: bool,
) void {
    const w = out.writer(alloc);
    w.writeAll("{\"project_root\":\"") catch return;
    mcpj.writeEscaped(alloc, out, project_root);
    w.print("\",\"indexed_files\":{d},\"current_seq\":{d},\"watcher_running\":{s}}}", .{
        explorer.outlines.count(),
        store.currentSeq(),
        if (watcher_running) "true" else "false",
    }) catch return;
}

fn handleChanges(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
    store: *Store,
) void {
    const since: u64 = if (getInt(args, "since")) |n| @intCast(@max(0, n)) else 0;
    const changes = store.changesSinceDetailed(since, alloc) catch {
        writeToolError(alloc, out, "INTERNAL", "changes lookup failed", null);
        return;
    };
    defer alloc.free(changes);

    const w = out.writer(alloc);
    w.print("{{\"current_seq\":{d},\"changes\":[", .{store.currentSeq()}) catch return;
    for (changes, 0..) |c, i| {
        if (i != 0) w.writeAll(",") catch return;
        w.writeAll("{\"path\":\"") catch return;
        mcpj.writeEscaped(alloc, out, c.path);
        w.print("\",\"op\":\"{s}\",\"seq\":{d},\"timestamp_ms\":{d}}}", .{
            @tagName(c.op),
            c.seq,
            c.timestamp,
        }) catch return;
    }
    w.writeAll("]}") catch return;
}

fn handleIndex(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    store: *Store,
    explorer: *Explorer,
    root: []const u8,
) void {
    explorer.setRoot(root);
    watcher.initialScanFast(store, explorer, root, alloc) catch {
        writeToolError(alloc, out, "INTERNAL", "index refresh failed", null);
        return;
    };

    const w = out.writer(alloc);
    w.print("{{\"started\":true,\"indexed_files\":{d},\"current_seq\":{d}}}", .{
        explorer.outlines.count(),
        store.currentSeq(),
    }) catch return;
}

fn handleTree(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
    explorer: *Explorer,
) void {
    var include_list: std.ArrayList([]const u8) = .{};
    defer include_list.deinit(alloc);

    if (args.get("include")) |include_val| {
        switch (include_val) {
            .string => |s| {
                include_list.append(alloc, s) catch {
                    writeToolError(alloc, out, "INTERNAL", "include allocation failed", null);
                    return;
                };
            },
            .array => |arr| {
                for (arr.items) |item| {
                    if (item != .string) {
                        writeToolError(alloc, out, "INVALID_ARGUMENT", "include array must contain only strings", null);
                        return;
                    }
                    include_list.append(alloc, item.string) catch {
                        writeToolError(alloc, out, "INTERNAL", "include allocation failed", null);
                        return;
                    };
                }
            },
            else => {
                writeToolError(alloc, out, "INVALID_ARGUMENT", "include must be a string or string array", null);
                return;
            },
        }
    }

    const raw_path = getStr(args, "path");
    var path_buf: []u8 = &.{};
    defer if (path_buf.len > 0) alloc.free(path_buf);

    const path: ?[]const u8 = if (raw_path) |p| blk: {
        if (!isPathSafe(p)) {
            writeToolError(alloc, out, "OUT_OF_SCOPE", "path traversal not allowed", null);
            return;
        }
        const trimmed = std.mem.trim(u8, p, " /");
        if (trimmed.len == 0) break :blk null;
        if (watcher.isSensitivePath(trimmed)) {
            writeToolError(alloc, out, "OUT_OF_SCOPE", "sensitive file access blocked", null);
            return;
        }
        path_buf = alloc.dupe(u8, trimmed) catch {
            writeToolError(alloc, out, "INTERNAL", "path allocation failed", null);
            return;
        };
        break :blk path_buf;
    } else null;

    const depth_val = getInt(args, "depth");
    const max_nodes_val = getInt(args, "max_nodes");
    if (depth_val) |d| {
        if (d < 0) {
            writeToolError(alloc, out, "INVALID_ARGUMENT", "depth must be >= 0", null);
            return;
        }
    }
    if (max_nodes_val) |n| {
        if (n < 0) {
            writeToolError(alloc, out, "INVALID_ARGUMENT", "max_nodes must be >= 0", null);
            return;
        }
    }

    const sort: TreeSort = if (getStr(args, "sort")) |s|
        std.meta.stringToEnum(TreeSort, s) orelse {
            writeToolError(alloc, out, "INVALID_ARGUMENT", "sort must be one of: name, modified, size", null);
            return;
        }
    else
        .name;

    const tree = explorer.getTreeWithOptions(alloc, false, .{
        .path = path,
        .depth = if (depth_val) |d| @intCast(@max(0, d)) else null,
        .max_nodes = if (max_nodes_val) |n| @intCast(@max(0, n)) else null,
        .include = include_list.items,
        .sort = sort,
        .dirs_first = if (args.get("dirs_first") != null) getBool(args, "dirs_first") else true,
    }) catch {
        writeToolError(alloc, out, "INTERNAL", "tree generation failed", null);
        return;
    };
    defer alloc.free(tree);

    const entries = parseTreeEntries(alloc, tree) catch {
        writeToolError(alloc, out, "INTERNAL", "tree parsing failed", null);
        return;
    };
    defer alloc.free(entries);

    const w = out.writer(alloc);
    w.writeAll("{\"tree\":") catch return;
    var idx: usize = 0;
    writeCompactTreeArray(alloc, out, entries, &idx, 0);
    w.writeAll("}") catch return;
}

const TreeEntry = struct {
    depth: u32,
    text: []const u8,
    is_dir: bool,
};

fn parseTreeEntries(alloc: std.mem.Allocator, tree: []const u8) ![]TreeEntry {
    var lines = std.mem.splitScalar(u8, tree, '\n');
    var out_entries: std.ArrayList(TreeEntry) = .{};
    defer out_entries.deinit(alloc);

    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        var i: usize = 0;
        while (i < line.len and line[i] == ' ') : (i += 1) {}
        const depth: u32 = @intCast(i / 2);
        const text = std.mem.trimLeft(u8, line, " ");
        try out_entries.append(alloc, .{
            .depth = depth,
            .text = text,
            .is_dir = std.mem.endsWith(u8, text, "/"),
        });
    }

    return out_entries.toOwnedSlice(alloc);
}

fn writeCompactTreeArray(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    entries: []const TreeEntry,
    idx: *usize,
    depth: u32,
) void {
    const w = out.writer(alloc);
    w.writeAll("[") catch return;
    var first = true;

    while (idx.* < entries.len) {
        const e = entries[idx.*];
        if (e.depth < depth) break;
        if (e.depth > depth) break;

        if (!first) w.writeAll(",") catch return;
        first = false;

        w.writeByte('"') catch return;
        mcpj.writeEscaped(alloc, out, e.text);
        w.writeByte('"') catch return;
        idx.* += 1;

        if (e.is_dir) {
            w.writeAll(",") catch return;
            writeCompactTreeArray(alloc, out, entries, idx, depth + 1);
        }
    }

    w.writeAll("]") catch return;
}

fn handleOutline(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
    explorer: *Explorer,
) void {
    const path = getStr(args, "path") orelse {
        writeToolError(alloc, out, "INVALID_ARGUMENT", "missing path", "Provide 'path' as string");
        return;
    };
    if (!isPathSafe(path)) {
        writeToolError(alloc, out, "OUT_OF_SCOPE", "path traversal not allowed", null);
        return;
    }
    if (watcher.isSensitivePath(path)) {
        writeToolError(alloc, out, "OUT_OF_SCOPE", "sensitive file access blocked", null);
        return;
    }

    var outline = (explorer.getOutline(path, alloc) catch {
        writeToolError(alloc, out, "INTERNAL", "outline lookup failed", null);
        return;
    }) orelse {
        writeToolError(alloc, out, "OUT_OF_SCOPE", "path not indexed", null);
        return;
    };
    defer outline.deinit();

    const w = out.writer(alloc);
    w.writeAll("{\"path\":\"") catch return;
    mcpj.writeEscaped(alloc, out, outline.path);
    w.print("\",\"language\":\"{s}\",\"line_count\":{d},\"byte_size\":{d},\"symbols\":[", .{
        @tagName(outline.language),
        outline.line_count,
        outline.byte_size,
    }) catch return;

    for (outline.symbols.items, 0..) |sym, i| {
        if (i != 0) w.writeAll(",") catch return;
        w.writeAll("{\"name\":\"") catch return;
        mcpj.writeEscaped(alloc, out, sym.name);
        w.print("\",\"kind\":\"{s}\",\"line_start\":{d},\"line_end\":{d}", .{
            @tagName(sym.kind),
            sym.line_start,
            sym.line_end,
        }) catch return;
        if (sym.detail) |detail| {
            w.writeAll(",\"detail\":\"") catch return;
            mcpj.writeEscaped(alloc, out, detail);
            w.writeAll("\"}") catch return;
        } else {
            w.writeAll("}") catch return;
        }
    }
    w.writeAll("]}") catch return;
}

fn handleSearch(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
    explorer: *Explorer,
) void {
    const query = getStr(args, "query") orelse {
        writeToolError(alloc, out, "INVALID_ARGUMENT", "missing query", "Provide 'query' as string");
        return;
    };

    if (getStr(args, "path")) |path| {
        if (!isPathSafe(path)) {
            writeToolError(alloc, out, "OUT_OF_SCOPE", "path traversal not allowed", null);
            return;
        }
        if (watcher.isSensitivePath(path)) {
            writeToolError(alloc, out, "OUT_OF_SCOPE", "sensitive file access blocked", null);
            return;
        }
    }

    const max_results: usize = if (getInt(args, "max_results")) |n|
        @intCast(@max(1, @min(n, 10000)))
    else
        50;
    const regex = getBool(args, "regex");

    const results = if (regex)
        explorer.searchContentRegex(query, alloc, max_results) catch {
            writeToolError(alloc, out, "REGEX_INVALID", "regex search failed", null);
            return;
        }
    else
        explorer.searchContent(query, alloc, max_results) catch {
            writeToolError(alloc, out, "INTERNAL", "search failed", null);
            return;
        };
    defer {
        for (results) |r| {
            alloc.free(r.path);
            alloc.free(r.line_text);
        }
        alloc.free(results);
    }

    const w = out.writer(alloc);
    w.writeAll("{\"matches\":[") catch return;
    for (results, 0..) |r, i| {
        if (i != 0) w.writeAll(",") catch return;
        w.writeAll("{\"path\":\"") catch return;
        mcpj.writeEscaped(alloc, out, r.path);
        w.writeAll("\",\"line\":") catch return;
        w.print("{d}", .{r.line_num}) catch return;
        w.writeAll(",\"text\":\"") catch return;
        mcpj.writeEscaped(alloc, out, r.line_text);
        w.writeAll("\"}") catch return;
    }
    w.writeAll("]}") catch return;
}

fn handleDeps(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
    explorer: *Explorer,
) void {
    const path = getStr(args, "path") orelse {
        writeToolError(alloc, out, "INVALID_ARGUMENT", "missing path", "Provide 'path' as string");
        return;
    };
    if (!isPathSafe(path)) {
        writeToolError(alloc, out, "OUT_OF_SCOPE", "path traversal not allowed", null);
        return;
    }
    if (watcher.isSensitivePath(path)) {
        writeToolError(alloc, out, "OUT_OF_SCOPE", "sensitive file access blocked", null);
        return;
    }

    const imported_by = explorer.getImportedBy(path, alloc) catch {
        writeToolError(alloc, out, "INTERNAL", "reverse dependency lookup failed", null);
        return;
    };
    defer {
        for (imported_by) |p| alloc.free(p);
        alloc.free(imported_by);
    }

    const imports = explorer.getImports(path, alloc) catch {
        writeToolError(alloc, out, "INTERNAL", "forward dependency lookup failed", null);
        return;
    };
    defer {
        for (imports) |p| alloc.free(p);
        alloc.free(imports);
    }

    const w = out.writer(alloc);
    w.writeAll("{\"path\":\"") catch return;
    mcpj.writeEscaped(alloc, out, path);
    w.writeAll("\",\"imported_by\":[") catch return;
    for (imported_by, 0..) |dep, i| {
        if (i != 0) w.writeAll(",") catch return;
        w.writeAll("\"") catch return;
        mcpj.writeEscaped(alloc, out, dep);
        w.writeAll("\"") catch return;
    }
    w.writeAll("],\"imports\":[") catch return;
    for (imports, 0..) |dep, i| {
        if (i != 0) w.writeAll(",") catch return;
        w.writeAll("\"") catch return;
        mcpj.writeEscaped(alloc, out, dep);
        w.writeAll("\"") catch return;
    }
    w.writeAll("]}") catch return;
}

fn writeResult(alloc: std.mem.Allocator, stdout: std.fs.File, id: ?std.json.Value, result: []const u8) void {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(alloc);
    buf.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    appendId(alloc, &buf, id);
    buf.appendSlice(alloc, ",\"result\":") catch return;
    appendSingleLineJson(alloc, &buf, result);
    buf.appendSlice(alloc, "}\n") catch return;
    stdout.writeAll(buf.items) catch {};
}

fn writeError(alloc: std.mem.Allocator, stdout: std.fs.File, id: ?std.json.Value, code: i32, msg: []const u8) void {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(alloc);
    buf.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":") catch return;
    appendId(alloc, &buf, id);
    buf.appendSlice(alloc, ",\"error\":{\"code\":") catch return;
    var tmp: [16]u8 = undefined;
    const c = std.fmt.bufPrint(&tmp, "{d}", .{code}) catch return;
    buf.appendSlice(alloc, c) catch return;
    buf.appendSlice(alloc, ",\"message\":\"") catch return;
    mcpj.writeEscaped(alloc, &buf, msg);
    buf.appendSlice(alloc, "\"}}\n") catch return;
    stdout.writeAll(buf.items) catch {};
}

fn appendSingleLineJson(alloc: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) void {
    for (value) |c| {
        if (c != '\n' and c != '\r') out.append(alloc, c) catch return;
    }
}

pub fn buildResultLineForTest(alloc: std.mem.Allocator, id: std.json.Value, result: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(alloc);

    try out.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":");
    appendId(alloc, &out, id);
    try out.appendSlice(alloc, ",\"result\":");
    appendSingleLineJson(alloc, &out, result);
    try out.appendSlice(alloc, "}\n");

    return try alloc.dupe(u8, out.items);
}

fn appendId(alloc: std.mem.Allocator, out: *std.ArrayList(u8), id: ?std.json.Value) void {
    if (id) |v| switch (v) {
        .integer => |n| {
            var tmp: [32]u8 = undefined;
            const n_str = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch return;
            out.appendSlice(alloc, n_str) catch return;
        },
        .string => |s| {
            out.append(alloc, '"') catch return;
            mcpj.writeEscaped(alloc, out, s);
            out.append(alloc, '"') catch return;
        },
        else => out.appendSlice(alloc, "null") catch return,
    } else {
        out.appendSlice(alloc, "null") catch return;
    }
}

const getStr = mcpj.getStr;
const getInt = mcpj.getInt;
const getBool = mcpj.getBool;

fn isPathSafe(path: []const u8) bool {
    if (path.len == 0) return false;
    if (std.mem.startsWith(u8, path, "/")) return false;
    if (std.mem.indexOf(u8, path, "../") != null) return false;
    if (std.mem.eql(u8, path, "..")) return false;
    if (std.mem.endsWith(u8, path, "/..")) return false;
    if (std.mem.indexOf(u8, path, "\\")) |_| return false;
    return true;
}

fn isToolErrorPayload(alloc: std.mem.Allocator, payload: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, payload, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    return parsed.value.object.contains("error");
}

fn buildToolCallResult(
    alloc: std.mem.Allocator,
    tool: Tool,
    args: *const std.json.ObjectMap,
    explorer: *Explorer,
    store: *Store,
    project_root: []const u8,
    watcher_running: bool,
) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    defer out.deinit(alloc);
    dispatchRuntime(alloc, tool, args, &out, explorer, store, project_root, watcher_running);

    const is_error = isToolErrorPayload(alloc, out.items);

    var result: std.ArrayList(u8) = .{};
    defer result.deinit(alloc);
    try result.appendSlice(alloc, "{\"content\":[{\"type\":\"text\",\"text\":\"");
    mcpj.writeEscaped(alloc, &result, out.items);
    if (is_error) {
        try result.appendSlice(alloc, "\"}],\"isError\":true}");
    } else {
        try result.appendSlice(alloc, "\"}],\"isError\":false}");
    }
    return try alloc.dupe(u8, result.items);
}
