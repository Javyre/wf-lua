const build_options = @import("build_options");
const std = @import("std");
const c = @import("c.zig");
const Lua = @import("Lua.zig");
const IpcServer = @import("IpcServer.zig");

const Allocator = std.mem.Allocator;
const This = @This();

/// Static memory for single plugin instance.
var plugin_: This = undefined;
/// Get the plugin instance.
pub fn getPlugin() *This {
    return &plugin_;
}

// { emitter: { signal-name: connection } }
const ObjectConnections = std.StringHashMap(*c.wf_SignalConnection);
const ActiveConnectionsMap = std.AutoHashMap(*c_void, ObjectConnections);

/// Root allocator used for the lifetime of the plugin.
allocator: *Allocator,

/// The lua state handle.
L: ?*c.lua_State,

/// This callback is used for most C -> lua communication.
event_callback: c.wflua_EventCallback,

/// Map of active signal connections grouped by wayfire object.
/// { emitter: { signal-name: connection, ... }, ... }
/// All stored memory should be in our root allocator.
active_connections: ActiveConnectionsMap,

ipc_server: IpcServer,

fn lifetimeCB(emitter: ?*c_void, data: ?*c_void) callconv(.C) void {
    const plugin = getPlugin();

    std.log.debug("Object died: {x}", .{emitter.?});
    plugin.event_callback.?(
        emitter.?,
        .WFLUA_EVENT_TYPE_EMITTER_DESTROYED,
        null,
        null,
    );
}

fn signalEventCB(
    sig_data: ?*c_void,
    object: ?*c_void,
    signal_: ?*c_void,
) callconv(.C) void {
    const plugin = getPlugin();
    const signal = @ptrCast([*:0]const u8, signal_);
    std.log.debug("Object {x} emitted {s}", .{ object.?, signal });
    plugin.event_callback.?(
        object,
        .WFLUA_EVENT_TYPE_SIGNAL,
        signal,
        sig_data,
    );
}

/// Exposed standard zig logger to lua.
export fn wflua_log(lvl: c.wflua_LogLvl, msg: [*:0]const u8) void {
    const scope = std.log.scoped(.lua);
    switch (lvl) {
        .WFLUA_LOGLVL_DEBUG => scope.debug("{s}", .{msg}),
        .WFLUA_LOGLVL_WARN => scope.warn("{s}", .{msg}),
        .WFLUA_LOGLVL_ERR => scope.err("{s}", .{msg}),
        _ => unreachable,
    }
}

/// Register the lua event callback.
export fn wflua_register_event_callback(callback: c.wflua_EventCallback) void {
    const plugin = getPlugin();

    std.debug.assert(plugin.event_callback == null);
    plugin.event_callback = callback;
}
/// Start listening for an object being destroyed.
export fn wflua_lifetime_subscribe(object: *c_void) void {
    std.log.debug("Watching object lifetime: {x}", .{object});
    c.wf_lifetime_subscribe(object, lifetimeCB, null);
}
/// Stop listening for an object being destroyed.
export fn wflua_lifetime_unsubscribe(object: *c_void) void {
    std.log.debug("Stopped watching object lifetime: {x}", .{object});
    c.wf_lifetime_unsubscribe(object, lifetimeCB);
}

/// Start listening for an object's signal.
export fn wflua_signal_subscribe(object: *c_void, signal: [*:0]const u8) void {
    const plugin = getPlugin();

    var object_conns = mk_oc: {
        const gop =
            plugin.active_connections.getOrPut(object) catch unreachable;
        if (!gop.found_existing) {
            gop.value_ptr.* = ObjectConnections.init(plugin.allocator);
        }
        break :mk_oc gop.value_ptr;
    };

    const owned_signal =
        plugin.allocator.dupeZ(u8, std.mem.span(signal)) catch unreachable;
    errdefer plugin.allocator.free(owned_signal);

    const connection = c.wf_create_signal_connection(
        signalEventCB,
        object,
        @ptrCast(*c_void, owned_signal),
    );
    errdefer c.wf_destroy_signal_connection(connection);

    if (object_conns.fetchPut(
        owned_signal,
        connection.?,
    ) catch unreachable) |kv| {
        std.log.err(
            "Subscribed to signal more than once on the same object! {x}",
            .{object},
        );
        plugin.allocator.free(kv.key);
        c.wf_destroy_signal_connection(kv.value);
    }

    c.wf_signal_subscribe(object, signal, connection);

    std.log.debug(
        "Watching object {x} for signal: {s}",
        .{ object, signal },
    );
}

