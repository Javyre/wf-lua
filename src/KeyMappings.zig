const std = @import("std");
const c = @import("c.zig");
const Lua = @import("Lua.zig");

const getPluginKeyMappings = @import("Plugin.zig").getPluginKeyMappings;

const Allocator = std.mem.Allocator;

const _ = comptime std.debug.assert(c.WLR_MODIFIER_COUNT <= 8);
const ModifierMask = u8;

const This = @This();

// Taken from: wlr_keyboard.c
fn xkbModMaskToModifierMask(
    keyboard: *c.struct_wlr_keyboard,
    mod_mask: c.xkb_mod_mask_t,
) ModifierMask {
    var modifiers: ModifierMask = 0;

    var i: u5 = 0;
    while (i < c.WLR_MODIFIER_COUNT) : (i += 1) {
        const mod_at_index =
            @as(c.xkb_mod_mask_t, 1) << @intCast(u5, keyboard.mod_indexes[i]);

        if (keyboard.mod_indexes[i] != c.XKB_MOD_INVALID and
            (mod_mask & mod_at_index) != 0)
        {
            modifiers |= @intCast(
                ModifierMask,
                (@as(c.xkb_mod_mask_t, 1) << i),
            );
        }
    }

    return modifiers;
}

const Key = packed struct {
    keysym: c.xkb_keysym_t,
    modifiers: ModifierMask,

    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        const pretty = comptime std.mem.eql(u8, "p", fmt);
        if (fmt.len == 0 or pretty) {
            if (!pretty)
                try std.fmt.format(writer, "Key[", .{});

            if (self.modifiers & c.WLR_MODIFIER_SHIFT != 0)
                try std.fmt.format(writer, "S-", .{});
            if (self.modifiers & c.WLR_MODIFIER_CAPS != 0)
                try std.fmt.format(writer, "c-", .{});
            if (self.modifiers & c.WLR_MODIFIER_CTRL != 0)
                try std.fmt.format(writer, "C-", .{});
            if (self.modifiers & c.WLR_MODIFIER_ALT != 0)
                try std.fmt.format(writer, "M-", .{});
            if (self.modifiers & c.WLR_MODIFIER_MOD2 != 0)
                try std.fmt.format(writer, "M2-", .{});
            if (self.modifiers & c.WLR_MODIFIER_MOD3 != 0)
                try std.fmt.format(writer, "M3-", .{});
            if (self.modifiers & c.WLR_MODIFIER_LOGO != 0)
                try std.fmt.format(writer, "s-", .{});
            if (self.modifiers & c.WLR_MODIFIER_MOD5 != 0)
                try std.fmt.format(writer, "M5-", .{});

            if (self.keysym != ' ' and
                ((self.keysym >= 0x0020 and self.keysym <= 0x007e) or
                (self.keysym >= 0x00a0 and self.keysym <= 0x00ff)))
            {
                try std.fmt.format(writer, "{c}", .{
                    @intCast(u8, self.keysym),
                });
            } else {
                var buff: [128]u8 = undefined;
                const len = c.xkb_keysym_get_name(self.keysym, &buff, buff.len);
                try std.fmt.format(writer, "{s}", .{
                    buff[0..@intCast(usize, len)],
                });
            }

            if (!pretty)
                try std.fmt.format(writer, "]", .{});
        } else {
            @compileError("Unknown format character: '" ++ fmt ++ "'");
        }
    }
};

const KeysContext = struct {
    pub fn hash(self: @This(), keys: []const Key) u64 {
        var wh = std.hash.Wyhash.init(5);
        for (keys) |key| {
            wh.update(std.mem.asBytes(&key.keysym));
            wh.update(std.mem.asBytes(&key.modifiers));
        }
        return wh.final();
    }
    pub fn eql(self: @This(), a: []const Key, b: []const Key) bool {
        if (a.len != b.len) return false;
        for (a) |e, i|
            if (!std.meta.eql(e, b[i])) return false;
        return true;
    }
};

const Mappings = std.HashMap(
    []const Key,
    struct {
        // An entry is a "path" of keys that may either be a mapping, a prefix
        // to some other mapping, or both.
        //
        // If path_refs == 0 and mappings == null, it is safe to remove this
        // entry from the mappings table.

        mapping: ?struct {
            handler: Lua.Ref,
            pop_keys: u16,
        } = null,

        /// Amount of mappings using this entry as a prefix path.
        path_refs: u16 = 0,
    },
    KeysContext,
    std.hash_map.default_max_load_percentage,
);

