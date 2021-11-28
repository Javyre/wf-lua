--- High-level lua bindings to wayfire's API.
--
-- @author Javier A. Pollak
-- @license GPL-v3
-- @alias Wf
-- @module wf
--
require 'wf.wf_h' -- Load the wf.h c header.

local ffi = require 'ffi'
local util = require 'wf.util'
local Log = require 'wf.log'

-- FFI Logic

local Raw = {lifetime_callbacks = {}, signal_callbacks = {}}

local function object_id(emitter_ptr)
    return tostring(ffi.cast('void *', emitter_ptr))
end

-- There is a cap on the amount of allowed lua-created C callbacks so we
-- reuse this same one for all signals.
Raw.event_callback = ffi.cast("wflua_EventCallback",
                              function(emitter, event_type, signal, signal_data)
    local success, err = pcall(function()
        if event_type == ffi.C.WFLUA_EVENT_TYPE_SIGNAL then
            -- NOTE: The address of the emitter is assumed to be constant for any
            -- given emitter.
            -- A signal was emitted to the signal_connection.
            Log.debug('SIGNAL EVENT: on ' .. object_id(emitter) .. ' : "' ..
                          ffi.string(signal) .. '"')

            local emitter_signals = Raw.signal_callbacks[object_id(emitter)]
                                        .signals
            emitter_signals[ffi.string(signal)]:call(emitter, signal_data)

        elseif event_type == ffi.C.WFLUA_EVENT_TYPE_EMITTER_DESTROYED then
            Log.debug('EMITTER DIED: ', object_id(emitter))

            local emitter_id = object_id(emitter)
            Raw.lifetime_callbacks[emitter_id]:call(emitter)
            Raw.lifetime_callbacks[emitter_id] = nil
        end
    end)

    if not success then Log.err('Error in lua event-callback:\n', err) end
end)

function Raw:subscribe_lifetime(emitter_ptr, handler)
    local emitter = object_id(emitter_ptr)

    Log.debug('subscribing to ' .. emitter .. ' lifetime')

    if not self.lifetime_callbacks[emitter] then
        ffi.C.wflua_lifetime_subscribe(emitter_ptr)
        self.lifetime_callbacks[emitter] = util.Hook {handler}
    else
        self.lifetime_callbacks[emitter]:hook(handler)
    end
    return handler
end

function Raw:unsubscribe_lifetime(emitter_ptr, handler)
    local emitter = object_id(emitter_ptr)

    self.lifetime_callbacks[emitter]:unhook(handler)

    if self.lifetime_callbacks[emitter]:is_empty() then
        ffi.C.wflua_lifetime_unsubscribe(emitter_ptr)
        self.lifetime_callbacks[emitter] = nil
    end
end

function Raw:subscribe(emitter_ptr, signal, handler, opts)
    local lifetime_cleanup = true
    if opts ~= nil and type(opts) == 'table' then
        if opts.lifetime_cleanup == false then lifetime_cleanup = false end
    end

    local emitter = object_id(emitter_ptr)

    Log.debug('subscribing to ' .. emitter .. ' ' .. signal)

    if not self.signal_callbacks[emitter] then
        local lifetime_handler = false
        if lifetime_cleanup then
            -- Clean up when the C++ emitter object dies.
            lifetime_handler = self:subscribe_lifetime(emitter_ptr, function()
                self.signal_callbacks[emitter] = nil
                ffi.C.wflua_signal_unsubscribe_all(emitter_ptr)
            end)
        end
        self.signal_callbacks[emitter] = {
            lifetime_handler = lifetime_cleanup,
            signals = {}
        }
    end

    local emitter_cbs = self.signal_callbacks[emitter].signals
    if not emitter_cbs[signal] then
        ffi.C.wflua_signal_subscribe(emitter_ptr, signal)

        emitter_cbs[signal] = util.Hook {handler}
    else
        emitter_cbs[signal]:hook(handler)
    end
    return handler
end

function Raw:unsubscribe(emitter_ptr, signal, handler)
    local emitter = object_id(emitter_ptr)

    local emitter_entry = self.signal_callbacks[emitter]
    local emitter_cbs = emitter_entry.signals
    emitter_cbs[signal]:unhook(handler)

    if emitter_cbs[signal]:is_empty() then
        ffi.C.wflua_signal_unsubscribe(emitter_ptr, signal)

        emitter_cbs[signal] = nil

        -- No signals being listened for for this emitter
        if not next(emitter_cbs) then
            if emitter_entry.lifetime_handler ~= false then
                -- No longer need to listen for emitter destroyed
                self.unsubscribe_lifetime(emitter_ptr,
                                          emitter_entry.lifetime_handler)
            end
            self.signal_callbacks[emitter] = nil
        end
    end
