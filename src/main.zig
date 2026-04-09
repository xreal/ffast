const std = @import("std");
const mcp_server = @import("mcp.zig");
const Explorer = @import("explore.zig").Explorer;
const Store = @import("store.zig").Store;
const watcher = @import("watcher.zig");
const snapshot_mod = @import("snapshot.zig");

pub const CliCommand = enum {
    mcp,
    index,
    snapshot,
    status,
    deps,
};

fn parseCommand(args: []const []const u8) ?CliCommand {
    if (args.len < 2) return null;
    if (std.mem.eql(u8, args[1], "mcp")) return .mcp;
    if (std.mem.eql(u8, args[1], "index")) return .index;
    if (std.mem.eql(u8, args[1], "snapshot")) return .snapshot;
    if (std.mem.eql(u8, args[1], "status")) return .status;
    if (std.mem.eql(u8, args[1], "deps")) return .deps;
    return null;
}

pub fn runCliCommand(allocator: std.mem.Allocator, root: []const u8, args: []const []const u8, command: CliCommand) ![]u8 {
    var store = Store.init(allocator);
    defer store.deinit();
    var explorer = Explorer.init(allocator);
    defer explorer.deinit();
    explorer.setRoot(root);

    try watcher.initialScanFast(&store, &explorer, root, allocator);

    switch (command) {
        .index => {
            return try std.fmt.allocPrint(allocator, "{{\"started\":true,\"indexed_files\":{d}}}\n", .{explorer.outlines.count()});
        },
        .snapshot => {
            const path = try std.fmt.allocPrint(allocator, "{s}/ffast.snapshot", .{root});
            defer allocator.free(path);
            try snapshot_mod.writeSnapshot(&explorer, root, path, allocator);
            const stat = try std.fs.cwd().statFile(path);
            return try std.fmt.allocPrint(
                allocator,
                "{{\"exists\":true,\"path\":\"{s}\",\"size_bytes\":{d},\"updated_at\":{d},\"wrote\":true}}\n",
                .{ path, stat.size, stat.mtime },
            );
        },
        .status => {
            return try std.fmt.allocPrint(
                allocator,
                "{{\"project_root\":\"{s}\",\"indexed_files\":{d},\"current_seq\":{d},\"watcher_running\":false}}\n",
                .{ root, explorer.outlines.count(), store.currentSeq() },
            );
        },
        .deps => {
            if (args.len < 3) return error.MissingArgument;
            const dep_path = args[2];
            const imported_by = try explorer.getImportedBy(dep_path, allocator);
            const imports = try explorer.getImports(dep_path, allocator);
            defer {
                for (imported_by) |p| allocator.free(p);
                allocator.free(imported_by);
                for (imports) |p| allocator.free(p);
                allocator.free(imports);
            }
            var buf: std.ArrayList(u8) = .{};
            defer buf.deinit(allocator);
            const w = buf.writer(allocator);
            w.print("{{\"path\":\"{s}\",\"imported_by\":[", .{dep_path}) catch return error.AllocationFailed;
            for (imported_by, 0..) |dep, i| {
                if (i != 0) w.writeAll(",") catch return error.AllocationFailed;
                w.print("\"{s}\"", .{dep}) catch return error.AllocationFailed;
            }
            w.writeAll("],\"imports\":[") catch return error.AllocationFailed;
            for (imports, 0..) |dep, i| {
                if (i != 0) w.writeAll(",") catch return error.AllocationFailed;
                w.print("\"{s}\"", .{dep}) catch return error.AllocationFailed;
            }
            w.writeAll("]}\n") catch return error.AllocationFailed;
            return try allocator.dupe(u8, buf.items);
        },
        .mcp => return error.InvalidCommand,
    }
}

pub fn main() !void {
    const stdout = std.fs.File.stdout();
    var out_buf: [1024]u8 = undefined;
    var w = stdout.writer(&out_buf);
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);

    if (args.len >= 2 and (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h"))) {
        try w.interface.writeAll(
            "ffast - focused code intelligence\n" ++
                "usage: ffast [root] <command>\n" ++
                "commands:\n" ++
                "  mcp\n" ++
                "  snapshot\n" ++
                "  index\n" ++
                "  status\n" ++
                "  deps <path>\n",
        );
        try w.interface.flush();
        return;
    }

    if (parseCommand(args)) |command| {
        if (command == .mcp) {
            try mcp_server.run(std.heap.page_allocator);
            return;
        }

        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        const project_root = std.fs.cwd().realpath(".", &root_buf) catch ".";
        const out = try runCliCommand(std.heap.page_allocator, project_root, args, command);
        defer std.heap.page_allocator.free(out);
        try w.interface.writeAll(out);
        try w.interface.flush();
        return;
    }

    try w.interface.writeAll("ffast: Unknown command\n");
    try w.interface.writeAll(
        "ffast - focused code intelligence\n" ++
            "usage: ffast [root] <command>\n" ++
            "commands:\n" ++
            "  mcp\n" ++
            "  snapshot\n" ++
            "  index\n" ++
            "  status\n" ++
            "  deps <path>\n",
    );
    try w.interface.flush();
}
