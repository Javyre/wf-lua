const std = @import("std");
const c = @import("c.zig");
const getPluginSignalDispatcher =
    @import("Plugin.zig").getPluginSignalDispatcher;

const Allocator = std.mem.Allocator;
const This = @This();

// { emitter: { signal-name: connection } }
const ObjectConnections = std.StringHashMap(*c.wf_SignalConnection);
const ActiveConnectionsMap = std.AutoHashMap(*c_void, ObjectConnections);

allocator: *Allocator,
L: *c.lua_State,

/// This callback is used for most C -> lua communication.
event_callback: c.wflua_EventCallback,

/// Map of active signal connections grouped by wayfire object.
/// { emitter: { signal-name: connection, ... }, ... }
/// All stored memory should be in our root allocator.
active_connections: ActiveConnectionsMap,

fn lifetimeCB(emitter: ?*c_void, data: ?*c_void) callconv(.C) void {
    const self = getPluginSignalDispatcher();

    std.log.debug("Object died: {x}", .{emitter.?});
    self.event_callback.?(
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
    const self = getPluginSignalDispatcher();
    const signal = @ptrCast([*:0]const u8, signal_);
    std.log.debug("Object {x} emitted {s}", .{ object.?, signal });
    self.event_callback.?(
        object,
        .WFLUA_EVENT_TYPE_SIGNAL,
        signal,
        sig_data,
    );
}

/// Register the lua event callback.
export fn wflua_register_event_callback(callback: c.wflua_EventCallback) void {
    const self = getPluginSignalDispatcher();

    std.debug.assert(self.event_callback == null);
    self.event_callback = callback;
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
    const self = getPluginSignalDispatcher();

    var object_conns = mk_oc: {
        const gop =
            self.active_connections.getOrPut(object) catch unreachable;
        if (!gop.found_existing) {
            gop.value_ptr.* = ObjectConnections.init(self.allocator);
        }
        break :mk_oc gop.value_ptr;
    };

    const owned_signal =
        self.allocator.dupeZ(u8, std.mem.span(signal)) catch unreachable;
    errdefer self.allocator.free(owned_signal);

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
        self.allocator.free(kv.key);
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

    const self = getPluginSignalDispatcher();

    var object_conns = self.active_connections.get(object) orelse {
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

    self.allocator.free(sig_entry.key);
    c.wf_destroy_signal_connection(sig_entry.value);

    if (object_conns.count() == 0) {
        _ = self.active_connections.remove(object);
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
    const self = getPluginSignalDispatcher();

    const ac = &self.active_connections;
    var object_conns_entry = ac.fetchRemove(object) orelse {
        std.log.err(
            "Unsubscribed from non-subscribed-to object! {x}",
            .{object},
        );
        return;
    };

    self.deinitObjectConnections(&object_conns_entry.value);
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

pub fn init(self: *This, allocator: *Allocator, L: *c.lua_State) !void {
    self.L = L;
    self.allocator = allocator;

    self.active_connections = ActiveConnectionsMap.init(self.allocator);
    errdefer self.deinitActiveConnections();
}

pub fn deinit(self: *This) void {
    self.deinitActiveConnections();
}
