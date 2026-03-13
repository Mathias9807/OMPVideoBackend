const std = @import("std");
const main = @import("main.zig");

var streamsMutex: std.Thread.Mutex = .{};
var streams: std.ArrayList([]u8) = .empty;

const StreamsResponse = struct {
    message: []u8,
    response: [][]u8,
    statusCode: u32,
};

const PollError = error{
    NoEndpointEnv,
};

pub fn pollStreams() !void {
    var envs = try std.process.getEnvMap(main.alloc);
    defer envs.deinit();

    var host = envs.get("STREAMS_ENDPOINT");
    if (host == null) {
        host = "https://stream.kirr.nu/streams";
    }

    var client = std.http.Client{ .allocator = main.alloc };
    defer client.deinit();

    const connection = client.connectTcp(host.?, 443, .tls) catch null;
    if (connection) |conn| {
        const fd: i32 = conn.stream_reader.file_reader.file.handle;
        const timeval = std.posix.timeval{ .sec = 3, .usec = 0 };
        std.posix.setsockopt(fd, std.posix.IPPROTO.TCP, std.posix.SO.RCVTIMEO, &std.mem.toBytes(timeval)) catch {};
    }

    var bodyWriter: std.Io.Writer.Allocating = .init(main.alloc);
    defer bodyWriter.deinit();

    while (true) {
        // Poll server for streams once per second
        defer std.Thread.sleep(1E9);

        // Send request
        const result = client.fetch(.{
            .location = .{ .url = host.? },
            .method = .GET,
            .response_writer = &bodyWriter.writer,
        }) catch |err| {
            std.debug.print("Failed to connect to remote: {}\n", .{err});
            return undefined;
        };

        if (result.status != .ok) {
            std.debug.print("Request to stream endpoint failed.\n", .{});
            continue;
        }

        const body = try bodyWriter.toOwnedSlice();

        const resp = std.json.parseFromSlice(StreamsResponse, main.alloc, body, .{}) catch |err| {
            std.debug.print("Failed to parse poll response as JSON: {}\nBody: {s}\n", .{ err, body });
            continue;
        };
        defer resp.deinit();

        // Update streams list (mutexed?)
        streamsMutex.lock();
        var oldStreams = streams;
        streams = .empty;
        for (resp.value.response) |stream| {
            try streams.append(main.alloc, stream);
        }
        // const ts = try main.alloc.dupe(u8, "Test");
        // try streams.append(main.alloc, ts);
        streamsMutex.unlock();

        // Check if any new ones have appeared
        outer: for (streams.items) |strm| {
            for (oldStreams.items) |old| {
                if (std.mem.eql(u8, old, strm))
                    continue :outer;
            }

            // New stream
            std.debug.print("New stream: {s}\n", .{strm});
            main.notifyAllNewStream(strm);
        }

        // Free old streams
        oldStreams.deinit(main.alloc);
    }
}

// Get own copy of all active streams. Must be free'd by caller
pub fn getStreams() ![][]u8 {
    streamsMutex.lock();
    defer streamsMutex.unlock();

    const copy = try main.alloc.alloc([]u8, streams.items.len);

    for (streams.items, 0..) |stream, i| {
        copy[i] = try main.alloc.alloc(u8, stream.len);
        @memcpy(copy[i], stream);
    }

    return copy;
}
