const std = @import("std");
const File = std.fs.File;
const Dir = std.fs.Dir;
const IterableDir = std.fs.IterableDir;

pub fn main() !void {
    const stdout = std.io.getStdOut();
    var buf = std.io.bufferedWriter(stdout.writer());

    var path = "./";
    var root_dir = try std.fs.cwd().openIterableDir(path, .{});
    defer root_dir.close();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var crawler = try crawl(root_dir, gpa.allocator(), 1);
    defer crawler.deinit();

    var w = buf.writer();

    while (try crawler.next()) |entry| {
        const stats = try entry.dir.statFile(entry.basename);
        try w.print("{any} ", .{stats.ctime});

        for (1..entry.depth) |_| {
            _ = try w.write(" \u{2502} ");
        }
        switch (entry.kind) {
            .directory => try w.print("{s}/\n", .{entry.basename}),
            else => try w.print("{s}\n", .{entry.basename}),
        }
    }

    try buf.flush();
}

/// The std.fs.IterableDir.Walker but with a depth limit.
const Crawler = struct {
    limit: u8,
    stack: std.ArrayList(StackItem),
    name_buffer: std.ArrayList(u8),

    const StackItem = struct {
        iter: IterableDir.Iterator,
        dirname_len: usize,
        depth: usize,
    };

    const CrawlerEntry = struct {
        dir: Dir,
        basename: []const u8,
        path: []const u8,
        kind: IterableDir.Entry.Kind,
        depth: usize,
    };

    pub fn next(self: *Crawler) !?CrawlerEntry {
        while (self.stack.items.len != 0) {
            var top = &self.stack.items[self.stack.items.len - 1];
            var containing = top;
            var dirname_len = top.dirname_len;
            var depth = top.depth;
            if (top.iter.next() catch |err| {
                var item = self.stack.pop();
                if (self.stack.items.len != 0) {
                    item.iter.dir.close();
                }
                return err;
            }) |base| {
                self.name_buffer.shrinkRetainingCapacity(dirname_len);
                if (self.name_buffer.items.len != 0) {
                    try self.name_buffer.append(std.fs.path.sep);
                    dirname_len += 1;
                }
                try self.name_buffer.appendSlice(base.name);
                if ((base.kind == .directory) and (depth < @as(usize, self.limit))) {
                    var new_dir = top.iter.dir.openIterableDir(base.name, .{}) catch |err| switch (err) {
                        error.NameTooLong => unreachable,
                        else => |e| return e,
                    };
                    {
                        errdefer new_dir.close();
                        try self.stack.append(StackItem{
                            .iter = new_dir.iterateAssumeFirstIteration(),
                            .dirname_len = self.name_buffer.items.len,
                            .depth = depth + 1,
                        });
                        top = &self.stack.items[self.stack.items.len - 1];
                        containing = &self.stack.items[self.stack.items.len - 2];
                    }
                }
                return CrawlerEntry{
                    .dir = containing.iter.dir,
                    .basename = self.name_buffer.items[dirname_len..],
                    .path = self.name_buffer.items,
                    .kind = base.kind,
                    .depth = depth,
                };
            } else {
                var item = self.stack.pop();
                if (self.stack.items.len != 0) {
                    item.iter.dir.close();
                }
            }
        }
        return null;
    }

    pub fn deinit(self: *Crawler) void {
        if (self.stack.items.len > 1) {
            for (self.stack.items[1..]) |*item| {
                item.iter.dir.close();
            }
        }
        self.stack.deinit();
        self.name_buffer.deinit();
    }
};

pub fn crawl(self: IterableDir, allocator: std.mem.Allocator, limit: u8) !Crawler {
    var name_buffer = std.ArrayList(u8).init(allocator);
    errdefer name_buffer.deinit();

    var stack = std.ArrayList(Crawler.StackItem).init(allocator);
    errdefer stack.deinit();

    try stack.append(Crawler.StackItem{
        .iter = self.iterate(),
        .dirname_len = 0,
        .depth = 1,
    });

    return Crawler{
        .limit = limit,
        .stack = stack,
        .name_buffer = name_buffer,
    };
}
