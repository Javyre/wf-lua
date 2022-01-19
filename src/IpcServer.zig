const std = @import("std");
const c = @import("c.zig");
const ipc = @import("ipc.zig");
const Lua = @import("Lua.zig");

const io = std.io;
const os = std.os;
const net = std.net;
const json = std.json;

const Allocator = std.mem.Allocator;
const This = @This();
const IpcServer = @This();

socket_server: IpcAsyncSocketServer,
allocator: *Allocator,

/// The lua state handle.
L: *c.lua_State,

/// The ipc command lua callback ref.
command_callback_ref: Lua.Ref,

fn AsyncSocketServer(comptime Parent: type, comptime Handler: type) type {
    return struct {
        const AsyncServer = @This();

        pub const ClientFrameState = struct {
            stream: net.Stream,

            waiting_for: ?WaitingFor = null,
            suspended_frame: ?anyframe = null,
            stop_loop: bool = false,
            wl_event_mask: ?u32 = null,
            async_server: *AsyncServer,
            inbox: ?union(enum) {
                IpcCommandResolve: [*:0]const u8,
                IpcCommandReject: struct {
                    err: [*:0]const u8,
                    error_code: c_int,
                },
                IpcCommandBeginNotifs: void,
                IpcCommandEndNotifs: void,
                IpcCommandNotify: [*:0]const u8,
            } = null,

            const WaitingFor = enum { read, write, ipc_command };

            const ResumeError = error{
                ClientFrameShuttingDown,
                WlSocketError,
                WlSocketHangup,
            };
            pub const ReadError = os.ReadError || ResumeError;
            pub const WriteError = os.WriteError || ResumeError;

            pub const Reader = io.Reader(*@This(), ReadError, read);
            pub const Writer = io.Writer(*@This(), WriteError, write);

            fn resumeFrame(self: *@This()) void {
                resume self.suspended_frame.?;

                // Frame has not suspended so has returned.
                if (self.suspended_frame == null) {
                    // Clean up the client frame.
                    const server = self.async_server;
                    const kv = server.active_clients.?.fetchRemove(
                        self.stream.handle,
                    ).?;

                    self.stream.close();
                    _ = c.wl_event_source_remove(kv.value.event_source);
                    // free the ClientFrame.
                    server.allocator.destroy(kv.value.frame);
                }
            }

            fn suspendFrame(self: *@This(), reason: WaitingFor) !void {
                suspend {
                    self.waiting_for = reason;
                    self.inbox = null;
                    self.suspended_frame = @frame();
                    self.wl_event_mask = null;
                }
                self.waiting_for = null;
                self.suspended_frame = null;
                defer self.wl_event_mask = null;

                if (self.wl_event_mask) |mask| {
                    if (mask & c.WL_EVENT_ERROR != 0) {
                        return error.WlSocketError;
                    } else if (mask & c.WL_EVENT_HANGUP != 0) {
                        return error.WlSocketHangup;
                    }
                }
                if (self.stop_loop)
                    return error.ClientFrameShuttingDown;
            }

            pub fn read(self: *@This(), buf: []u8) ReadError!usize {
                while (true) {
                    return self.stream.read(buf) catch |err| switch (err) {
                        error.WouldBlock => {
                            // Treat HUP as EOF.
                            self.suspendFrame(.read) catch |err2|
                                switch (err2) {
                                error.WlSocketHangup => return 0,
                                else => |e| return e,
                            };
                            continue;
                        },
                        else => |e| return e,
                    };
                }
            }

            pub fn write(self: *@This(), buf: []const u8) WriteError!usize {
                while (true) {
                    return self.stream.write(buf) catch |err| switch (err) {
                        error.WouldBlock => {
                            try self.suspendFrame(.write);
                            continue;
                        },
                        else => |e| return e,
                    };
                }
            }

            pub fn reader(self: *@This()) Reader {
                return .{ .context = self };
            }

            pub fn writer(self: *@This()) Writer {
                return .{ .context = self };
            }
        };

        const ClientFrame = struct {
            frame: @Frame(runClientHandler),
            state: ClientFrameState,
        };
        const ActiveClientsMap = std.AutoHashMap(
            os.socket_t,
            struct {
                frame: *ClientFrame,
                event_source: *c.wl_event_source,
            },
        );

        is_loop_active: bool = false,
        stop_loop: bool = false,
        sock_fd: ?os.socket_t = null,
        event_source: ?*c.wl_event_source = null,
        loop_frame: @Frame(mainLoop) = undefined,
        suspended_frame: ?anyframe = null,

        parent: *Parent = undefined,
        active_clients: ?ActiveClientsMap = null,
        allocator: *Allocator,

        // NOTE: once initialized, this struct should no longer be copied/moved
        // around.
        pub fn init(
            self: *@This(),
            allocator: *Allocator,
            socket_path: []const u8,
            parent: *Parent,
        ) !void {
            self.allocator = allocator;
            self.parent = parent;

            self.active_clients = ActiveClientsMap.init(allocator);
            errdefer self.active_clients.?.deinit();

            const address = try net.Address.initUnix(socket_path);
            const sock_flags =
                os.SOCK_STREAM | os.SOCK_CLOEXEC | os.SOCK_NONBLOCK;
            const sock_fd = try os.socket(address.any.family, sock_flags, 0);
            self.sock_fd = sock_fd;
            errdefer {
                os.closeSocket(sock_fd);
                self.sock_fd = null;
            }

            const socklen = address.getOsSockLen();
            os.bind(sock_fd, &address.any, socklen) catch |err| switch (err) {
                error.AddressInUse => {
                    std.log.err(
                        "Bind failed! Socket in use: {s}",
                        .{socket_path},
                    );
                    return err;
                },
                else => return err,
            };
            try os.listen(sock_fd, 5);

            // NOTE: a normal `async self.mainLoop();` call here crashes the
            // compiler :(. This is just a workaround.
            _ = @asyncCall(&self.loop_frame, {}, mainLoop, .{self});

            // Resume the main loop when the socket becomes readable (i.e. when
            // there is an incoming connection)
            self.event_source = c.wl_event_loop_add_fd(
                c.wf_Core_get_event_loop(c.wf_get_core()),
                sock_fd,
                c.WL_EVENT_READABLE,
                mainLoopTick,
                @ptrCast(*c_void, self),
            ).?;
        }

        pub fn deinit(self: *@This()) !void {
            if (self.active_clients) |*active_conns| {
                self.stopClientFrames();
                active_conns.deinit();
            }

            if (self.is_loop_active) {
                self.stop_loop = true;
                resume self.suspended_frame.?;
                std.debug.assert(!self.is_loop_active);
            }

            if (self.event_source) |evt_souce| {
                _ = c.wl_event_source_remove(evt_souce);
            }

            if (self.sock_fd) |sock_fd| {
                std.log.debug("closing socket. {any}", .{sock_fd});
                os.closeSocket(sock_fd);
                self.sock_fd = null;
            }
        }

        pub fn reset(self: *@This()) void {
            if (self.active_clients != null)
                self.stopClientFrames();
        }

        fn stopClientFrames(self: *@This()) void {
            const active_conns = &(self.active_clients.?);
            // Cannot just keep using the same iterator since it is
            // invalidated when the frame returns and removes the map entry.
            var conn_count = active_conns.count();
            while (conn_count > 0) : (conn_count -= 1) {
                const conn_frame: *ClientFrame =
                    active_conns.valueIterator().next().?.frame;

                conn_frame.state.stop_loop = true;
                conn_frame.state.resumeFrame();
            }
            // All frames should have cleaned up and returned.
            std.debug.assert(active_conns.count() == 0);
        }

        fn mainLoopTick(
            fd: c_int,
            mask: u32,
            data: ?*c_void,
        ) callconv(.C) c_int {
            const self = @ptrCast(
                *@This(),
                @alignCast(@alignOf(@This()), data),
            );
            std.debug.assert(mask == c.WL_EVENT_READABLE);
            resume self.suspended_frame.?;

            return 0;
        }

        fn clientFrameTick(
            fd: c_int,
            mask: u32,
            data: ?*c_void,
        ) callconv(.C) c_int {
            const client_frame = @ptrCast(
                *ClientFrame,
                @alignCast(@alignOf(ClientFrame), data),
            );

            const need_resume = x: {
                if (mask & (c.WL_EVENT_ERROR | c.WL_EVENT_HANGUP) != 0) {
                    break :x true;
                } else if (client_frame.state.waiting_for) |waiting_for| {
                    if ((waiting_for == .read and
                        mask & c.WL_EVENT_READABLE != 0) or
                        (waiting_for == .write and
                        mask & c.WL_EVENT_WRITABLE != 0))
                    {
                        break :x true;
                    }
                }
                break :x false;
            };

            if (need_resume) {
                client_frame.state.wl_event_mask = mask;
                client_frame.state.resumeFrame();
            }

            return 0;
        }

        fn mainLoop(self: *@This()) void {
            self.is_loop_active = true;
            while (true) {
                // TODO: only suspend on EWOULDBLOCK error. So we can handle all
                // pending connections before waiting for more.

                // Wait to be resumed on a new connection.
                suspend {
                    self.suspended_frame = @frame();
                }
                self.suspended_frame = null;

                if (self.stop_loop) {
                    self.is_loop_active = false;
                    return;
                }

                const conn_fd = os.accept(
                    self.sock_fd.?,
                    null,
                    null,
                    os.SOCK_NONBLOCK | os.SOCK_CLOEXEC,
                ) catch |err| {
                    std.log.err(
                        "Failed to accept ipc client connection: {}",
                        .{err},
                    );
                    continue;
                };
                const conn_stream = net.Stream{ .handle = conn_fd };

                std.log.debug(
                    "Client frame size: {d}",
                    .{@sizeOf(ClientFrame)},
                );
                const conn_frame = self.allocator.create(
                    ClientFrame,
                ) catch |err| {
                    std.log.err(
                        "Failed to allocate connection handler frame: {}",
                        .{err},
                    );
                    conn_stream.close();
                    continue;
                };

                const event_source = c.wl_event_loop_add_fd(
                    c.wf_Core_get_event_loop(c.wf_get_core()),
                    conn_fd,
                    c.WL_EVENT_READABLE | c.WL_EVENT_WRITABLE,
                    clientFrameTick,
                    @ptrCast(*c_void, conn_frame),
                ).?;

                self.active_clients.?.put(
                    conn_fd,
                    .{
                        .frame = conn_frame,
                        .event_source = event_source,
                    },
                ) catch |err| {
                    std.log.err(
                        "Failed to put new active_connection entry: {}",
                        .{err},
                    );
                    conn_stream.close();
                    self.allocator.destroy(conn_frame);
                    _ = c.wl_event_source_remove(event_source);
                    continue;
                };

                std.log.debug(
                    "Active ipc connections: {d}",
                    .{self.active_clients.?.count()},
                );

                conn_frame.* = ClientFrame{
                    .state = ClientFrameState{
                        .stream = conn_stream,
                        .async_server = self,
                    },
                    .frame = undefined,
                };
                _ = @asyncCall(&conn_frame.frame, {}, runClientHandler, .{
                    self,
                    &conn_frame.state,
                });
            }
        }

        fn runClientHandler(self: *@This(), state: *ClientFrameState) void {
            Handler.handleClient(
                ClientFrameState,
                self.parent,
                state,
            ) catch |err| switch (err) {
                error.ClientFrameShuttingDown => {
                    std.log.debug("Client socket shutdown.", .{});
                },
                else => |e| {
                    std.log.err("Socket client handler failed: {}", .{e});
                    if (@errorReturnTrace()) |trace|
                        std.debug.dumpStackTrace(trace.*);
                },
            };
        }
    };
}

