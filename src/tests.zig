const std = @import("std");
const testing = std.testing;

test "ffast --help shows distilled command set" {
    const result = try std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &.{ "zig", "build", "run", "--", "--help" },
        .cwd = ".",
        .max_output_bytes = 32 * 1024,
    });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    try testing.expect(std.mem.indexOf(u8, result.stdout, "ffast") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "mcp") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "snapshot") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "--no-telemetry") == null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "serve") == null);
}

test "ffast CLI index command reports indexed files" {
    const main_cli = @import("main.zig");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("src");
    var file = try tmp.dir.createFile("src/main.zig", .{});
    defer file.close();
    try file.writeAll("pub fn main() void {}\n");

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &root_buf);

    const out = try main_cli.runCliCommand(testing.allocator, root, &.{ "index", "index" }, .index);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\"started\":true") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"indexed_files\":1") != null);
}

test "ffast CLI snapshot command writes ffast.snapshot" {
    const main_cli = @import("main.zig");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("src");
    var file = try tmp.dir.createFile("src/main.zig", .{});
    defer file.close();
    try file.writeAll("pub fn main() void {}\n");

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &root_buf);

    const out = try main_cli.runCliCommand(testing.allocator, root, &.{ "snapshot", "snapshot" }, .snapshot);
    defer testing.allocator.free(out);

    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/ffast.snapshot", .{root});
    defer testing.allocator.free(snap_path);

    try testing.expect(std.mem.indexOf(u8, out, "\"exists\":true") != null);
    try std.fs.cwd().access(snap_path, .{});
}

test "ffast detectLanguage supports required set" {
    const explore = @import("explore.zig");

    try testing.expect(explore.detectLanguage("a.zig") == .zig);
    try testing.expect(explore.detectLanguage("a.ts") == .typescript);
    try testing.expect(explore.detectLanguage("a.js") == .javascript);
    try testing.expect(explore.detectLanguage("a.go") == .go_lang);
    try testing.expect(explore.detectLanguage("a.php") == .php);
    try testing.expect(explore.detectLanguage("a.py") == .python);
}

test "ffast Go parser extracts function and type" {
    const Explorer = @import("explore.zig").Explorer;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var exp = Explorer.init(arena.allocator());
    try exp.indexFile("main.go", "package main\n\ntype Config struct{}\nfunc main() {}\n");
    var outline = (try exp.getOutline("main.go", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();

    try testing.expect(outline.symbols.items.len >= 2);
}

test "ffast TypeScript outline skips local const declarations" {
    const Explorer = @import("explore.zig").Explorer;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var exp = Explorer.init(arena.allocator());
    try exp.indexFile(
        "main.ts",
        "export function run() {\n" ++
            "  const localValue = 1;\n" ++
            "  return localValue;\n" ++
            "}\n",
    );

    var outline = (try exp.getOutline("main.ts", testing.allocator)) orelse return error.TestUnexpectedResult;
    defer outline.deinit();

    try testing.expect(outline.symbols.items.len == 1);
    try testing.expect(std.mem.eql(u8, outline.symbols.items[0].name, "run"));
}

test "ffast Tool enum exposes only seven tools" {
    const Tool = @import("mcp.zig").Tool;

    try testing.expect(std.meta.stringToEnum(Tool, "ffast_tree") != null);
    try testing.expect(std.meta.stringToEnum(Tool, "ffast_outline") != null);
    try testing.expect(std.meta.stringToEnum(Tool, "ffast_search") != null);
    try testing.expect(std.meta.stringToEnum(Tool, "ffast_index") != null);
    try testing.expect(std.meta.stringToEnum(Tool, "ffast_status") != null);
    try testing.expect(std.meta.stringToEnum(Tool, "ffast_snapshot") != null);
    try testing.expect(std.meta.stringToEnum(Tool, "ffast_changes") != null);
    try testing.expect(std.meta.stringToEnum(Tool, "ffast_deps") != null);

    try testing.expect(std.meta.stringToEnum(Tool, "ffast_remote") == null);
    try testing.expect(std.meta.stringToEnum(Tool, "ffast_read") == null);
}

test "ffast_search returns structured matches" {
    const Explorer = @import("explore.zig").Explorer;
    const mcp_server = @import("mcp.zig");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator());
    try exp.indexFile("src/a.zig", "pub fn alpha() void {}\n");

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"query\":\"alpha\",\"max_results\":10}", .{});
    defer parsed.deinit();

    const out = try mcp_server.dispatchForTest(testing.allocator, .ffast_search, &parsed.value.object, &exp);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\"matches\":[") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"path\":\"src/a.zig\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"line\":1") != null);
}

