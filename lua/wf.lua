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

function Raw:subscribe(emitter_ptr, signal, handler)
    local emitter = object_id(emitter_ptr)

    Log.debug('subscribing to ' .. emitter .. ' ' .. signal)

    if not self.signal_callbacks[emitter] then
        self.signal_callbacks[emitter] = {
            -- Clean up when the C++ emitter object dies.
            lifetime_handler = self:subscribe_lifetime(emitter_ptr, function()
                self.signal_callbacks[emitter] = nil
                ffi.C.wflua_signal_unsubscribe_all(emitter_ptr)
            end),
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
            -- No longer need to listen for emitter destroyed
            self.unsubscribe_lifetime(emitter_ptr,
                                      emitter_entry.lifetime_handler)
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
    Raw.signal_data_converters = {
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
            ['view-move-request'] = view_signal
        },
        view = {
            ['mapped'] = view_signal,
            ['pre-unmapped'] = view_signal,
            ['unmapped'] = view_signal,
            ['set-sticky'] = view_signal,
            ['title-changed'] = view_signal,
            ['app-id-changed'] = view_signal,
            ['decoration-state-updated'] = view_signal,
            ['ping-timeout'] = view_signal
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

-- Public API

local Wf = {}

-- Outputs are represented as a single outputs table since there is only only
-- central wflua instance per wayfire session.
do
    local outputs = {_signal_handlers = {}, _raw_outputs = nil}

    -- Populate output pointers
    do
        local _raw_outputs = util.Set()

        local first = ffi.C.wf_get_next_output(output)
        local output = first
        repeat
            _raw_outputs:add(output)

            local output = ffi.C.wf_get_next_output(output)
        until output == first

        outputs._raw_outputs = _raw_outputs
    end

    --- Hook into a signal on all outputs.
    --
    -- Start listening for and calling `handler` on this signal. 
    -- `output` is the specific `Output` that triggered the signal.
    -- The type of `data` depends on the signal being listened for.
    -- See (TODO: signal definitions page).
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
    function outputs:hook(signal, handler)
        if not self._signal_handlers[signal] then
            local hook = util.Hook()
            local handler = function(emitter, data)
                data = Raw:convert_signal_data('output', signal, data)
                emitter = ffi.cast('wf_Output *', emitter)

                hook:call(emitter, data)
            end

            self._signal_handlers[signal] = {hook = hook, handler = handler}

            self._raw_outputs:for_each(function(output)
                Raw:subscribe(output, signal, handler)
            end)
        end

        self._signal_handlers[signal].hook:hook(handler)

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
    function outputs:unhook(signal, handler)
        if not self._signal_handlers[signal] then
            error('Signal "' .. signal ..
                      '" not in signal_handlers. Cannot unhook!')
        end

        local hook = self._signal_handlers[signal].hook

        hook:unhook(handler)

        if hook:is_empty() then
            local handler = self._signal_handlers[signal].handler
            self._raw_outputs:for_each(function(output)
                Raw:unsubscribe(output, signal, handler)
            end)

            self._signal_handlers[signal] = nil
        end

        return handler
    end

    Wf.outputs = outputs
end

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

---A wayfire output.
-- @type Output
ffi.metatype("wf_Output", {
    __tostring = function(self)
        return ffi.string(ffi.C.wf_Output_to_string(self))
    end,
    __index = {
        --- Get the output's workarea geometry.
        -- @tparam Output self the output.
        -- @treturn Geometry the the output's workarea.
        get_workarea = function(self)
            return ffi.C.wf_Output_get_workarea(self)
        end
    }
})

--- Lua-local data attached to views.
-- @type ViewData
-- @local
local ViewData = {
    data = {},

    --- Store some data.
    --
    -- Delete some stored data by setting it to `nil`.
    -- @local
    set = function(self, view_ptr, key, value)
        local view = object_id(view_ptr)
        if not self.data[view] then
            if value == nil then return end

            self.data[view] = {[key] = value}
            Raw:subscribe_lifetime(view_ptr,
                                   function() self.data[view] = nil end)
        else
            self.data[view][key] = value
        end
    end,

    --- Retrieve some stored data.
    -- @local
    get = function(self, view_ptr, key)
        return self.data[object_id(view_ptr)][key]
    end
}

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

            ViewData:set(self, handler, raw_handler)
            Raw:subscribe(self, signal, raw_handler)
            return handler
        end,

        --- Unhook from a signal on this view.
        --
        -- Stop listening for and calling `handler` on this signal.
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
            local raw_handler = ViewData:get(self, handler)
            Raw:unsubscribe(self, signal, raw_handler)
            ViewData:set(self, handler, nil)
        end
    }
})

--
--
-- TEST --
--
--

local function test(wf)
    wf.set {'swayfire-deco', border_radius = 123, border_width = 23}

    wf.outputs.hook('view-mapped', function(data)
        print(string.format('view %s mapped', data.view.title))
    end)
end

return Wf