end

ffi.C.wflua_register_event_callback(Raw.event_callback)

--- Set the value of an option.
-- The option must already by registered by Wayfire.
-- @local
function Raw.set_option(sect, opt, val)
    local val_str = string.format('%s', val)

    local r = ffi.C.wf_set_option_str(sect, opt, val_str)

    if r == ffi.C.WF_INVALID_OPTION_VALUE then
        error(string.format('`%s` is not a valid value for %s/%s', val, sect,
                            opt))
    elseif r == ffi.C.WF_INVALID_OPTION_SECTION then
        error(string.format('`%s` is not a valid section name', sect))
    elseif r == ffi.C.WF_INVALID_OPTION then
        error(string.format('`%s` is not a valid option in `%s`', opt, sect))
    end
end

do
    local function view_signal(sig_data)
        return {view = ffi.C.wf_get_signaled_view(sig_data)}
    end

    local function output_signal(sig_data)
        return {output = ffi.C.wf_get_signaled_output(sig_data)}
    end

    Raw.signal_data_converters = {
        core = {
            ['view-created'] = view_signal,
            ['view-system-bell'] = view_signal,
            ['output-gain-focus'] = output_signal,
            ['output-stack-order-changed'] = output_signal
        },
        ['output-layout'] = {
            ['output-added'] = output_signal,
            ['pre-remove'] = output_signal,
            ['output-removed'] = output_signal
        },
        output = {
            ['view-mapped'] = view_signal,
            ['view-pre-unmapped'] = view_signal,
            ['view-unmapped'] = view_signal,
            ['view-set-sticky'] = view_signal,
            ['view-decoration-state-updated'] = view_signal,
            ['view-attached'] = view_signal,
            ['view-layer-attached'] = view_signal,
            ['view-detached'] = view_signal,
            ['view-layer-detached'] = view_signal,
            ['view-disappeared'] = view_signal,
            ['view-focused'] = view_signal,
            ['view-move-request'] = view_signal,
            ['gain-focus'] = output_signal,
            ['start-rendering'] = output_signal,
            ['stack-order-changed'] = output_signal
        },
        view = {
            ['mapped'] = view_signal,
            ['pre-unmapped'] = view_signal,
            ['unmapped'] = view_signal,
            ['set-sticky'] = view_signal,
            ['title-changed'] = view_signal,
            ['app-id-changed'] = view_signal,
            ['decoration-state-updated'] = view_signal,
            ['ping-timeout'] = view_signal,
            ['set-output'] = output_signal
        }
    }
end

function Raw:convert_signal_data(type, signal, raw_data)
    local data_converter = self.signal_data_converters[type][signal]

    -- Without converting this raw_data pointer, it's essentially useless in
    -- lua-land.
    if not data_converter then return nil end

    return data_converter(raw_data)
end

---Functions
-- @section

-- Public API
local Wf = {}

--- Set option values in a given section.
--
-- The section and option names must already be registered in wayfire by it or
-- some plugin.
--
-- @usage
-- --The arguments are passed in the form: 
-- set { 'section', option = value, ...}
--
-- -- The wayfire.ini equivalent:
-- --
-- -- [section]
-- -- option = value
-- -- ...
-- @tparam {section,option=value,...} args
-- @within Functions
function Wf.set(args)
    if type(args) ~= 'table' then
        error([[The arguments to set should be passed in the form: 
                set { 'section', option = value, option2 = value, ... }]], 2)
    end

    local sect = args[1]
    for opt, val in pairs(args) do
        if opt ~= 1 then Raw.set_option(sect, opt, val) end
    end
end

---A rectangle.
-- @field x
-- @field y
-- @field width
-- @field height
-- @type Geometry
ffi.metatype("wf_Geometry", {
    __tostring = function(self)
        return string.format("(%d,%d %dx%d)", self.x, self.y, self.width,
                             self.height)
    end
})

