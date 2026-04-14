const std = @import("std");

const FileNode = struct {
    name: []const u8,
    size: u64 = 0,
    is_directory: bool = false,
    children: std.ArrayList(*FileNode),

    fn deinit(self: *FileNode, allocator: std.mem.Allocator) void {
        for (self.children.items) |child| {
            child.deinit(allocator);
        }
        self.children.deinit();
        allocator.free(self.name);
        allocator.destroy(self);
    }
};

fn scanDirectory(allocator: std.mem.Allocator, root: *FileNode) !*FileNode {
    var dir_res = if (std.fs.path.isAbsolute(root.name))
        std.fs.openIterableDirAbsolute(root.name, .{})
    else
        std.fs.cwd().openIterableDir(root.name, .{});

    var iterable_dir = dir_res catch |err| {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("Error: {any}\n", .{err});
        return root;
    };
    defer iterable_dir.close();

    var it = iterable_dir.iterate();
    while (true) {
        const entry_opt = it.next() catch |err| {
            const stderr = std.io.getStdErr().writer();
            try stderr.print("Error: {any}\n", .{err});
            return root;
        };
        const entry = entry_opt orelse break;

        if (entry.kind == .sym_link) continue;

        const child_path = try std.fs.path.join(allocator, &[_][]const u8{ root.name, entry.name });

        var child_node = try allocator.create(FileNode);
        child_node.* = .{
            .name = child_path,
            .children = std.ArrayList(*FileNode).init(allocator),
        };

        if (entry.kind == .directory) {
            child_node.is_directory = true;
            _ = try scanDirectory(allocator, child_node);
            try root.children.append(child_node);
            root.size += child_node.size;
        } else {
            child_node.is_directory = false;
            const stat_res = if (std.fs.path.isAbsolute(child_path))
                std.fs.statFileAbsolute(child_path)
            else
                std.fs.cwd().statFile(child_path);

            const file_stat = stat_res catch |err| {
                const stderr = std.io.getStdErr().writer();
                try stderr.print("Error: {any}\n", .{err});
                // In C++ it just continues
                allocator.free(child_path);
                allocator.destroy(child_node);
                continue;
            };
            child_node.size = file_stat.size;
            try root.children.append(child_node);
            root.size += child_node.size;
        }
    }

    return root;
}

fn printScan(root: *const FileNode, depth: usize) void {
    const stdout = std.io.getStdOut().writer();
    var i: usize = 0;
    while (i < depth) : (i += 1) {
        stdout.print("   ", .{}) catch {};
    }

    const filename = std.fs.path.basename(root.name);

    const display_name = if (filename.len == 0) root.name else filename;

    stdout.print("|--{s} : {d}\n", .{ display_name, root.size }) catch {};

    for (root.children.items) |child| {
        printScan(child, depth + 1);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len > 2) {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("Usage: {s} [directory path]\n", .{args[0]});
        std.process.exit(64);
    }

    const root_path = if (args.len == 1) "." else args[1];

    //duplicate the path because FileNode.deinit will free it.
    const root_name = try allocator.dupe(u8, root_path);

    var root = try allocator.create(FileNode);
    root.* = .{
        .name = root_name,
        .is_directory = true,
        .children = std.ArrayList(*FileNode).init(allocator),
    };
    defer root.deinit(allocator);

    _ = try scanDirectory(allocator, root);
    printScan(root, 0);
}
