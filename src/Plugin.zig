const build_options = @import("build_options");
const std = @import("std");
const c = @import("c.zig");
const Lua = @import("Lua.zig");
const SignalDispatcher = @import("SignalDispatcher.zig");
const KeyMappings = @import("KeyMappings.zig");
const IpcServer = @import("IpcServer.zig");

const Allocator = std.mem.Allocator;
const This = @This();

/// Static memory for single plugin instance.
var plugin_: This = undefined;
/// Get the plugin instance.
pub fn getPlugin() *This {
    return &plugin_;
}

pub fn getPluginSignalDispatcher() *SignalDispatcher {
    return &getPlugin().signal_dispatcher;
}
pub fn getPluginKeyMappings() *KeyMappings {
    return &getPlugin().key_mappings;
}

/// Root allocator used for the lifetime of the plugin.
allocator: *Allocator,

/// The lua state handle.
L: ?*c.lua_State,

signal_dispatcher: SignalDispatcher,
key_mappings: KeyMappings,
ipc_server: IpcServer,


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

    // Prepare the dispatcher state.
    try self.signal_dispatcher.init(self.allocator, self.L.?);
    // Prepare the mappings state.
    try self.key_mappings.init(self.allocator, self.L.?);

    // Run the init file.
    const init_file = try getInitFile(&arena.allocator);
    std.log.info("Running init file from: {s}", .{init_file});
    try Lua.doFile(L, init_file);

    std.log.info("Done running init.", .{});

    try self.ipc_server.init(self.allocator, self.L.?);
}

/// Plugin cleanup.
pub fn fini(self: *This) void {
    self.ipc_server.deinit();
    self.key_mappings.deinit();
    self.signal_dispatcher.deinit();

    c.lua_close(self.L);

    std.log.info("Goodbye.", .{});
}