---Width-height dimensions.
-- @field width
-- @field height
-- @type Dimensions
ffi.metatype("wf_Dimensions", {
    __tostring = function(self)
        return string.format("(%dx%d)", self.width, self.height)
    end
})

---Floating point coordinates.
-- @field x
-- @field y
-- @type Pointf
ffi.metatype("wf_Pointf", {
    __tostring = function(self)
        return string.format("(%f,%f)", self.x, self.y)
    end
})

--- Lua-local data attached to wayfire objects.
-- @type ObjectData
-- @local
local ObjectData = {
    data = {},

    --- Store some data.
    --
    -- Delete some stored data by setting it to `nil`.
    -- @local
    set = function(self, object_ptr, key, value, opts)
        local lifetime_cleanup = true
        if opts ~= nil and type(opts) == 'table' then
            if opts.lifetime_cleanup == false then
                lifetime_cleanup = false
            end
        end

        local object = object_id(object_ptr)
        if not self.data[object] then
            if value == nil then return end

            self.data[object] = {[key] = value}
            if lifetime_cleanup then
                Raw:subscribe_lifetime(object_ptr,
                                       function()
                    self.data[object] = nil
                end)
            end
        else
            self.data[object][key] = value
        end
    end,

    --- Retrieve some stored data.
    -- @local
    get = function(self, object_ptr, key)
        return self.data[object_id(object_ptr)][key]
    end
}

do
    -- We don't need to actually call wayfire's get_core everytime since it should
    -- never change.
    local core = ffi.C.wf_get_core()
    function Wf.get_core() return core end
end