test "ffast_tree handler returns compact nested tree payload" {
    const Explorer = @import("explore.zig").Explorer;
    const mcp_server = @import("mcp.zig");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator());
    try exp.indexFile("src/main.zig", "pub fn main() void {}\n");

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{}", .{});
    defer parsed.deinit();

    const out = try mcp_server.dispatchForTest(testing.allocator, .ffast_tree, &parsed.value.object, &exp);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\"tree\":[") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"src/\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "main.zig  ") != null);
}

test "ffast_tree supports path depth include sort and dirs_first args" {
    const Explorer = @import("explore.zig").Explorer;
    const mcp_server = @import("mcp.zig");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator());
    try exp.indexFile("app/one/a.zig", "pub fn a() void {}\n");
    try exp.indexFile("app/two/b.zig", "pub fn b() void {}\n");
    try exp.indexFile("app/two/c.md", "# c\n");

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"path\":\"app\",\"depth\":1,\"max_nodes\":10,\"include\":\"*.zig\",\"sort\":\"name\",\"dirs_first\":true}",
        .{},
    );
    defer parsed.deinit();

    const out = try mcp_server.dispatchForTest(testing.allocator, .ffast_tree, &parsed.value.object, &exp);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\"tree\":[") != null);
    try testing.expect(std.mem.indexOf(u8, out, "a.zig") != null);
    try testing.expect(std.mem.indexOf(u8, out, "b.zig") != null);
    try testing.expect(std.mem.indexOf(u8, out, "c.md") == null);
}

test "ffast_tree rejects invalid sort argument" {
    const Explorer = @import("explore.zig").Explorer;
    const mcp_server = @import("mcp.zig");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator());
    try exp.indexFile("src/main.zig", "pub fn main() void {}\n");

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"sort\":\"bogus\"}", .{});
    defer parsed.deinit();

    const out = try mcp_server.dispatchForTest(testing.allocator, .ffast_tree, &parsed.value.object, &exp);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\"error\":") != null);
    try testing.expect(std.mem.indexOf(u8, out, "sort must be one of") != null);
}

test "ffast_outline handler returns symbols payload" {
    const Explorer = @import("explore.zig").Explorer;
    const mcp_server = @import("mcp.zig");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator());
    try exp.indexFile("main.go", "package main\n\ntype Config struct{}\nfunc main() {}\n");

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"path\":\"main.go\"}", .{});
    defer parsed.deinit();

    const out = try mcp_server.dispatchForTest(testing.allocator, .ffast_outline, &parsed.value.object, &exp);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\"path\":\"main.go\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"symbols\":[") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Config") != null);
}

test "ffast changes follow monotonic store seq" {
    const Store = @import("store.zig").Store;

    var store = Store.init(testing.allocator);
    defer store.deinit();

    _ = try store.recordSnapshot("src/a.zig", 10, 1);
    _ = try store.recordSnapshot("src/b.zig", 20, 2);

    const changes = try store.changesSinceDetailed(0, testing.allocator);
    defer testing.allocator.free(changes);
    try testing.expect(changes.len == 2);
    try testing.expect(store.currentSeq() == 2);
}

test "ffast_status reports seq and watcher state" {
    const Store = @import("store.zig").Store;
    const Explorer = @import("explore.zig").Explorer;
    const mcp_server = @import("mcp.zig");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var exp = Explorer.init(arena.allocator());

    try exp.indexFile("src/a.zig", "pub fn alpha() void {}\n");
    _ = try store.recordSnapshot("src/a.zig", 23, 1);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{}", .{});
    defer parsed.deinit();

    const out = try mcp_server.dispatchForTestRuntime(
        testing.allocator,
        .ffast_status,
        &parsed.value.object,
        &exp,
        &store,
        "/tmp/project",
        true,
    );
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\"project_root\":\"/tmp/project\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"indexed_files\":1") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"current_seq\":1") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"watcher_running\":true") != null);
}

