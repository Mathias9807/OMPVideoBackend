const std = @import("std");
const main = @import("main.zig");
const streams = @import("streams.zig");

// Client-to-Server message types:
// - list_streams: retrieves a list of active streams
// - chat_stream: send a chat message to a specific stream
// - watching: notify server of which streams you're watching
//
// Server-to-Client message types:
// - new_stream: notify client of a new stream
// - chat: notify client of a message to a stream they're watching

const Client = @This();

websocket: std.http.Server.WebSocket,
thread: std.Thread,
alive: bool,

read_buf: []u8,
write_buf: []u8,

const ClientError = error{
    ConnectionClosed,
    UnsupportedFormat,
    Unknown,
};

pub const RequestType = enum {
    bare,
    list_streams,
    chat_stream,
    watching,
    new_stream,
    chat,
};

const BareRequest = struct {
    type: RequestType,
    id: u32,
};

const ListStreamsRequest = struct {
    type: RequestType,
    id: u32,
};
const ListStreamsResponse = struct {
    streams: [][]u8,
    id: u32,
};

pub const NotifyStream = struct {
    type: RequestType,
    stream: []u8,
};

fn readPacket(c: *Client) ![]u8 {
    var msg = c.websocket.readSmallMessage() catch |err| switch (err) {
        error.ConnectionClose => return ClientError.ConnectionClosed,
        error.EndOfStream => return ClientError.ConnectionClosed,
        else => {
            std.debug.print("Read failed: {}\n", .{err});
            return ClientError.Unknown;
        },
    };
    std.debug.print("\treadPacket: read message {}\n", .{msg.opcode});

    while (msg.opcode != .text) {
        switch (msg.opcode) {
            .ping => try c.websocket.writeMessage("", .pong),
            .connection_close => return ClientError.ConnectionClosed,
            .binary => return ClientError.UnsupportedFormat,
            else => {},
        }

        msg = try c.websocket.readSmallMessage();
    }

    return msg.data;
}

pub fn processClient(c: *Client) void {

    std.debug.print("Starting client thread...\n", .{});
    while (true) {
        const req = readPacket(c) catch |err| switch (err) {
            ClientError.UnsupportedFormat => {
                std.debug.print("Client sent binary data?\n", .{});
                continue;
            },
            ClientError.ConnectionClosed => break,
            else => {
                std.debug.print("Message reading failed! {}\n", .{err});
                break;
            },
        };

        std.debug.print("Received packet\n", .{});

        // Convert req json to an unmarshalled struct
        const parsed = std.json.parseFromSlice(BareRequest, main.alloc, req, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            std.debug.print("Parse error: {}\n", .{err});
            continue;
        };
        defer parsed.deinit();

        std.debug.print("Received JSON: {s}\n", .{@tagName(parsed.value.type)});

        switch (parsed.value.type) {
            .bare => continue,
            .list_streams => handleListStreams(c, req),
            else => continue,
        }
    }

    main.alloc.free(c.read_buf);
    main.alloc.free(c.write_buf);
    c.alive = false;

    std.debug.print("Killing client thread\n", .{});
}

fn handleListStreams(c: *Client, reqData: []u8) void {
    const req = std.json.parseFromSlice(ListStreamsRequest, main.alloc, reqData, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.debug.print("Parse error: {}\n", .{err});
        return;
    };
    defer req.deinit();

    const strms = streams.getStreams() catch {
        sendMessage(c, ListStreamsResponse, .{ .streams = undefined, .id = req.value.id });
        return;
    };
    const resp = ListStreamsResponse{ .streams = strms, .id = req.value.id };
    sendMessage(c, ListStreamsResponse, resp);

    for (strms) |strm| main.alloc.free(strm);
    main.alloc.free(strms);
}

pub fn sendMessage(c: *Client, comptime ResponseType: anytype, value: ResponseType) void {
    var encoded: std.Io.Writer.Allocating = .init(main.alloc);
    encoded.writer.print("{f}", .{std.json.fmt(value, .{})}) catch |err| {
        std.debug.print("Failed to encode JSON response: {}\n", .{err});
        return;
    };
    c.websocket.writeMessage(encoded.written(), .text) catch |err| {
        std.debug.print("Failed to send response: {}\n", .{err});
    };
}
