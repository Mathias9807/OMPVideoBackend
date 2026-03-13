const std = @import("std");
var gpa = std.heap.DebugAllocator(.{}).init;
pub var alloc: std.mem.Allocator = undefined;

// Server backend for stream service.
// Only has a single route, the base path establishes a websocket connection through which all other communication occurs.
//
// Websocket communication is with JSON text. A type field describes the message type.

const basePath: []const u8 = "/api";

const Client = @import("client.zig");
var clients: std.ArrayList(Client) = .empty;

const streams = @import("streams.zig");

pub fn main() !void {
    alloc = @constCast(&gpa).allocator();
    defer _ = gpa.deinit();

    const address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 15000);

    var server = try address.listen(.{
        .reuse_address = true,
    });
    defer server.deinit();

    _ = try std.Thread.spawn(.{}, streams.pollStreams, .{});

    while (true) {
        try handleConnection(try server.accept());

        // Remove dead clients
        var i: usize = 0;
        while (i < clients.items.len) {
            if (!clients.items[i].alive) {
                _ = clients.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }
}

fn handleConnection(conn: std.net.Server.Connection) !void {
    const read_buffer = try alloc.alloc(u8, 1024);
    var reader = conn.stream.reader(read_buffer);

    const write_buffer = try alloc.alloc(u8, 1024);
    var writer = conn.stream.writer(write_buffer);

    // var buffer = try alloc.alloc(u8, 1024);
    var http_server = std.http.Server.init(reader.interface(), &writer.interface);

    var req = try http_server.receiveHead();
    // try req.respond("Hello world\n", std.http.Server.Request.RespondOptions{});

    // Verify the request was a POST to /<basePath>/
    var target: []const u8 = req.head.target;
    if (target[target.len - 1] == '/') target.len -= 1;

    if (req.head.method != std.http.Method.GET or !std.mem.eql(u8, target, basePath)) {
        req.respond("", .{ .status = .bad_request }) catch |err| {
            std.debug.print("Failed to respond: {}\n", .{err});
        };
        return;
    }

    // try req.respond("Hello world\n", std.http.Server.Request.RespondOptions{});
    const upgradeReq = req.upgradeRequested();
    var websocket = req.respondWebSocket(.{ .key = upgradeReq.websocket.? }) catch |err| {
        std.debug.print("Failed to open websocket: {}\n", .{err});
        return;
    };

    websocket.flush() catch unreachable;

    const c = clients.addOne(alloc) catch unreachable;
    c.websocket = websocket;
    c.read_buf = read_buffer;
    c.write_buf = write_buffer;
    c.alive = true;
    c.thread = try std.Thread.spawn(.{ .allocator = alloc }, Client.processClient, .{c});
}

// Send message to all connected clients that a new stream is available
pub fn notifyAllNewStream(stream: []u8) void {
    std.debug.print("Pinging {} clients\n", .{clients.items.len});
    for (clients.items) |*clt| {
        if (clt.alive) {
            std.debug.print("Client is alive, sending\n", .{});
            clt.sendMessage(Client.NotifyStream, .{ .type = Client.RequestType.new_stream, .stream = stream });
        }
    }
}