test "ffast_changes returns detailed change list" {
    const Store = @import("store.zig").Store;
    const Explorer = @import("explore.zig").Explorer;
    const mcp_server = @import("mcp.zig");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var exp = Explorer.init(arena.allocator());

    _ = try store.recordSnapshot("src/a.zig", 10, 1);
    _ = try store.recordSnapshot("src/b.zig", 20, 2);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"since\":0}", .{});
    defer parsed.deinit();

    const out = try mcp_server.dispatchForTestRuntime(
        testing.allocator,
        .ffast_changes,
        &parsed.value.object,
        &exp,
        &store,
        "/tmp/project",
        false,
    );
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\"current_seq\":2") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"changes\":[") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"path\":\"src/a.zig\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"path\":\"src/b.zig\"") != null);
}

test "ffast snapshot write creates snapshot file" {
    const snapshot = @import("snapshot.zig");
    const Explorer = @import("explore.zig").Explorer;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &root_buf);

    var exp = Explorer.init(arena.allocator());
    try exp.indexFile("src/main.zig", "pub fn main() void {}\n");

    const out_path = try std.fmt.allocPrint(testing.allocator, "{s}/ffast.snapshot", .{root});
    defer testing.allocator.free(out_path);

    try snapshot.writeSnapshot(&exp, root, out_path, testing.allocator);
    try std.fs.cwd().access(out_path, .{});
}

test "ffast_snapshot reports missing snapshot metadata" {
    const Store = @import("store.zig").Store;
    const Explorer = @import("explore.zig").Explorer;
    const mcp_server = @import("mcp.zig");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &root_buf);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var exp = Explorer.init(arena.allocator());

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{}", .{});
    defer parsed.deinit();

    const out = try mcp_server.dispatchForTestRuntime(
        testing.allocator,
        .ffast_snapshot,
        &parsed.value.object,
        &exp,
        &store,
        root,
        false,
    );
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\"exists\":false") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"wrote\":false") != null);
    try testing.expect(std.mem.indexOf(u8, out, "ffast.snapshot") != null);
}

test "ffast_snapshot write mode creates file and returns metadata" {
    const Store = @import("store.zig").Store;
    const Explorer = @import("explore.zig").Explorer;
    const mcp_server = @import("mcp.zig");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &root_buf);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var exp = Explorer.init(arena.allocator());
    try exp.indexFile("src/main.zig", "pub fn main() void {}\n");

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"write\":true}", .{});
    defer parsed.deinit();

    const out = try mcp_server.dispatchForTestRuntime(
        testing.allocator,
        .ffast_snapshot,
        &parsed.value.object,
        &exp,
        &store,
        root,
        false,
    );
    defer testing.allocator.free(out);

    const snap_path = try std.fmt.allocPrint(testing.allocator, "{s}/ffast.snapshot", .{root});
    defer testing.allocator.free(snap_path);

    try testing.expect(std.mem.indexOf(u8, out, "\"exists\":true") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"wrote\":true") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"size_bytes\":") != null);
    try std.fs.cwd().access(snap_path, .{});
}

test "ffast blocks sensitive file patterns" {
    const watcher = @import("watcher.zig");

    try testing.expect(watcher.isSensitivePath(".env"));
    try testing.expect(watcher.isSensitivePath("credentials.json"));
    try testing.expect(watcher.isSensitivePath(".ssh/id_rsa"));
    try testing.expect(!watcher.isSensitivePath("src/main.zig"));
}

