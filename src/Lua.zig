const std = @import("std");
const c = @import("c.zig");

const LuaState = ?*c.lua_State;

const LuaError = error{
    LoadStringFailed,
    RunStringFailed,
    LoadFileFailed,
    RunFileFailed,
};

pub fn doString(L: LuaState, chunk: [:0]const u8) LuaError!void {
    if (c.luaL_loadstring(L, chunk) != 0) {
        std.log.err(
            "Failed to load string: {s}",
            .{c.lua_tolstring(L, -1, null)},
        );
        return LuaError.LoadStringFailed;
    }

    if (c.lua_pcall(L, 0, c.LUA_MULTRET, 0) != 0) {
        std.log.err(
            "Failed to run string: {s}",
            .{c.lua_tolstring(L, -1, null)},
        );
        return LuaError.RunStringFailed;
    }
}

pub fn doFile(L: LuaState, file: [:0]const u8) LuaError!void {
    if (c.luaL_loadfile(L, file) != 0) {
        std.log.err(
            "Failed to load file: {s}",
            .{c.lua_tolstring(L, -1, null)},
        );
        return LuaError.LoadFileFailed;
    }

    if (c.lua_pcall(L, 0, c.LUA_MULTRET, 0) != 0) {
        std.log.err(
            "Failed to run file: {s}",
            .{c.lua_tolstring(L, -1, null)},
        );
        return LuaError.RunFileFailed;
    }
}