fn getSocketPath(out_buf: []u8) ![:0]const u8 {
    var a = std.heap.FixedBufferAllocator.init(out_buf);

    if (std.os.getenv("WFIPC_SOCKET")) |file| {
        return a.allocator.dupeZ(u8, file);
    } else {
        var sock_file_buf: [50]u8 = undefined;
        const sock_file = try std.fmt.bufPrint(
            &sock_file_buf,
            "wf-ipc.{d}.{d}.sock",
            .{ c.getpid(), c.getuid() },
        );

        if (std.os.getenv("XDG_RUNTIME_DIR")) |rt_dir| {
            return try std.fs.path.joinZ(
                &a.allocator,
                &.{ rt_dir, sock_file },
            );
        } else {
            return try std.fs.path.joinZ(
                &a.allocator,
                &.{ "/tmp/", sock_file },
            );
        }
    }
}

export fn wflua_ipc_command_resolve(
    state_: *c_void,
    result: [*:0]const u8,
) void {
    const State = IpcAsyncSocketServer.ClientFrameState;
    const state = @ptrCast(*State, @alignCast(@alignOf(*State), state_));

    std.debug.assert(state.waiting_for.? == .ipc_command);
    state.inbox = .{ .IpcCommandResolve = result };
    state.resumeFrame();
}
export fn wflua_ipc_command_reject(
    state_: *c_void,
    err: [*:0]const u8,
    error_code: c_int,
) void {
    const State = IpcAsyncSocketServer.ClientFrameState;
    const state = @ptrCast(*State, @alignCast(@alignOf(*State), state_));

    std.debug.assert(state.waiting_for.? == .ipc_command);
    state.inbox = .{
        .IpcCommandReject = .{ .err = err, .error_code = error_code },
    };
    state.resumeFrame();
}
export fn wflua_ipc_command_begin_notifications(
    state_: *c_void,
) void {
    const State = IpcAsyncSocketServer.ClientFrameState;
    const state = @ptrCast(*State, @alignCast(@alignOf(*State), state_));

    std.debug.assert(state.waiting_for.? == .ipc_command);
    state.inbox = .{ .IpcCommandBeginNotifs = {} };
    state.resumeFrame();
}
export fn wflua_ipc_command_notify(
    state_: *c_void,
    notif: ?[*:0]const u8,
) void {
    const State = IpcAsyncSocketServer.ClientFrameState;
    const state = @ptrCast(*State, @alignCast(@alignOf(*State), state_));

    std.debug.assert(state.waiting_for.? == .ipc_command);
    if (notif) |n| {
        state.inbox = .{ .IpcCommandNotify = n };
    } else {
        state.inbox = .{ .IpcCommandEndNotifs = {} };
    }
    state.resumeFrame();
}

