const std = @import("std");
const ipc = @import("ipc.zig");

const os = std.os;
const net = std.net;
const mem = std.mem;

fn printHelp() !void {
    const stdout = std.io.getStdOut();
    try stdout.writeAll("Usage: ");
    try stdout.writeAll(mem.span(os.argv[0]));
    try stdout.writeAll(" [-h] <command> <args>\n");
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit())
        std.log.err("Main allocator detected leaks.", .{});

    var argv = try gpa.allocator.alloc([]const u8, os.argv.len);
    defer gpa.allocator.free(argv);
    for (os.argv) |arg, i|
        argv[i] = mem.span(arg);

    const args = argv[1..argv.len];

    if (args.len == 0) {
        std.log.err("Missing <command> argument.", .{});
        try printHelp();
        return 1;
    }
    if (mem.eql(u8, args[0], "-h")) {
        try printHelp();
        return 0;
    }

    const socket_path = os.getenv("WFIPC_SOCKET") orelse {
        std.log.err("Cannot get socket path. " ++
            "Environment variable WFIPC_SOCKET not set.", .{});
        return 1;
    };

    const stream = try net.connectUnixSocket(socket_path);
    defer stream.close();

    const proto = ipc.Protocol(@TypeOf(stream).Reader, @TypeOf(stream).Writer){
        .allocator = &gpa.allocator,
        .reader = stream.reader(),
        .writer = stream.writer(),
    };
    const resp = try proto.request(ipc.Command.RespRecv, ipc.Command.ReqSend{
        .id = 1,
        .params = .{
            .command = args[0],
            .args = args[1..args.len],
        },
    });
    defer proto.freeResponse(resp);

    switch (resp) {
        .Result => {
            const stdout = std.io.getStdOut().writer();
            try stdout.writeAll(resp.Result.result.cmd_result);
            try stdout.writeAll("\n");
        },
        .Error => {
            const stderr = std.io.getStdErr().writer();
            try stderr.writeAll(resp.Error.@"error".message);
            try stderr.writeAll("\n");

            // All command errors should fit into u8.
            return @intCast(u8, @enumToInt(resp.Error.@"error".code));
        },
        .BeginingNotifs => {
            const stdout = std.io.getStdOut().writer();

            while (try proto.nextNotif(ipc.Command.NotifRecv)) |notif_| {
                defer proto.freeNotif(notif_);
                switch (notif_) {
                    .Notif => |notif| {
                        try stdout.writeAll(notif.params.notif);
                        try stdout.writeAll("\n");
                    },
                    .NotifEnd => {
                        return 0;
                    },
                }
            }
        },
    }
    return 0;
}