test "ffast initial scan respects root gitignore wildcard and directory patterns" {
    const Store = @import("store.zig").Store;
    const Explorer = @import("explore.zig").Explorer;
    const watcher = @import("watcher.zig");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var ignore = try tmp.dir.createFile(".gitignore", .{});
    defer ignore.close();
    try ignore.writeAll(
        "/public/upload*\n" ++
            "/public/js/\n" ++
            "*.log\n",
    );

    try tmp.dir.makePath("src");
    try tmp.dir.makePath("public/upload");
    try tmp.dir.makePath("public/upload-extra");
    try tmp.dir.makePath("public/js");
    try tmp.dir.makePath("x/public/uploadx");

    var f1 = try tmp.dir.createFile("src/main.zig", .{});
    defer f1.close();
    try f1.writeAll("pub fn main() void {}\n");

    var f2 = try tmp.dir.createFile("public/upload/a.zig", .{});
    defer f2.close();
    try f2.writeAll("pub fn a() void {}\n");

    var f3 = try tmp.dir.createFile("public/upload-extra/b.zig", .{});
    defer f3.close();
    try f3.writeAll("pub fn b() void {}\n");

    var f4 = try tmp.dir.createFile("public/js/app.zig", .{});
    defer f4.close();
    try f4.writeAll("pub fn app() void {}\n");

    var f5 = try tmp.dir.createFile("app.log", .{});
    defer f5.close();
    try f5.writeAll("line\n");

    var f6 = try tmp.dir.createFile("x/public/uploadx/keep.zig", .{});
    defer f6.close();
    try f6.writeAll("pub fn keep() void {}\n");

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &root_buf);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var exp = Explorer.init(arena.allocator());

    try watcher.initialScan(&store, &exp, root, testing.allocator, false);

    var o_main = try exp.getOutline("src/main.zig", testing.allocator);
    defer if (o_main) |*o| o.deinit();
    try testing.expect(o_main != null);

    var o_upload = try exp.getOutline("public/upload/a.zig", testing.allocator);
    defer if (o_upload) |*o| o.deinit();
    try testing.expect(o_upload == null);

    var o_upload_extra = try exp.getOutline("public/upload-extra/b.zig", testing.allocator);
    defer if (o_upload_extra) |*o| o.deinit();
    try testing.expect(o_upload_extra == null);

    var o_js = try exp.getOutline("public/js/app.zig", testing.allocator);
    defer if (o_js) |*o| o.deinit();
    try testing.expect(o_js == null);

    var o_log = try exp.getOutline("app.log", testing.allocator);
    defer if (o_log) |*o| o.deinit();
    try testing.expect(o_log == null);

    var o_nested = try exp.getOutline("x/public/uploadx/keep.zig", testing.allocator);
    defer if (o_nested) |*o| o.deinit();
    try testing.expect(o_nested != null);
}

test "ffast initial scan respects nested gitignore in subdirectories" {
    const Store = @import("store.zig").Store;
    const Explorer = @import("explore.zig").Explorer;
    const watcher = @import("watcher.zig");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("src");
    try tmp.dir.makePath("storage/logs");

    var nested_ignore = try tmp.dir.createFile("storage/logs/.gitignore", .{});
    defer nested_ignore.close();
    try nested_ignore.writeAll("*\n!.gitignore\n");

    var src = try tmp.dir.createFile("src/main.zig", .{});
    defer src.close();
    try src.writeAll("pub fn main() void {}\n");

    var logf = try tmp.dir.createFile("storage/logs/app.php", .{});
    defer logf.close();
    try logf.writeAll("<?php echo 'x';\n");

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &root_buf);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var exp = Explorer.init(arena.allocator());

    try watcher.initialScan(&store, &exp, root, testing.allocator, false);

    var o_src = try exp.getOutline("src/main.zig", testing.allocator);
    defer if (o_src) |*o| o.deinit();
    try testing.expect(o_src != null);

    var o_log = try exp.getOutline("storage/logs/app.php", testing.allocator);
    defer if (o_log) |*o| o.deinit();
    try testing.expect(o_log == null);
}