/// Stop listening for an object's signal.
export fn wflua_signal_unsubscribe(
    object: *c_void,
    signal: [*:0]const u8,
) void {
    // Just destroy the appropriate signal connection object and the signal will
    // be disconnected.

    const plugin = getPlugin();

    var object_conns = plugin.active_connections.get(object) orelse {
        std.log.err(
            "Unsubscribed from non-subscribed-to object! {x}",
            .{object},
        );
        return;
    };

    const sig_entry = object_conns.fetchRemove(std.mem.span(signal)) orelse {
        std.log.err(
            "Unsubscribed from non-subscribed-to signal! {s} on {x}",
            .{ signal, object },
        );
        return;
    };

    plugin.allocator.free(sig_entry.key);
    c.wf_destroy_signal_connection(sig_entry.value);

    if (object_conns.count() == 0) {
        _ = plugin.active_connections.remove(object);
        object_conns.deinit();
    }

    std.log.debug(
        "Stopped watching object {x} for signal: {s}",
        .{ object, signal },
    );
}

/// Stop listening for any of an object's signals.
export fn wflua_signal_unsubscribe_all(object: *c_void) void {
    // Just free all the signal connections of an object and the signals will be
    // disconnected.
    const plugin = getPlugin();

    const ac = &plugin.active_connections;
    var object_conns_entry = ac.fetchRemove(object) orelse {
        std.log.err(
            "Unsubscribed from non-subscribed-to object! {x}",
            .{object},
        );
        return;
    };

    plugin.deinitObjectConnections(&object_conns_entry.value);
}

/// Find the lua init file using the following precedence:
/// $WFLUA_INIT
/// > $XDG_CONFIG_HOME/wayfire/init.lua
/// > $HOME/.config/wayfire/init.lua
/// Only env vars are checked for existence (not files).
fn getInitFile(allocator: *Allocator) ![:0]const u8 {
    const path = std.fs.path;

    if (std.os.getenv("WFLUA_INIT")) |file| {
        return try allocator.dupeZ(u8, file);
    } else if (std.os.getenv("XDG_CONFIG_HOME")) |file| {
        return try path.joinZ(allocator, &[_][]const u8{
            file,
            "wayfire/init.lua",
        });
    } else if (std.os.getenv("HOME")) |file| {
        return try path.joinZ(allocator, &[_][]const u8{
            file,
            ".config/wayfire/init.lua",
        });
    }

    std.log.err("$HOME is unset. Cannot find init file!", .{});
    return error.FileNotFound;
}

/// Recursively deinit an ObjectConnections map.
fn deinitObjectConnections(self: *This, obj_entry: *ObjectConnections) void {
    var iter_sigs = obj_entry.iterator();
    while (iter_sigs.next()) |kv| {
        self.allocator.free(kv.key_ptr.*);
        c.wf_destroy_signal_connection(kv.value_ptr.*);
    }
    obj_entry.deinit();
}

/// Recursively deinit the active_connections map.
fn deinitActiveConnections(self: *This) void {
    var iter_objs = self.active_connections.valueIterator();
    while (iter_objs.next()) |obj_conns| {
        self.deinitObjectConnections(obj_conns);
    }
    self.active_connections.deinit();
}

/// Plugin entry point.
pub fn init(self: *This, allocator: *Allocator) !void {
    // NOTE: SIGPIPE needs to be handled locally. So we need to disable the
    // signal and handle the errors from write() and read().
    std.os.sigaction(std.os.SIGPIPE, &.{
        .handler = .{ .sigaction = std.os.SIG_IGN },
        .mask = std.os.empty_sigset,
        .flags = 0,
    }, null);

    self.allocator = allocator;

    self.active_connections = ActiveConnectionsMap.init(self.allocator);
    errdefer self.deinitActiveConnections();

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();

    std.debug.print("\n\nHello, wayfireee!!\n\n\n", .{});

    self.L = c.luaL_newstate();
    errdefer {
        c.lua_close(self.L);
        self.L = null;
    }
    const L = self.L;

    c.luaL_openlibs(L);

    // Add the wf-lua runtime dir to the path.
    try Lua.doString(L, "package.path = package.path .. ';" ++
        build_options.LUA_RUNTIME ++ "/?.lua'");

    // Run the init file.
    const init_file = try getInitFile(&arena.allocator);
    std.log.info("Running init file from: {s}", .{init_file});
    try Lua.doFile(L, init_file);

    std.log.info("Done running init.", .{});

    try self.ipc_server.init(self.allocator, self.L.?);
}

/// Plugin cleanup.
pub fn fini(self: *This) void {
    c.lua_close(self.L);

    self.deinitActiveConnections();

    self.ipc_server.deinit();

    std.log.info("Goodbye.", .{});
}
