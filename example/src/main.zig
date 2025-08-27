const std = @import("std");
const tracy = @import("tracy");

var finalise_threads = std.atomic.Value(bool).init(false);

fn handleSigInt(_: c_int) callconv(.c) void {
    finalise_threads.store(true, .release);
}

pub fn main() !void {
    tracy.setThreadName("Main");
    defer tracy.message("Graceful main thread exit");

    std.posix.sigaction(std.posix.SIG.INT, &.{
        .handler = .{ .handler = handleSigInt },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, null);

    const other_thread = try std.Thread.spawn(.{}, otherThread, .{});
    defer other_thread.join();

    while (!finalise_threads.load(.acquire)) {
        tracy.frameMark();

        const zone = tracy.initZone(@src(), .{ .name = "Important work" });
        defer zone.deinit();
        std.Thread.sleep(100);
    }
}

fn otherThread() void {
    tracy.setThreadName("Other");
    defer tracy.message("Graceful other thread exit");

    var os_allocator = tracy.TracingAllocator.init(std.heap.page_allocator);

    const tracing_arena = tracy.TracingArena.init(os_allocator.allocator(), "arena") catch @panic("Welp");
    defer tracing_arena.deinit();
    const allocator = tracing_arena.allocator;

    var stack: std.ArrayList(u8) = .empty;
    defer stack.deinit(allocator);

    var stdin_buffer: [1024]u8 = undefined;
    var stdout_buffer: [1024]u8 = undefined;
    var writer_buffer: [1024]u8 = undefined;
    var stdin = std.fs.File.stdin().reader(&stdin_buffer).interface;
    var stdout = std.fs.File.stdout().writer(&stdout_buffer).interface;

    while (!finalise_threads.load(.acquire)) {
        const zone = tracy.initZone(@src(), .{ .name = "IO loop" });
        defer zone.deinit();

        stdout.print("Enter string: ", .{}) catch break;

        {
            const stream_zone = tracy.initZone(@src(), .{ .name = "Writer.streamDelimiter" });
            defer stream_zone.deinit();
            var stream_writer = stack.writer(allocator).adaptToNewApi(&writer_buffer).new_interface;
            _ = stdin.streamDelimiter(&stream_writer, '\n') catch break;
        }

        var str: []u8 = undefined;
        {
            const toowned_zone = tracy.initZone(@src(), .{ .name = "ArrayList.toOwnedSlice" });
            defer toowned_zone.deinit();
            str = stack.toOwnedSlice(allocator) catch break;
            defer allocator.free(str);
        }

        {
            const reverse_zone = tracy.initZone(@src(), .{ .name = "std.mem.reverse" });
            defer reverse_zone.deinit();
            std.mem.reverse(u8, str);
        }

        stdout.print("Reversed: {s}\n", .{str}) catch break;
    }
}