---The Wayfire compositor instance.
-- @usage local core = wf.get_core()
-- -- move the cursor to (100, 100)
-- core:warp_cursor({100, 100})
-- @type Core
ffi.metatype("wf_Core", {
    __tostring = function(self)
        return ffi.string(ffi.C.wf_Core_to_string(self))
    end,
    __index = {
        --- Set the cursor to the given name from the cursor theme.
        -- @tparam Core self the wayfire instance.
        -- @tparam string name the cursor name.
        set_cursor = function(self, name)
            ffi.C.wf_Core_set_cursor(self, name)
        end,

        --- Request to hide the cursor.
        --
        -- Increments the hide-cursor reference count and hides the cursor if
        -- it is not already hidden.
        -- @tparam Core self the wayfire instance.
        hide_cursor = function(self) ffi.C.wf_Core_hide_cursor(self) end,

        --- Request to unhide the cursor.
        --
        -- Decrement the hide-cursor reference count. If it goes to 0, then the
        -- cursor is actually unhidden.
        -- @tparam Core self the wayfire instance.
        unhide_cursor = function(self) ffi.C.wf_Core_unhide_cursor(self) end,

        --- Move the cursor to the given point.
        --
        -- The point is interpreted as being in global coordinates.
        -- @tparam Core self the wayfire instance.
        -- @tparam Pointf position the cursor position.
        warp_cursor = function(self, position)
            ffi.C.wf_Core_warp_cursor(self, position)
        end,

        --- Get the cursor position in global coordinates.
        --
        -- @tparam Core self the wayfire instance.
        -- @treturn Pointf the cursor position.
        get_cursor_position = function(self)
            return ffi.C.wf_Core_get_cursor_position(self)
        end,

        --- Get the view that currently has cursor focus.
        --
        -- @tparam Core self the wayfire instance.
        -- @treturn View the view that currently has cursor focus.
        get_cursor_focus_view = function(self)
            return ffi.C.wf_Core_get_cursor_focus_view(self)
        end,

        --- Get the view that currently has touch focus.
        --
        -- @tparam Core self the wayfire instance.
        -- @treturn View the view that currently has touch focus.
        get_touch_focus_view = function(self)
            return ffi.C.wf_Core_get_touch_focus_view(self)
        end,

        --- Get the view at the given point.
        --
        -- The point is interpreted as being in global coordinates.
        -- Returns `nil` if there is no view at the point.
        -- @tparam Core self the wayfire instance.
        -- @tparam Pointf point the point.
        -- @treturn ?View the view at the given point. Or nil if none.
        get_view_at = function(self, point)
            return ffi.C.wf_Core_get_view_at(self, point)
        end,

        --- Give a view keyboard focus.
        --
        -- @tparam Core self the wayfire instance.
        -- @tparam View view the view to set as active.
        set_active_view = function(self, view)
            ffi.C.wf_Core_set_active_view(self, view)
        end,

        --- Focus the given view and it's output.
        --
        -- Also brings the view to the front of the stack.
        -- @tparam Core self the wayfire instance.
        -- @tparam View view the view to give focus to.
        focus_view = function(self, view)
            ffi.C.wf_Core_focus_view(self, view)
        end,

        --- Focus the given output.
        --
        -- @tparam Core self the wayfire instance.
        -- @tparam Output output the output to give focus to.
        focus_output = function(self, output)
            ffi.C.wf_Core_focus_output(self, output)
        end,

        --- Get the currently focused output.
        --
        -- @tparam Core self the wayfire instance.
        -- @treturn Output the currently focused output.
        get_active_output = function(self)
            return ffi.C.wf_Core_get_active_output(self)
        end,

        --- Move the given view to the output.
        --
        -- If `reconf` is `true`, then clamp the view's geometry to the
        -- target output's geometry.
        -- @tparam Core self the wayfire instance.
        -- @tparam View view the view to move.
        -- @tparam Output new_output the output to move the view to.
        -- @tparam bool reconf whether to clamp the view's geometry to the
        -- target output geometry.
        move_view_to_output = function(self, view, new_output, reconf)
            if reconf == nil then reconf = false end
            ffi.C.wf_Core_move_view_to_output(self, view, new_output, reconf)
        end,

        --- Get the Wayland socket name of the current Wayland session.
        --
        -- @tparam Core self the wayfire instance.
        -- @treturn string the Wayland socket name of the current Wayland
        -- session.
        get_wayland_display = function(self)
            return ffi.string(ffi.C.wf_Core_get_wayland_display(self))
        end,

        --- Get the XWayland display name.
        --
        -- @tparam Core self the wayfire instance.
        -- @treturn string the XWayland display name.
        get_xwayland_display = function(self)
            return ffi.string(ffi.C.wf_Core_get_xwayland_display(self))
        end,

        --- Run a command with the system POSIX shell.
        --
        -- Sets the correct `WAYLAND_DISPLAY` and `DISPLAY` variables as well as
        -- others in order to make the process properly aware of the Wayfire
        -- session.
        --
        -- @tparam Core self the wayfire instance.
        -- @tparam string command the command to run.
        -- @treturn int the PID of the process.
        run = function(self, command) ffi.C.wf_Core_run(self, command) end,

        --- Shutdown the whole Wayfire process.
        --
        -- @tparam Core self the wayfire instance.
        shutdown = function(self) ffi.C.wf_Core_shutdown(self) end,

        --- Get the OutputLayout object representing the layout of the outputs.
        --
        -- @tparam Core self the wayfire instance.
        -- @treturn OutputLayout the OutputLayout object representing the layout
        -- of the outputs.
        get_output_layout = function(self)
            return ffi.C.wf_Core_get_output_layout(self)
        end,

        --- Hook into a signal on the Wayfire instance.
        --
        -- Start listening for and calling `handler` on this signal. 
        -- The type of `data` depends on the signal being listened for.
        -- See (TODO: signal definitions page).
        --
        -- @usage wf.get_core():hook('reload-config', function(core, data)
        --     print('The wayfire config has been reloaded!')
        -- end)
        -- @usage
        -- local wf = require('wf')
        --
        -- -- Whatever the wayfire config file says, override the option value
        -- -- as soon as it's reloaded.
        -- do
        --     local my_settings = function()
        --         wf.set {'core', background_color = '#344B5DFF'}
        --     end
        -- 
        --     local core = wf.get_core()
        --     core:hook('reload-config', function(core, data)
        --         -- Config was reloaded
        --         my_settings()
        --     end)
        -- 
        --     my_settings()
        -- end
        -- @usage
        -- assert(handler == wf.get_core():hook('startup-finished', handler))
        --
        -- @tparam Core self
        -- @tparam string signal
        -- @tparam fn(core,data) handler
        -- @treturn fn(core,data) handler
        hook = function(self, signal, handler)
            local raw_handler = function(_emitter, data)
                data = Raw:convert_signal_data('core', signal, data)
                handler(self, data)
            end

            ObjectData:set(self, handler, raw_handler)
            Raw:subscribe(self, signal, raw_handler)
            return handler
        end,

        --- Unhook from a signal on the Wayfire instance.
        --
        -- Stop listening for and calling `handler` on this signal.
        --
        -- @usage 
        -- local handler = wf.get_core():hook('view-created',
        --                             function(core, data) end)
        -- core:unhook('view-created', handler)
        --
        -- @usage local core = wf.get_core()
        -- local handler = function() end
        -- core:hook('view-created', handler)
        -- core:hook('startup-finished', handler)
        -- core:unhook('view-created', handler)
        -- core:unhook('startup-finished', handler)
        --
        -- @tparam Core self
        -- @tparam string signal
        -- @tparam fn(core,data) handler
        unhook = function(self, signal, handler)
            local raw_handler = ObjectData:get(self, handler)
            Raw:unsubscribe(self, signal, raw_handler)
            ObjectData:set(self, handler, nil)
        end
    }
})