test "ffast initial scan skips unknown-language text files" {
    const Store = @import("store.zig").Store;
    const Explorer = @import("explore.zig").Explorer;
    const watcher = @import("watcher.zig");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("src");
    try tmp.dir.makePath("public");

    var src = try tmp.dir.createFile("src/main.zig", .{});
    defer src.close();
    try src.writeAll("pub fn main() void {}\n");

    var css = try tmp.dir.createFile("public/style.css", .{});
    defer css.close();
    try css.writeAll("body { color: black; }\n");

    var html = try tmp.dir.createFile("public/index.html", .{});
    defer html.close();
    try html.writeAll("<html><body>x</body></html>\n");

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &root_buf);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var exp = Explorer.init(arena.allocator());

    try watcher.initialScan(&store, &exp, root, testing.allocator, false);

    var o_src = try exp.getOutline("src/main.zig", testing.allocator);
    defer if (o_src) |*o| o.deinit();
    try testing.expect(o_src != null);
    try testing.expect(o_src.?.line_count >= 1);
    try testing.expect(o_src.?.symbols.items.len >= 1);

    var o_css = try exp.getOutline("public/style.css", testing.allocator);
    defer if (o_css) |*o| o.deinit();
    try testing.expect(o_css == null);

    var o_html = try exp.getOutline("public/index.html", testing.allocator);
    defer if (o_html) |*o| o.deinit();
    try testing.expect(o_html == null);
}

test "ffast fast initial scan keeps outlines and search" {
    const Store = @import("store.zig").Store;
    const Explorer = @import("explore.zig").Explorer;
    const watcher = @import("watcher.zig");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("src");
    var src = try tmp.dir.createFile("src/main.zig", .{});
    defer src.close();
    try src.writeAll(
        "pub fn main() void {\n" ++
            "    const blazing = true;\n" ++
            "}\n",
    );

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &root_buf);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var exp = Explorer.init(arena.allocator());
    exp.setRoot(root);

    try watcher.initialScanFast(&store, &exp, root, testing.allocator);

    // Fast scan: outlines stored, but content NOT stored to save RAM
    try testing.expect(exp.outlines.count() == 1);
    try testing.expect(exp.contents.count() == 0);
    var o_src = try exp.getOutline("src/main.zig", testing.allocator);
    defer if (o_src) |*o| o.deinit();
    try testing.expect(o_src != null);
    try testing.expect(o_src.?.line_count >= 1);
    try testing.expect(o_src.?.symbols.items.len >= 1);

    const results = try exp.searchContent("blazing", testing.allocator, 10);
    defer {
        for (results) |r| {
            testing.allocator.free(r.path);
            testing.allocator.free(r.line_text);
        }
        testing.allocator.free(results);
    }
    try testing.expect(results.len == 1);
}

test "ffast MCP bootstrap defaults to fast initial scan" {
    const Store = @import("store.zig").Store;
    const Explorer = @import("explore.zig").Explorer;
    const mcp_server = @import("mcp.zig");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("src");
    var src = try tmp.dir.createFile("src/main.zig", .{});
    defer src.close();
    try src.writeAll("pub fn main() void {}\n");

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &root_buf);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var exp = Explorer.init(arena.allocator());

    try mcp_server.bootstrapIndexForTest(&store, &exp, root, testing.allocator);

    try testing.expect(exp.outlines.count() == 1);
}

test "mcp watcher runtime picks up file changes" {
    const Store = @import("store.zig").Store;
    const Explorer = @import("explore.zig").Explorer;
    const mcp_server = @import("mcp.zig");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("src");
    var src = try tmp.dir.createFile("src/main.ts", .{});
    defer src.close();
    try src.writeAll("export function run(){ return 1; }\n");

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &root_buf);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var exp = Explorer.init(arena.allocator());

    try mcp_server.bootstrapIndexForTest(&store, &exp, root, testing.allocator);

    var runtime = mcp_server.WatcherRuntime{};
    try mcp_server.startWatcherForTest(&store, &exp, root, &runtime);
    defer mcp_server.stopWatcherForTest(&runtime);

    // Let watcher build its initial known-file snapshot first.
    std.Thread.sleep(300 * std.time.ns_per_ms);

    const seq_before = store.currentSeq();

    // Modify an existing tracked file to avoid race with initial snapshot population.
    try tmp.dir.writeFile(.{ .sub_path = "src/main.ts", .data = "export function run(){ return 2; }\n" });

    var observed = false;
    var tries: usize = 0;
    while (tries < 40) : (tries += 1) {
        std.Thread.sleep(100 * std.time.ns_per_ms);
        if (store.currentSeq() > seq_before) {
            observed = true;
            break;
        }
    }

    try testing.expect(observed);
}

