const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

pub const MsgHeader = packed struct {
    len: u32 = 0,
};

fn RpcMethodSend(comptime method: []const u8, comptime params: type) type {
    return struct {
        method: []const u8 = method,
        jsonrpc: []const u8 = "2.0",
        id: u32,
        params: params,
    };
}
// Used for parsing. Method field is comptime for json.parse() to discriminate.
fn RpcMethodRecv(comptime method: []const u8, comptime params: type) type {
    return struct {
        // We don't require client's to include the jsonrpc:"2.0" field.
        comptime method: []const u8 = method,
        id: u32,
        params: params,
    };
}
fn RpcNotifSend(comptime method: []const u8, comptime params: type) type {
    return struct {
        method: []const u8 = method,
        jsonrpc: []const u8 = "2.0",
        params: params,
    };
}
fn RpcNotifRecv(comptime method: []const u8, comptime params: type) type {
    return struct {
        comptime method: []const u8 = method,
        params: params,
    };
}
fn RpcResponseResultSend(comptime Result: type) type {
    return struct { id: u32, jsonrpc: []const u8 = "2.0", result: Result };
}
fn RpcResponseResultRecv(comptime Result: type) type {
    return struct { id: u32, result: Result };
}
fn RpcResponseErrorSend(comptime Error: type) type {
    return struct { id: u32, jsonrpc: []const u8 = "2.0", @"error": Error };
}
fn RpcResponseErrorRecv(comptime Error: type) type {
    return struct { id: u32, @"error": Error };
}

pub const RpcErrorCode = enum(i32) {
    // NOTE: For Command errors, we also happen to use the RPC error code for
    // the exit code in wf-msg.

    // Can't use main c.zig since it depends on libc but wf-msg doesn't link
    // libc.
    const c = @cImport({
        @cInclude("wf-lua.h");
    });

    // generic command error
    CommandError = @intCast(i32, c.WFLUA_IPC_COMMAND_ERROR),
    CommandInvalidArgs = @intCast(i32, c.WFLUA_IPC_COMMAND_INVALID_ARGS),

    pub fn jsonStringify(
        self: @This(),
        options: json.StringifyOptions,
        out_stream: anytype,
    ) @TypeOf(out_stream).Error!void {
        return json.stringify(@enumToInt(self), options, out_stream);
    }
};

pub const Command = struct {
    pub const Params = struct {
        command: []const u8,
        args: [][]const u8,
    };

    // Using distict field named so that the json parser can discriminate.
    pub const Result = struct { cmd_result: []const u8 };
    pub const BeginingNotifs = struct { begin_notifs: bool = true };
    pub const Error = struct {
        code: RpcErrorCode,
        message: []const u8,
    };

    pub const ReqSend = RpcMethodSend("command", Params);
    pub const ReqRecv = RpcMethodRecv("command", Params);
    pub const RespSend = union(enum) {
        Result: RpcResponseResultSend(Result),
        BeginingNotifs: RpcResponseResultSend(BeginingNotifs),
        Error: RpcResponseErrorSend(Error),
    };
    pub const RespRecv = union(enum) {
        Result: RpcResponseResultRecv(Result),
        BeginingNotifs: RpcResponseResultRecv(BeginingNotifs),
        Error: RpcResponseErrorRecv(Error),
    };
    pub const NotifSend = union(enum) {
        Notif: RpcNotifSend("cmd_notif", struct { id: u32, notif: []const u8 }),
        NotifEnd: RpcNotifSend("cmd_notif_end", struct { id: u32 }),
    };
    pub const NotifRecv = union(enum) {
        Notif: RpcNotifRecv("cmd_notif", struct { id: u32, notif: []const u8 }),
        NotifEnd: RpcNotifRecv("cmd_notif_end", struct { id: u32 }),
    };
};

pub const RequestRecv = union(enum) {
    Command: Command.ReqRecv,
};

pub fn Protocol(comptime Reader: type, comptime Writer: type) type {
    return struct {
        allocator: *Allocator,
        reader: Reader,
        writer: Writer,

        fn getJsonParseOpts(self: *const @This()) json.ParseOptions {
            return .{
                .allocator = self.allocator,
                .ignore_unknown_fields = true,
                .allow_trailing_data = false,
            };
        }

        fn sendMsg(
            self: *const @This(),
            msg_buf: *std.ArrayList(u8),
            msg: anytype,
        ) !void {
            try json.stringify(msg, .{}, msg_buf.writer());

            const header = MsgHeader{
                .len = try std.math.cast(u32, msg_buf.items.len),
            };

            try self.writer.writeStruct(header);
            try self.writer.writeAll(msg_buf.items);
        }

        fn nextRequestImpl(
            self: *const @This(),
            comptime ReqType: type,
        ) !?ReqType {
            var recv_header: MsgHeader = undefined;
            const recv_len = try self.reader.read(
                @ptrCast(*[@sizeOf(MsgHeader)]u8, &recv_header),
            );

            // EOF between messages is well-formed
            if (recv_len == 0)
                return null;

            var msg_buf = std.ArrayList(u8).init(self.allocator);
            defer msg_buf.deinit();

            try msg_buf.resize(recv_header.len);
            try self.reader.readNoEof(msg_buf.items);
            return try json.parse(
                ReqType,
                &json.TokenStream.init(msg_buf.items),
                self.getJsonParseOpts(),
            );
        }

        // == Client ==

        pub fn nextNotif(
            self: *const @This(),
            comptime NotifType: type,
        ) !?NotifType {
            return self.nextRequestImpl(NotifType);
        }
        pub fn freeNotif(self: *const @This(), notif: anytype) void {
            json.parseFree(@TypeOf(notif), notif, self.getJsonParseOpts());
        }

        /// Make a request and read the response.
        pub fn request(
            self: *const @This(),
            comptime Resp: type,
            req: anytype,
        ) !Resp {
            var msg_buf = std.ArrayList(u8).init(self.allocator);
            defer msg_buf.deinit();

            // Send:
            try self.sendMsg(&msg_buf, req);

            // Recv:
            var recv_header: MsgHeader = undefined;
            try self.reader.readNoEof(
                @ptrCast(*[@sizeOf(MsgHeader)]u8, &recv_header),
            );
            try msg_buf.resize(recv_header.len);
            try self.reader.readNoEof(msg_buf.items);
            return try json.parse(
                Resp,
                &json.TokenStream.init(msg_buf.items),
                self.getJsonParseOpts(),
            );
        }
        pub fn freeResponse(
            self: *const @This(),
            resp: anytype,
        ) void {
            json.parseFree(@TypeOf(resp), resp, self.getJsonParseOpts());
        }

        // == Server ==

        pub fn nextRequest(self: *const @This()) !?RequestRecv {
            return self.nextRequestImpl(RequestRecv);
        }
        pub fn freeRequest(self: *const @This(), req: RequestRecv) void {
            json.parseFree(RequestRecv, req, self.getJsonParseOpts());
        }

        pub fn sendResponse(self: *const @This(), resp: anytype) !void {
            var msg_buf = std.ArrayList(u8).init(self.allocator);
            defer msg_buf.deinit();

            try self.sendMsg(&msg_buf, resp);
        }

        pub fn sendNotif(self: *const @This(), notif: anytype) !void {
            var msg_buf = std.ArrayList(u8).init(self.allocator);
            defer msg_buf.deinit();

            try self.sendMsg(&msg_buf, notif);
        }
    };
}