allocator: *Allocator,
L: *c.lua_State,
mappings: Mappings,
keyboard_key_signal: *c.wf_SignalConnection,
pending_keys: std.ArrayList(Key),

fn mapKeys(L: ?*c.lua_State) callconv(.C) c_int {
    // 3 Parameters: keys, handler, ?pop_keys
    std.debug.assert(c.lua_gettop(L.?) == 3);

    const keys = Lua.tostring(L.?, 1);
    const handler = x: {
        c.lua_pushvalue(L.?, 2); // push copy
        break :x Lua.ref(L.?); // pop and ref
    };
    const pop_keys = x: {
        if (c.lua_isnil(L.?, 3)) {
            break :x null;
        } else {
            break :x @intCast(u16, c.lua_tointeger(L.?, 3));
        }
    };

    mapKeysImpl(keys, handler, pop_keys) catch |err| switch (err) {
        ParserError.InvalidModifier,
        ParserError.InvalidKeySymbol,
        ParserError.InvalidEmptyKeys,
        => {
            std.log.err("Error parsing keys: '{s}': {}", .{ keys, err });
        },
        else => unreachable,
    };

    return 0;
}

// TODO: remove entry when handler is null
fn mapKeysImpl(keys: []const u8, handler: Lua.Ref, pop_keys: ?u16) !void {
    const self = getPluginKeyMappings();

    const parsed_keys: []Key = try parseKeys(self.allocator, keys);
    std.debug.assert(parsed_keys.len > 0);

    std.log.debug("Keys: {any}", .{parsed_keys});

    {
        const gop = try self.mappings.getOrPut(parsed_keys);
        const new_mapping = .{
            .pop_keys = @intCast(u16, pop_keys orelse parsed_keys.len),
            .handler = handler,
        };
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .mapping = new_mapping };
        } else {
            if (gop.value_ptr.mapping) |old_mapping| {
                Lua.unref(self.L, old_mapping.handler);
            }
            gop.value_ptr.mapping = new_mapping;
        }
    }

    var key_path = parsed_keys;
    key_path.len -= 1;

    while (key_path.len > 0) : (key_path.len -= 1) {
        const gop = try self.mappings.getOrPut(key_path);
        if (gop.found_existing) {
            gop.value_ptr.path_refs += 1;
        } else {
            gop.key_ptr.* = try self.allocator.dupe(Key, key_path);
            gop.value_ptr.* = .{ .path_refs = 1 };
        }
    }
}

const ParserError = error{
    InvalidModifier,
    InvalidKeySymbol,
    InvalidEmptyKeys,
};

/// Parse a key sequence string into a sequence of `Key`s.
///
/// The string follows similar formatting to that of emacs.
/// Every key is separated by whitespace, and formatted as:
///
///     (Modifier-)*Key
///
/// Modifiers are:
///     S: Shift
///     M: Alt / Meta / Mod1
///     C: Ctrl
///     s: Super / Logo / Mod4
///     c: Caps
///
///     M1: Alt / Meta / Mod1
///     M2: Mod2
///     M3: Mod3
///     M4: Super / Logo / Mod4
///     M5: Mod5
///
/// Keys must be valid keysym names as defined in <xkbcommon-keysyms.h> or a
/// Latin-1 symbol. (utf8 strings are not handled)
///
/// Examples:
///     C-a    : Ctrl and a pressed at the same time.
///     C-S-a  : Ctrl, Shift and a pressed at the same time.
///     C-a b c: Ctrl and a pressed at the same time, then b pressed, then c
///     pressed.
///
fn parseKeys(allocator: *Allocator, keys: []const u8) ![]Key {
    var parsed_keys = std.ArrayList(Key).init(allocator);

    var rest = std.mem.trimRight(u8, keys, " \t");

    while (rest.len > 0) {
        rest = std.mem.trimLeft(u8, rest, " \t");
        if (rest.len == 0)
            break;

        try parsed_keys.append(try parseKey(&rest));
    }

    if (parsed_keys.items.len == 0)
        return ParserError.InvalidEmptyKeys;

    return parsed_keys.toOwnedSlice();
}

