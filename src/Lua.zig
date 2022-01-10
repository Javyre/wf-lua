const std = @import("std");
const c = @import("c.zig");

const LuaState = ?*c.lua_State;

const LuaError = error{
    LoadStringFailed,
    RunStringFailed,
    LoadFileFailed,
    RunFileFailed,
    PCallFailed,
};

pub fn tostring(L: LuaState, index: c_int) [:0]const u8 {
    var len: usize = undefined;
    const cstr = c.lua_tolstring(L, index, &len);
    return cstr[0..len:0];
}

pub const Ref = struct { ref: c_int };

pub fn ref(L: LuaState) Ref {
    return .{ .ref = c.luaL_ref(L, c.LUA_REGISTRYINDEX) };
}
pub fn unref(L: LuaState, ref_: Ref) void {
    c.luaL_unref(L, c.LUA_REGISTRYINDEX, ref_.ref);
}
pub fn rawGetRef(L: LuaState, ref_: Ref) void {
    c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, ref_.ref);
}

pub fn pcall(L: LuaState, opts: struct {
    nargs: c_int,
    nresults: c_int,
    errfunc: c_int = 0,
}) LuaError!void {
    if (c.lua_pcall(L, opts.nargs, opts.nresults, opts.errfunc) != 0) {
        std.log.err(
            "pcall failed: {s}",
            .{tostring(L, -1)},
        );
        c.lua_pop(L, 1);
        return LuaError.PCallFailed;
    }
}

pub fn doString(L: LuaState, chunk: [:0]const u8) LuaError!void {
    if (c.luaL_loadstring(L, chunk) != 0) {
        std.log.err(
            "Failed to load string: {s}",
            .{tostring(L, -1)},
        );
        c.lua_pop(L, 1);
        return LuaError.LoadStringFailed;
    }

    if (c.lua_pcall(L, 0, c.LUA_MULTRET, 0) != 0) {
        std.log.err(
            "Failed to run string: {s}",
            .{tostring(L, -1)},
        );
        c.lua_pop(L, 1);
        return LuaError.RunStringFailed;
    }
}

pub fn doFile(L: LuaState, file: [:0]const u8) LuaError!void {
    if (c.luaL_loadfile(L, file) != 0) {
        std.log.err(
            "Failed to load file: {s}",
            .{tostring(L, -1)},
        );
        c.lua_pop(L, 1);
        return LuaError.LoadFileFailed;
    }

    if (c.lua_pcall(L, 0, c.LUA_MULTRET, 0) != 0) {
        std.log.err(
            "Failed to run file: {s}",
            .{tostring(L, -1)},
        );
        c.lua_pop(L, 1);
        return LuaError.RunFileFailed;
    }
}
