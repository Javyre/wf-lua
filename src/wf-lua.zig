const std = @import("std");
const Plugin = @import("Plugin.zig");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const scope_prefix = if (scope == .default)
        ""
    else
        "(" ++ @tagName(scope) ++ ")";

    const color = switch (level) {
        .emerg, .alert, .crit, .err => "\x1B[31m", // red
        .warn => "\x1B[33m", // yellow
        .notice, .info, .debug => "",
    };

    const prefix = "[\x1B[1m" ++ color ++ @tagName(level) ++ "\x1B[0m]" ++
        scope_prefix ++ " ";

    // Print the message to stderr, silently ignoring any errors
    const held = std.debug.getStderrMutex().acquire();
    defer held.release();
    const stderr = std.io.getStdErr().writer();
    nosuspend stderr.print(prefix ++ format ++ "\n", args) catch return;
}

// Make sure the plugin is loaded once per wayfire session and not once per
// output.
var singleton_plugin_ref: u16 = 0;

export fn plugin_init() ?*c_void {
    singleton_plugin_ref += 1;
    if (singleton_plugin_ref > 1)
        return null;

    var plugin = Plugin.getPlugin();

    plugin.init(&gpa.allocator) catch |err| {
        std.log.err("Failed to initialize the plugin: {any}", .{err});
        if (@errorReturnTrace()) |trace|
            std.debug.dumpStackTrace(trace.*);
        return null;
    };

    return @ptrCast(*c_void, @alignCast(@alignOf(*c_void), plugin));
}

export fn plugin_fini(raw_plugin: ?*c_void) void {
    std.debug.assert(singleton_plugin_ref > 0);
    singleton_plugin_ref -= 1;
    if (singleton_plugin_ref > 0)
        return;

    if (raw_plugin == null)
        return;

    const plugin = @ptrCast(*Plugin, @alignCast(
        @alignOf(*Plugin),
        raw_plugin,
    ));

    plugin.fini();
    if (gpa.deinit())
        std.log.err("Main allocator detected leaks.", .{});
}