/// Parse a single key from a key sequence
fn parseKey(rest: *[]const u8) !Key {

    // Consume all modifiers.
    var modifiers: ModifierMask = 0;
    while (true) {
        modifiers |= parseModifier(rest) catch |err| switch (err) {
            error.InvalidModifier => break,
            else => return err,
        };
    }

    // Now we should have just the name / symbol of a keysym leftover before the
    // next whitespace or end of string.
    const next_whitespace =
        std.mem.indexOfAny(u8, rest.*, " \t") orelse rest.len;
    const keysym_name = rest.*[0..next_whitespace];
    rest.* = rest.*[next_whitespace..rest.*.len];

    // 1:1 keysyms for latin-1 characters.
    if (keysym_name.len == 1 and
        ((keysym_name[0] >= 0x0020 and keysym_name[0] <= 0x007e) or
        (keysym_name[0] >= 0x00a0 and keysym_name[0] <= 0x00ff)))
    {
        return Key{ .keysym = keysym_name[0], .modifiers = modifiers };
    } else {
        var buff: [256]u8 = undefined;
        var buff_alloc = std.heap.FixedBufferAllocator.init(&buff);
        const keysym_name_c =
            buff_alloc.allocator.dupeZ(u8, keysym_name) catch unreachable;

        const keysym = c.xkb_keysym_from_name(
            keysym_name_c,
            c.enum_xkb_keysym_flags.XKB_KEYSYM_NO_FLAGS,
        );

        if (keysym == c.XKB_KEY_NoSymbol) {
            std.log.err("Invalid KeySym name: '{s}'", .{keysym_name});
            return error.InvalidKeySymbol;
        }

        return Key{ .keysym = keysym, .modifiers = modifiers };
    }
}

/// Consume a modifier followed by a '-'
fn parseModifier(rest: *[]const u8) !ModifierMask {
    if (rest.*.len >= 2 and rest.*[1] == '-') {
        const modifier = x: {
            switch (rest.*[0]) {
                'S' => break :x c.WLR_MODIFIER_SHIFT,
                'c' => break :x c.WLR_MODIFIER_CAPS,
                'C' => break :x c.WLR_MODIFIER_CTRL,
                'M' => break :x c.WLR_MODIFIER_ALT,
                's' => break :x c.WLR_MODIFIER_LOGO,
                else => return error.InvalidModifier,
            }
        };
        rest.* = rest.*[2..rest.len];
        return @intCast(ModifierMask, modifier);
    }
    if (rest.*.len >= 3 and rest.*[0] == 'M' and rest.*[2] == '-') {
        const modifier = x: {
            switch (rest.*[1]) {
                '1' => break :x c.WLR_MODIFIER_ALT,
                '2' => break :x c.WLR_MODIFIER_MOD2,
                '3' => break :x c.WLR_MODIFIER_MOD3,
                '4' => break :x c.WLR_MODIFIER_LOGO,
                '5' => break :x c.WLR_MODIFIER_MOD5,
                else => return error.InvalidModifier,
            }
        };
        rest.* = rest.*[3..rest.len];
        return @intCast(ModifierMask, modifier);
    }
    return error.InvalidModifier;
}

// TODO: write tests for this parser once zig build allows us to run our tests
//       without crashing due to undefined wayfire symbols we aren't using.
// test "parseKey" {
//     var key = std.mem.span("M-C-a");

//     try std.testing.expectEqual(Key{
//         .keysym = 'a',
//         .modifiers = c.WLR_MODIFIER_ALT | c.WLR_MODIFIER_CTRL,
//     }, try parseKey(&key));
// }