fn forwardAsyncNotifs(
    self: *This,
    state: *IpcAsyncSocketServer.ClientFrameState,
    proto: anytype,
    req: ipc.Command.ReqRecv,
    cancel_ref: Lua.Ref,
) !void {
    notifs: while (true) {
        state.suspendFrame(.ipc_command) catch |err| switch (err) {
            error.WlSocketHangup,
            error.WlSocketError,
            error.ClientFrameShuttingDown,
            => |e| {
                std.log.info(
                    "Received {} while command notifying. " ++
                        "Cancelling command promise for {s}.",
                    .{ e, req.params.command },
                );
                Lua.rawGetRef(self.L, cancel_ref);
                try Lua.pcall(self.L, .{ .nargs = 0, .nresults = 0 });

                if (e == error.ClientFrameShuttingDown) {
                    return e;
                } else {
                    return;
                }
            },
            else => |e| return e,
        };
        switch (state.inbox.?) {
            .IpcCommandNotify => |notif| {
                try proto.sendNotif(ipc.Command.NotifSend{ .Notif = .{
                    .params = .{ .id = req.id, .notif = std.mem.span(notif) },
                } });
            },
            .IpcCommandEndNotifs => {
                try proto.sendNotif(ipc.Command.NotifSend{ .NotifEnd = .{
                    .params = .{ .id = req.id },
                } });
                break :notifs;
            },

            // These are invalid/impossible since we already began
            // notifications.
            .IpcCommandResolve,
            .IpcCommandReject,
            .IpcCommandBeginNotifs,
            => unreachable,
        }
    }
}