---The current layout of the outputs.
--
-- Mainly useful for hooking into output layout signals like `"output-added"`.
--
-- @usage local output_layout = wf.get_core():get_output_layout()
-- output_layout:hook("output-added", function(output_layout, data)
--     print("new output!", data.output)
-- end)
-- @type OutputLayout
ffi.metatype("wf_OutputLayout", {
    __tostring = function(self)
        return "OutputLayout{ " .. self:get_num_outputs() .. " output(s) }"
    end,
    __index = {
        --- Get the output at the given coordinates.
        --
        -- Returns nil if no output is on the specified coordinate.
        --
        -- @tparam OutputLayout self the output layout object.
        -- @tparam number x the X coordinate.
        -- @tparam number y the Y coordinate.
        -- @treturn Output the output at the given coordinates or nil.
        get_output_at = function(self, x, y)
            ffi.C.wf_OutputLayout_get_output_at(self, x, y)
        end,

        --- Get the output at the given coordinates and the closest point on it.
        --
        -- Returns `output, closest` meaning the output found at the given
        -- origin point and the closest point to the given origin on the output.
        --
        -- @tparam OutputLayout self the output layout object.
        -- @tparam Pointf origin The origin point to query for.
        -- @treturn Output the output at the given coordinates.
        -- @treturn Pointf the closest point to the origin inside the found
        -- output.
        get_output_coords_at = function(self, origin)
            local closest = ffi.new('wf_Pointf')
            local output = ffi.C.wf_OutputLayout_get_output_coords_at(self,
                                                                      origin,
                                                                      closest)
            return output, closest
        end,

        --- Get the number of current outputs.
        --
        -- @tparam OutputLayout self the output layout object.
        -- @treturn number the number of outputs.
        get_num_outputs = function(self)
            return ffi.C.wf_OutputLayout_get_num_outputs(self)
        end,

        --- Iterate through the current outputs.
        -- 
        -- Start by calling this function with `nil` as parameter and then
        -- successively call it until the returned value is the same as the
        -- first call.
        -- 
        -- @usage local first = output_layout:get_next_output(nil)
        -- local output = first
        -- repeat
        --     print("Current output:", output)
        --     local output = output_layout:get_next_output(output)
        -- until output == first
        -- @tparam OutputLayout self the output layout object.
        -- @tparam Output prev the output to step forwards from.
        -- @treturn Output the next output.
        get_next_output = function(self, prev)
            return ffi.C.wf_OutputLayout_get_next_output(self, prev)
        end,

        --- Get an output by name.
        -- 
        -- @tparam OutputLayout self the output layout object.
        -- @tparam string name the name of the output.
        -- @treturn Output the next output.
        find_output = function(self, name)
            return ffi.C.wf_OutputLayout_find_output(self, name)
        end,

        -- COMBAK: write the hook/unhook methods for this. We need a special
        -- case in the Raw stuff to opt out of lifetime tracking since
        -- OutputLayout is not an object but just a signal provider.

        --- Hook into a signal on the output layout.
        --
        -- Start listening for and calling `handler` on this signal. 
        -- The type of `data` depends on the signal being listened for.
        -- See (TODO: signal definitions page).
        --
        -- @usage local layout = wf.get_core():get_output_layout()
        -- layout:hook('output-added', function(layout, data)
        --     print('An output has been added:', data.output)
        -- end)
        -- @usage
        -- assert(handler == layout:hook('output-removed', handler))
        --
        -- @tparam OutputLayout self
        -- @tparam string signal
        -- @tparam fn(layout,data) handler
        -- @treturn fn(layout,data) handler
        hook = function(self, signal, handler)
            local raw_handler = function(_emitter, data)
                data = Raw:convert_signal_data('output-layout', signal, data)
                handler(self, data)
            end

            ObjectData:set(self, handler, raw_handler,
                           {lifetime_cleanup = false})
            Raw:subscribe(self, signal, raw_handler, {lifetime_cleanup = false})
            return handler
        end,

        --- Unhook from a signal on the output layout.
        --
        -- Stop listening for and calling `handler` on this signal.
        --
        -- @usage 
        -- local handler = wf.get_core():hook('output-added',
        --                             function(layout, data) end)
        -- core:unhook('output-added', handler)
        --
        -- @usage local layout = wf.get_core():get_output_layout()
        -- local handler = function() end
        -- layout:hook('output-added', handler)
        -- layout:hook('output-removed', handler)
        -- layout:unhook('output-added', handler)
        -- layout:unhook('output-removed', handler)
        --
        -- @tparam OutputLayout self
        -- @tparam string signal
        -- @tparam fn(layout,data) handler
        unhook = function(self, signal, handler)
            local raw_handler = ObjectData:get(self, handler)
            Raw:unsubscribe(self, signal, raw_handler)
            ObjectData:set(self, handler, nil)
        end
    }
})