fn handleKeyboardKeyCB(
    sig_data: ?*c_void,
    data1: ?*c_void,
    _data2: ?*c_void,
) callconv(.C) void {
    const self = @ptrCast(
        *@This(),
        @alignCast(@alignOf(@This()), data1),
    );

    const event = c.wf_get_signaled_keyboard_key_event(sig_data).*;

    if (event.state !=
        c.enum_wl_keyboard_key_state.WL_KEYBOARD_KEY_STATE_PRESSED)
        return;

    const seat = c.wf_Core_get_current_seat(c.wf_get_core());
    const keyboard: *c.struct_wlr_keyboard = c.wlr_seat_get_keyboard(seat);

    var keysyms: []const c.xkb_keysym_t = undefined;
    keysyms.len = @intCast(usize, c.xkb_state_key_get_syms(
        keyboard.xkb_state,
        event.keycode + 8,
        @ptrCast([*c][*c]const c.xkb_keysym_t, &keysyms.ptr),
    ));

    for (keysyms) |ks| {
        switch (ks) {
            // Skip modifier keys.
            c.XKB_KEY_Shift_L...c.XKB_KEY_Hyper_R => continue,
            else => {},
        }

        // Directly using this modifier mask would give us 'S-L' for shift +
        // capital L, but the user might have mapped just 'L' for the keysym. We
        // need to query the "consumed modifiers" and match a mapping without
        // them. (See the section on "consumed-modifiers" in xkbcommon.h)
        const modifiers: ModifierMask = @intCast(
            ModifierMask,
            c.wlr_keyboard_get_modifiers(keyboard),
        );

        const consumed_mods: ModifierMask = xkbModMaskToModifierMask(
            keyboard,
            c.xkb_state_key_get_consumed_mods(
                keyboard.xkb_state,
                event.keycode + 8,
            ),
        );

        const key = Key{
            .keysym = ks,
            .modifiers = modifiers & ~consumed_mods,
        };

        self.pending_keys.append(key) catch unreachable;

        if (self.mappings.get(self.pending_keys.items)) |entry| {
            if (entry.mapping) |mapping|
                runMappingHandler(self, mapping);

            // NOTE: It'd be nice to have more options for
            // input_event_processing_mode_t or maybe make it a bitflag.
            // see: https://github.com/WayfireWM/wayfire/issues/1320
            c.wf_set_signaled_keyboard_key_mode(
                sig_data,
                c.wf_InputEventProcessingMode
                    .WF_INPUT_EVENT_PROC_MODE_NO_CLIENT,
            );
        } else {
            // Try again with just the last keysym entered.

            self.pending_keys.clearRetainingCapacity();
            self.pending_keys.append(key) catch unreachable;

            if (self.mappings.get(self.pending_keys.items)) |entry| {
                if (entry.mapping) |mapping|
                    runMappingHandler(self, mapping);

                c.wf_set_signaled_keyboard_key_mode(
                    sig_data,
                    c.wf_InputEventProcessingMode
                        .WF_INPUT_EVENT_PROC_MODE_NO_CLIENT,
                );
            } else {
                self.pending_keys.clearRetainingCapacity();
            }
        }
        std.log.debug("{any}, {}", .{ self.pending_keys.items, key });
    }
}

fn runMappingHandler(self: *This, mapping: anytype) void {
    Lua.rawGetRef(self.L, mapping.handler);
    Lua.pcall(
        self.L,
        .{ .nargs = 0, .nresults = 0 },
    ) catch |err| switch (err) {
        Lua.LuaError.PCallFailed => {
            std.log.err(
                "Failed to run keymapping handler lua function.",
                .{},
            );
        },
        else => unreachable,
    };

    const pending_len = self.pending_keys.items.len;
    self.pending_keys.resize(
        pending_len - std.math.min(mapping.pop_keys, pending_len),
    ) catch unreachable;
}

pub fn init(self: *@This(), allocator: *Allocator, L: *c.lua_State) !void {
    self.allocator = allocator;
    self.L = L;

    c.lua_pushcfunction(L, mapKeys);
    c.lua_setglobal(L, "wf__map_keys");

    self.mappings = Mappings.init(allocator);
    errdefer {
        // NOTE: not deallocating any elements since this should stay empty in
        // this function.
        self.mappings.deinit();
        self.mappings = undefined;
    }

    self.pending_keys = try std.ArrayList(Key).initCapacity(allocator, 10);
    errdefer {
        self.pending_keys.deinit();
        self.pending_keys = undefined;
    }

    self.keyboard_key_signal = c.wf_create_signal_connection(
        handleKeyboardKeyCB,
        @ptrCast(*c_void, self),
        null,
    ).?;
    c.wf_signal_subscribe(
        @ptrCast(*c_void, c.wf_get_core().?),
        "keyboard_key",
        self.keyboard_key_signal,
    );
    errdefer {
        c.wf_destroy_signal_connection(self.keyboard_key_signal);
        self.keyboard_key_signal = undefined;
    }
}

pub fn deinit(self: *@This()) void {
    c.wf_destroy_signal_connection(self.keyboard_key_signal);
    self.keyboard_key_signal = undefined;

    self.pending_keys.deinit();
    self.pending_keys = undefined;

    {
        var it = self.mappings.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.mapping) |mapping|
                Lua.unref(self.L, mapping.handler);

            self.allocator.free(entry.key_ptr.*);
        }
        self.mappings.deinit();
        self.mappings = undefined;
    }
}