fn dispatchCommand(
    self: *This,
    state: *IpcAsyncSocketServer.ClientFrameState,
    proto: anytype,
    req: ipc.Command.ReqRecv,
) !void {
    const orig_stack_len = c.lua_gettop(self.L);

    Lua.rawGetRef(self.L, self.command_callback_ref);

    // 3 arguments: handle, command, args
    const handle = @ptrCast(*c_void, @alignCast(@alignOf(*c_void), state));
    c.lua_pushlightuserdata(self.L, handle);
    c.lua_pushlstring(self.L, req.params.command.ptr, req.params.command.len);
    {
        c.lua_createtable(self.L, @intCast(c_int, req.params.args.len), 0);
        var i: u16 = 1;
        for (req.params.args) |arg| {
            c.lua_pushlstring(self.L, arg.ptr, arg.len);
            c.lua_rawseti(self.L, -2, i);
            i += 1;
        }
    }
    try Lua.pcall(self.L, .{ .nargs = 3, .nresults = 4 });

    // 4 return values: status, result, error_code, cancel_cb

    // status:
    // - 0 = promise pending (request-response/notifier command),
    // - 1 = promise resolved (request-response command),
    // - 2 = notifications begun (notifier command),
    const status = @intCast(u8, c.lua_tointeger(self.L, -4));
    switch (status) {
        // promise pending (request-response/notifier command),
        0 => {
            // CASE0: Command resolves on some future event. Pending returned.
            //        Result/Error resolved later.

            // Top of the stack is the last return value which is the cancel cb.
            // We take a ref so that we can leave the stack clean before
            // suspending.
            const cancel_ref = Lua.ref(self.L); // pops the cancel_cb
            defer Lua.unref(self.L, cancel_ref);
            c.lua_pop(self.L, 3); // pops the rest of the returns

            // Stack should be clean now.
            std.debug.assert(c.lua_gettop(self.L) == orig_stack_len);

            state.suspendFrame(.ipc_command) catch |err| switch (err) {
                error.WlSocketHangup,
                error.WlSocketError,
                error.ClientFrameShuttingDown,
                => |e| {
                    std.log.info(
                        "Received {} while command pending. " ++
                            "Cancelling command promise for {s}.",
                        .{ e, req.params.command },
                    );
                    Lua.rawGetRef(self.L, cancel_ref);
                    try Lua.pcall(self.L, .{ .nargs = 0, .nresults = 0 });

                    if (e == error.ClientFrameShuttingDown) {
                        return e;
                    } else {
                        return;
                    }
                },
                else => |e| return e,
            };
            switch (state.inbox.?) {
                .IpcCommandResolve => |result| {
                    try proto.sendResponse(ipc.Command.RespSend{ .Result = .{
                        .id = req.id,
                        .result = .{ .cmd_result = std.mem.span(result) },
                    } });
                },
                .IpcCommandReject => |inbox| {
                    try proto.sendResponse(ipc.Command.RespSend{
                        .Error = .{
                            .id = req.id,
                            .@"error" = .{
                                .code = @intToEnum(
                                    ipc.RpcErrorCode,
                                    @intCast(i32, inbox.error_code),
                                ),
                                .message = std.mem.span(inbox.err),
                            },
                        },
                    });
                },
                .IpcCommandBeginNotifs => {
                    try proto.sendResponse(ipc.Command.RespSend{
                        .BeginingNotifs = .{ .id = req.id, .result = .{} },
                    });
                    try self.forwardAsyncNotifs(state, proto, req, cancel_ref);
                },
                .IpcCommandEndNotifs,
                .IpcCommandNotify,
                => unreachable,
            }
        },

        // promise resolved (request-response command),
        1 => {
            // CASE1: Command resolved during pcall. Result/Error returned.

            defer {
                c.lua_pop(self.L, 4);
                std.debug.assert(c.lua_gettop(self.L) == orig_stack_len);
            }
            const result = Lua.tostring(self.L, -3);
            const error_code = @intCast(i32, c.lua_tointeger(self.L, -2));

            if (error_code == 0) {
                try proto.sendResponse(ipc.Command.RespSend{ .Result = .{
                    .id = req.id,
                    .result = .{ .cmd_result = result },
                } });
            } else {
                try proto.sendResponse(ipc.Command.RespSend{ .Error = .{
                    .id = req.id,
                    .@"error" = .{
                        .code = @intToEnum(ipc.RpcErrorCode, error_code),
                        .message = result,
                    },
                } });
            }
        },

        // notifications begun (notifier command),
        2 => {
            // CASE2: Command is a notifier command.
            // return values: 2, result(array of notifs), nil, cancel_cb

            try proto.sendResponse(ipc.Command.RespSend{
                .BeginingNotifs = .{ .id = req.id, .result = .{} },
            });

            // Carry out the synchronous notifs returned.
            {
                std.debug.assert(c.lua_istable(self.L, -3));
                const notifs_len = c.lua_objlen(self.L, -3);
                var i: c_int = 1;
                while (i <= notifs_len) : (i += 1) {
                    c.lua_rawgeti(self.L, -3, i);

                    if (c.lua_isstring(self.L, -1) != 0) {
                        const notif = Lua.tostring(self.L, -1);

                        try proto.sendNotif(ipc.Command.NotifSend{
                            .Notif = .{
                                .params = .{ .id = req.id, .notif = notif },
                            },
                        });
                    } else {
                        // end_notifications was sent.
                        std.debug.assert(i == notifs_len);

                        try proto.sendNotif(ipc.Command.NotifSend{
                            .NotifEnd = .{
                                .params = .{ .id = req.id },
                            },
                        });

                        c.lua_pop(self.L, 1); // pop the notif.
                        c.lua_pop(self.L, 4);
                        std.debug.assert(
                            c.lua_gettop(self.L) == orig_stack_len,
                        );
                        return;
                    }

                    c.lua_pop(self.L, 1);
                }
            }

            // Top of the stack is the last return value which is the cancel cb.
            // We take a ref so that we can leave the stack clean before
            // suspending.
            const cancel_ref = Lua.ref(self.L); // pops the cancel_cb
            defer Lua.unref(self.L, cancel_ref);
            c.lua_pop(self.L, 3); // pops the rest of the returns

            // Stack should be clean now.
            std.debug.assert(c.lua_gettop(self.L) == orig_stack_len);

            try self.forwardAsyncNotifs(state, proto, req, cancel_ref);
        },

        else => unreachable,
    }
}