test "ffast_outline blocks traversal and sensitive paths" {
    const Explorer = @import("explore.zig").Explorer;
    const mcp_server = @import("mcp.zig");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator());
    try exp.indexFile("src/main.zig", "pub fn main() void {}\n");

    const traversal = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"path\":\"../secret.txt\"}", .{});
    defer traversal.deinit();

    const out_traversal = try mcp_server.dispatchForTest(testing.allocator, .ffast_outline, &traversal.value.object, &exp);
    defer testing.allocator.free(out_traversal);
    try testing.expect(std.mem.indexOf(u8, out_traversal, "\"code\":\"OUT_OF_SCOPE\"") != null);
    try testing.expect(std.mem.indexOf(u8, out_traversal, "path traversal not allowed") != null);

    const sensitive = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"path\":\".env\"}", .{});
    defer sensitive.deinit();

    const out_sensitive = try mcp_server.dispatchForTest(testing.allocator, .ffast_outline, &sensitive.value.object, &exp);
    defer testing.allocator.free(out_sensitive);
    try testing.expect(std.mem.indexOf(u8, out_sensitive, "\"code\":\"OUT_OF_SCOPE\"") != null);
    try testing.expect(std.mem.indexOf(u8, out_sensitive, "sensitive file access blocked") != null);
}

test "ffast README lists exactly v1 tools" {
    const readme = try std.fs.cwd().readFileAlloc(testing.allocator, "README.md", 128 * 1024);
    defer testing.allocator.free(readme);

    try testing.expect(std.mem.indexOf(u8, readme, "ffast_tree") != null);
    try testing.expect(std.mem.indexOf(u8, readme, "ffast_outline") != null);
    try testing.expect(std.mem.indexOf(u8, readme, "ffast_search") != null);
    try testing.expect(std.mem.indexOf(u8, readme, "ffast_index") != null);
    try testing.expect(std.mem.indexOf(u8, readme, "ffast_status") != null);
    try testing.expect(std.mem.indexOf(u8, readme, "ffast_snapshot") != null);
    try testing.expect(std.mem.indexOf(u8, readme, "ffast_changes") != null);
    try testing.expect(std.mem.indexOf(u8, readme, "No telemetry") != null);
}

test "ffast MCP tools/call dispatches implemented handler" {
    const Store = @import("store.zig").Store;
    const Explorer = @import("explore.zig").Explorer;
    const mcp_server = @import("mcp.zig");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exp = Explorer.init(arena.allocator());
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{}", .{});
    defer parsed.deinit();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fs.cwd().realpath(".", &root_buf);

    const out = try mcp_server.callToolForTestRuntime(
        testing.allocator,
        .ffast_index,
        &parsed.value.object,
        &exp,
        &store,
        root,
        false,
    );
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\"isError\":false") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\\\"started\\\":true") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\\\"indexed_files\\\":") != null);
}

test "ffast_index performs runtime reindex and updates status" {
    const Store = @import("store.zig").Store;
    const Explorer = @import("explore.zig").Explorer;
    const mcp_server = @import("mcp.zig");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("src");
    var file = try tmp.dir.createFile("src/main.zig", .{});
    defer file.close();
    try file.writeAll("pub fn main() void {}\n");

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &root_buf);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var exp = Explorer.init(arena.allocator());

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{}", .{});
    defer parsed.deinit();

    const out_before = try mcp_server.dispatchForTestRuntime(
        testing.allocator,
        .ffast_status,
        &parsed.value.object,
        &exp,
        &store,
        root,
        false,
    );
    defer testing.allocator.free(out_before);
    try testing.expect(std.mem.indexOf(u8, out_before, "\"indexed_files\":0") != null);

    const out_index = try mcp_server.callToolForTestRuntime(
        testing.allocator,
        .ffast_index,
        &parsed.value.object,
        &exp,
        &store,
        root,
        false,
    );
    defer testing.allocator.free(out_index);
    try testing.expect(std.mem.indexOf(u8, out_index, "\\\"indexed_files\\\":1") != null);

    const out_after = try mcp_server.dispatchForTestRuntime(
        testing.allocator,
        .ffast_status,
        &parsed.value.object,
        &exp,
        &store,
        root,
        false,
    );
    defer testing.allocator.free(out_after);
    try testing.expect(std.mem.indexOf(u8, out_after, "\"indexed_files\":1") != null);
}