---A wayfire output.
-- @usage local view = -- some View
-- local output = view:get_output()
-- output:ensure_visible(view)
-- output:focus_view(view)
-- @type Output
ffi.metatype("wf_Output", {
    __tostring = function(self)
        return ffi.string(ffi.C.wf_Output_to_string(self))
    end,
    __index = {
        --- Get the screen size of this output.
        -- @tparam Output self the output.
        -- @treturn Dimensions the screen size.
        get_screen_size = function(self)
            return ffi.C.wf_Output_get_screen_size(self)
        end,

        --- Get the screen size of this output as a Geometry.
        -- The `x,y` of the Geometry will be 0.
        -- @tparam Output self the output.
        -- @treturn Geometry the screen size.
        get_relative_geometry = function(self)
            return ffi.C.wf_Output_get_relative_geometry(self)
        end,

        --- Get the geometry of the screen.
        -- This should include the screen dimensions as well as meaningful `x,y`
        -- coordinates.
        -- @tparam Output self the output.
        -- @treturn Geometry the screen geometry.
        get_layout_geometry = function(self)
            return ffi.C.wf_Output_get_layout_geometry(self)
        end,

        --- Ensure the pointer is on this output.
        -- If the pointer isn't already on this output, move it.
        --
        -- If `center` is `true`, move the pointer to the center of the screen
        -- regardless of whether it is already on this output.
        -- @tparam Output self the output.
        -- @tparam bool center whether to unconditionally center the pointer.
        ensure_pointer = function(self, center)
            if center == nil then center = false end
            ffi.C.wf_Output_ensure_pointer(self, center)
        end,

        --- Get the cursor position relative to the output.
        -- @tparam Output self the output.
        -- @treturn Geometry the screen geometry.
        get_cursor_position = function(self)
            return ffi.C.wf_Output_get_cursor_position(self)
        end,

        --- Get the view at the top of the workspace layer.
        -- @tparam Output self the output.
        -- @treturn View the view at the top of the workspace layer.
        get_top_view = function(self)
            return ffi.C.wf_Output_get_top_view(self)
        end,

        --- Get the most recently focused view on this output.
        -- @tparam Output self the output.
        -- @treturn View the view at the top of the workspace layer.
        get_active_view = function(self)
            return ffi.C.wf_Output_get_active_view(self)
        end,

        --- Try to focus the view on this output.
        -- If `raise` is `true`, also raise it to the top of its layer.
        -- @tparam Output self the output.
        -- @tparam View view the view to focus.
        -- @tparam bool raise whether to raise the view.
        -- @treturn View the view at the top of the workspace layer.
        focus_view = function(self, view, raise)
            if raise == nil then raise = false end
            ffi.C.wf_Output_focus_view(self, view, raise)
        end,

        --- Switch workspaces to make this view visible.
        -- @tparam Output self the output.
        -- @tparam View view the view to make visible.
        -- @treturn bool whether a workspace switch occurred.
        ensure_visible = function(self, view)
            return ffi.C.wf_Output_ensure_visible(self, view)
        end,

        --- Get the output's workarea geometry.
        -- @tparam Output self the output.
        -- @treturn Geometry the the output's workarea.
        get_workarea = function(self)
            return ffi.C.wf_Output_get_workarea(self)
        end,

        --- Hook into a signal on this output.
        --
        -- Start listening for and calling `handler` on this signal. 
        -- The type of `data` depends on the signal being listened for.
        -- See (TODO: signal definitions page).
        --
        -- @usage output:hook('view-mapped', function(output, data)
        --     print('View ', data.view:get_title(), ' mapped!')
        -- end)
        -- @usage assert(handler == output:hook('view-focused', handler))
        --
        -- @tparam Output self
        -- @tparam string signal
        -- @tparam fn(output,data) handler
        -- @treturn fn(output,data) handler
        hook = function(self, signal, handler)
            local raw_handler = function(_emitter, data)
                data = Raw:convert_signal_data('output', signal, data)
                handler(self, data)
            end

            ObjectData:set(self, handler, raw_handler)
            Raw:subscribe(self, signal, raw_handler)
            return handler
        end,

        --- Unhook from a signal on this output.
        --
        -- Stop listening for and calling `handler` on this signal.
        --
        -- @usage 
        -- local handler = output:hook('view-focused',
        --                             function(output, data) end)
        -- output:unhook('view-focused', handler)
        --
        -- @usage local handler = function() end
        -- output:hook('view-mapped', handler)
        -- output:hook('view-focused', handler)
        -- output:unhook('view-mapped', handler)
        -- output:unhook('view-focused', handler)
        --
        -- @tparam Output self
        -- @tparam string signal
        -- @tparam fn(output,data) handler
        unhook = function(self, signal, handler)
            local raw_handler = ObjectData:get(self, handler)
            Raw:unsubscribe(self, signal, raw_handler)
            ObjectData:set(self, handler, nil)
        end
    }
})