const IpcAsyncSocketServer = AsyncSocketServer(IpcServer, struct {
    fn handleClient(
        comptime State: type,
        self: *IpcServer,
        state: *State,
    ) !void {
        std.log.debug("New connection!", .{});

        const Reader = @TypeOf(state.*).Reader;
        const Writer = @TypeOf(state.*).Writer;
        const proto = ipc.Protocol(Reader, Writer){
            .allocator = self.allocator,
            .reader = state.reader(),
            .writer = state.writer(),
        };

        while (try proto.nextRequest()) |req| {
            defer proto.freeRequest(req);

            var timer = try std.time.Timer.start();
            try self.dispatchCommand(
                state,
                proto,
                req.Command,
            );
            std.log.debug("Command handled in {d}ms", .{
                @intToFloat(f64, timer.read()) / std.time.ns_per_ms,
            });
        }

        std.log.debug("Connection closed.", .{});
    }
});

pub fn init(self: *This, allocator: *Allocator, L: *c.lua_State) !void {
    var socket_path_buf: [120]u8 = undefined;
    const socket_path = try getSocketPath(&socket_path_buf);

    // Export the variable
    const errno = c.setenv("WFIPC_SOCKET", socket_path, 1);
    if (errno != 0)
        std.log.err("Failed to set WFIPC_SOCKET envvar: errno={d}", .{errno});

    self.allocator = allocator;
    self.L = L;

    c.lua_getglobal(self.L, "wf__ipc_command_callback");
    self.command_callback_ref = Lua.ref(self.L);

    try self.socket_server.init(allocator, socket_path, self);
}

pub fn deinit(self: *This) !void {
    try self.socket_server.deinit();

    Lua.unref(self.L, self.command_callback_ref);
}

pub fn reset(self: *This) void {
    self.socket_server.reset();
}