test "ffast unknown command prints usage hint" {
    const result = try std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &.{ "zig", "build", "run", "--", "nonesuch" },
        .cwd = ".",
        .max_output_bytes = 32 * 1024,
    });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    try testing.expect(std.mem.indexOf(u8, result.stdout, "Unknown command") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "usage: ffast") != null);
}

test "ffast MCP bootstrap indexes project before tool calls" {
    const Store = @import("store.zig").Store;
    const Explorer = @import("explore.zig").Explorer;
    const mcp_server = @import("mcp.zig");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("src");
    var file = try tmp.dir.createFile("src/main.zig", .{});
    defer file.close();
    try file.writeAll("pub fn main() void {}\n");

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &root_buf);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var exp = Explorer.init(arena.allocator());

    try mcp_server.bootstrapIndexForTest(&store, &exp, root, testing.allocator);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{}", .{});
    defer parsed.deinit();

    const out_tree = try mcp_server.dispatchForTest(testing.allocator, .ffast_tree, &parsed.value.object, &exp);
    defer testing.allocator.free(out_tree);
    try testing.expect(std.mem.indexOf(u8, out_tree, "main.zig") != null);

    const out_status = try mcp_server.dispatchForTestRuntime(
        testing.allocator,
        .ffast_status,
        &parsed.value.object,
        &exp,
        &store,
        root,
        false,
    );
    defer testing.allocator.free(out_status);
    try testing.expect(std.mem.indexOf(u8, out_status, "\"indexed_files\":0") == null);
}

test "ffast MCP JSON-RPC result is single-line framed" {
    const mcp_server = @import("mcp.zig");

    const line = try mcp_server.buildResultLineForTest(
        testing.allocator,
        std.json.Value{ .integer = 1 },
        "{\"tools\":[\n{\"name\":\"ffast_tree\"}\n]}",
    );
    defer testing.allocator.free(line);

    const first_newline = std.mem.indexOfScalar(u8, line, '\n') orelse return error.TestUnexpectedResult;
    try testing.expect(first_newline == line.len - 1);
}

test "ffast MCP tools/list includes inputSchema per tool" {
    const mcp_server = @import("mcp.zig");

    const payload = try mcp_server.toolsListForTest(testing.allocator);
    defer testing.allocator.free(payload);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
    defer parsed.deinit();

    const tools_val = parsed.value.object.get("tools") orelse return error.TestUnexpectedResult;
    try testing.expect(tools_val == .array);
    try testing.expect(tools_val.array.items.len == 8);

    for (tools_val.array.items) |tool| {
        try testing.expect(tool == .object);
        try testing.expect(tool.object.get("inputSchema") != null);
    }

    var saw_tree = false;
    for (tools_val.array.items) |tool| {
        const name_val = tool.object.get("name") orelse continue;
        if (name_val != .string) continue;
        if (!std.mem.eql(u8, name_val.string, "ffast_tree")) continue;
        saw_tree = true;

        const schema_val = tool.object.get("inputSchema") orelse return error.TestUnexpectedResult;
        try testing.expect(schema_val == .object);

        const props_val = schema_val.object.get("properties") orelse return error.TestUnexpectedResult;
        try testing.expect(props_val == .object);

        try testing.expect(props_val.object.get("path") != null);
        try testing.expect(props_val.object.get("depth") != null);
        try testing.expect(props_val.object.get("max_nodes") != null);
        try testing.expect(props_val.object.get("include") != null);
        try testing.expect(props_val.object.get("sort") != null);
        try testing.expect(props_val.object.get("dirs_first") != null);
    }
    try testing.expect(saw_tree);
}

test "resource governor transitions high and critical states" {
    const governor_mod = @import("resource_governor.zig");
    var g = governor_mod.ResourceGovernor.init(.{
        .max_ram_mb = 3800,
        .high_watermark_pct = 85,
        .critical_watermark_pct = 95,
    });

    g.updateRssBytes(3000 * 1024 * 1024);
    try testing.expect(g.state() == .normal);

    g.updateRssBytes(3300 * 1024 * 1024);
    try testing.expect(g.state() == .high);

    g.updateRssBytes(3650 * 1024 * 1024);
    try testing.expect(g.state() == .critical);
}