---A wayfire view.
-- @usage
-- -- If view is foot, then set its geometry and hook into the 'title-changed'
-- -- event of this view.
-- if view:get_app_id() == 'foot' then
--     view:set_geometry({1, 2, 500, 300})
-- 
--     view:hook('title-changed', function(view, data)
--         print('View title changed! New title:', data.view:get_title())
--         assert(view == data.view)
--     end)
-- end
-- @type View
ffi.metatype("wf_View", {
    __tostring = function(self)
        return ffi.string(ffi.C.wf_View_to_string(self))
    end,
    __index = {
        --- Get the view's title.
        -- @tparam View self the view.
        -- @treturn string the view's title.
        get_title = function(self)
            return ffi.string(ffi.C.wf_View_get_title(self))
        end,

        --- Get the view's app id.
        -- @tparam View self the view.
        -- @treturn string the view's app id.
        get_app_id = function(self)
            return ffi.string(ffi.C.wf_View_get_app_id(self))
        end,

        --- Get the view's wm geometry.
        -- @tparam View self the view.
        -- @treturn Geometry the view's wm geometry.
        get_wm_geometry = function(self)
            return ffi.C.wf_View_get_wm_geometry(self)
        end,

        --- Get the view's output geometry.
        -- @tparam View self the view.
        -- @treturn Geometry the view's output geometry.
        get_output_geometry = function(self)
            return ffi.C.wf_View_get_output_geometry(self)
        end,

        --- Get the view's bounding box.
        -- @tparam View self the view.
        -- @treturn Geometry the view's bounding box.
        get_bounding_box = function(self)
            return ffi.C.wf_View_get_bounding_box(self)
        end,

        --- Get the view's output.
        -- @tparam View self the view.
        -- @treturn Output the output the view is on.
        get_output = function(self) return ffi.C.wf_View_get_output(self) end,

        --- Set the view's geometry.
        -- @tparam View self the view.
        -- @tparam Geometry geo the view's new geometry.
        -- @usage view:set_geometry({x, y, w, h})
        set_geometry = function(self, geo)
            return ffi.C.wf_View_set_geometry(self, geo)
        end,

        --- Hook into a signal on this view.
        --
        -- Start listening for and calling `handler` on this signal. 
        -- The type of `data` depends on the signal being listened for.
        -- See (TODO: signal definitions page).
        --
        -- @usage view:hook('title-changed', function(view, data)
        --     print('View title changed! New title:', data.view:get_title())
        --     assert(view == data.view)
        -- end)
        -- @usage assert(handler == view:hook('title-changed', handler))
        --
        -- @tparam View self
        -- @tparam string signal
        -- @tparam fn(view,data) handler
        -- @treturn fn(view,data) handler
        hook = function(self, signal, handler)
            local raw_handler = function(_emitter, data)
                data = Raw:convert_signal_data('view', signal, data)
                handler(self, data)
            end

            ObjectData:set(self, handler, raw_handler)
            Raw:subscribe(self, signal, raw_handler)
            return handler
        end,

        --- Unhook from a signal on this view.
        --
        -- Stop listening for and calling `handler` on this signal.
        --
        -- @usage local handler = view:hook('title-changed', function(view, data) end)
        -- view:unhook('title-changed', handler)
        --
        -- @usage local handler = function() end
        -- view:hook('title-changed', handler)
        -- view:hook('app-id-changed', handler)
        -- view:unhook('title-changed', handler)
        -- view:unhook('app-id-changed', handler)
        --
        -- @tparam View self
        -- @tparam string signal
        -- @tparam fn(view,data) handler
        unhook = function(self, signal, handler)
            local raw_handler = ObjectData:get(self, handler)
            Raw:unsubscribe(self, signal, raw_handler)
            ObjectData:set(self, handler, nil)
        end
    }
})