test "governor denies heavy batch at critical watermark" {
    const governor_mod = @import("resource_governor.zig");
    var g = governor_mod.ResourceGovernor.init(.{ .max_ram_mb = 3800 });
    g.updateRssBytes(3700 * 1024 * 1024);
    const admit = g.tryAdmitBatch(64 * 1024 * 1024);
    try testing.expect(!admit.allowed);
    try testing.expect(admit.reason == .critical_watermark);
}

test "governor allows batch at normal watermark" {
    const governor_mod = @import("resource_governor.zig");
    var g = governor_mod.ResourceGovernor.init(.{ .max_ram_mb = 3800 });
    g.updateRssBytes(1000 * 1024 * 1024);
    const admit = g.tryAdmitBatch(4 * 1024 * 1024);
    try testing.expect(admit.allowed);
    try testing.expect(admit.reason == .none);
}

test "ffast_status includes core index fields" {
    const Store = @import("store.zig").Store;
    const Explorer = @import("explore.zig").Explorer;
    const mcp_server = @import("mcp.zig");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var exp = Explorer.init(arena.allocator());

    try exp.indexFile("src/a.zig", "pub fn alpha() void {}\n");
    _ = try store.recordSnapshot("src/a.zig", 23, 1);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{}", .{});
    defer parsed.deinit();

    const out = try mcp_server.dispatchForTestRuntime(
        testing.allocator,
        .ffast_status,
        &parsed.value.object,
        &exp,
        &store,
        "/tmp/project",
        false,
    );
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\"indexed_files\":") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"current_seq\":") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"watcher_running\":") != null);
}

test "search works while tier2 coverage is partial" {
    const Store = @import("store.zig").Store;
    const Explorer = @import("explore.zig").Explorer;
    const watcher = @import("watcher.zig");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("src");
    var f = try tmp.dir.createFile("src/a.ts", .{});
    defer f.close();
    try f.writeAll("export const needle = 1;\n");

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &root_buf);

    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    var exp = Explorer.init(arena.allocator());

    exp.setRoot(root);
    try watcher.initialScanFast(&store, &exp, root, std.testing.allocator);

    // Clear cached contents to simulate partial index state
    exp.releaseContents();
    try std.testing.expect(exp.contents.count() == 0);

    // Search should still work via disk fallback
    const res = try exp.searchContent("needle", std.testing.allocator, 5);
    defer {
        for (res) |r| {
            std.testing.allocator.free(r.path);
            std.testing.allocator.free(r.line_text);
        }
        std.testing.allocator.free(res);
    }
    try std.testing.expect(res.len == 1);
    try std.testing.expect(std.mem.indexOf(u8, res[0].path, "a.ts") != null);
}

test "secondary scheduler checkpoint persists and reloads" {
    const snapshot = @import("snapshot.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &root_buf);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/ffast.snapshot", .{root});
    defer std.testing.allocator.free(path);

    const meta = "{\"tier2_processed\":12,\"tier2_queued\":30,\"root_hash\":1}";
    try tmp.dir.writeFile(.{ .sub_path = "ffast.snapshot", .data = meta });

    const cp = try snapshot.readSecondaryCheckpointForTest(path, std.testing.allocator);
    try std.testing.expect(cp.processed_files == 12);
    try std.testing.expect(cp.queued_files == 30);
}

test "index budget config defaults are conservative" {
    const explore_mod = @import("explore.zig");
    const cfg = explore_mod.IndexBudgetConfig.fromEnvForTest(null, null, null, null);
    try std.testing.expect(cfg.max_ram_mb == 3800);
    try std.testing.expect(cfg.target_seconds == 60);
    try std.testing.expect(cfg.batch_min_files == 32);
    try std.testing.expect(cfg.batch_max_files == 256);
}

test "index budget config parses env overrides" {
    const explore_mod = @import("explore.zig");
    const cfg = explore_mod.IndexBudgetConfig.fromEnvForTest("2048", "120", "16", "512");
    try std.testing.expect(cfg.max_ram_mb == 2048);
    try std.testing.expect(cfg.target_seconds == 120);
    try std.testing.expect(cfg.batch_min_files == 16);
    try std.testing.expect(cfg.batch_max_files == 512);
}