-- Outputs represented as a single outputs table since there is only only
-- central wflua instance per wayfire session.
do
    local outputs = {_hooked_signals = {}}
    local output_layout = Wf.get_core():get_output_layout()

    -- Populate output pointers
    do
        local _raw_outputs = {}

        local first = output_layout:get_next_output(nil)
        local output = first
        repeat
            _raw_outputs[object_id(output)] = output

            local output = output_layout:get_next_output(output)
        until output == first

        outputs._raw_outputs = _raw_outputs
    end

    -- Update the raw_outputs list appropriately
    do
        output_layout:hook('output-added', function(layout, data)
            if outputs._raw_outputs[object_id(data.output)] == nil then
                outputs._raw_outputs[object_id(data.output)] = data.output
                for _, sig in pairs(outputs._hooked_signals) do
                    data.output:hook(sig.signal, sig.handler)
                end
            end
        end)
        output_layout:hook('output-removed', function(layout, data)
            outputs._raw_outputs[object_id(data.output)] = nil
            -- No need to unhook signals as this is taken care of by the
            -- lifetime cleanup of the output object.
        end)
    end

    --- Hook into a signal on all outputs.
    --
    -- Start listening for and calling `handler` on this signal. 
    -- `output` is the specific `Output` that triggered the signal.
    -- The type of `data` depends on the signal being listened for.
    -- See (TODO: signal definitions page).
    --
    -- Note that this differs from calling `Output:hook()` on a specific
    -- `output` as we are hooking into this signal for *all* outputs
    -- simultaneously.
    --
    -- @usage 
    -- local wf = require 'wf'
    --
    -- wf.outputs:hook('view-focused', function(output, data)
    --     print('View ', data.view, ' focused on output ', output)
    -- end)
    -- @usage assert(handler == wf.outputs:hook('view-focused', handler))
    --
    -- @tparam string signal
    -- @tparam fn(output,data) handler
    -- @treturn fn(output,data) handler
    -- @within Functions
    function outputs:hook(signal, handler)
        self._hooked_signals[signal .. tostring(handler)] = {
            signal = signal,
            handler = handler
        }
        for _, output in pairs(self._raw_outputs) do
            output:hook(signal, handler)
        end
        return handler
    end

    --- Unhook from a signal on all outputs.
    --
    -- Stop listening for and calling `handler` on this signal.
    -- @usage
    -- local handler = wf.outputs:hook('view-focused',
    --                                 function(output, data) end)
    -- wf.outputs:unhook('view-focused', handler)
    --
    -- @usage local handler = function() end
    -- wf.outputs:hook('view-mapped', handler)
    -- wf.outputs:hook('view-focused', handler)
    -- wf.outputs:unhook('view-mapped', handler)
    -- wf.outputs:unhook('view-focused', handler)
    --
    -- @tparam string signal
    -- @tparam fn(output,data) handler
    -- @within Functions
    function outputs:unhook(signal, handler)
        self._hooked_signals[signal .. tostring(handler)] = nil
        for _, output in pairs(self._raw_outputs) do
            output:unhook(signal, handler)
        end
        return handler
    end

    Wf.outputs = outputs
end

return Wf
