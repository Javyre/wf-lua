--- Customizable IPC server for Wayfire.
--
-- @author Javier A. Pollak
-- @license GPL-v3
-- @alias Wf-IPC
-- @module wf.ipc
--
local ffi = require 'ffi'
local util = require 'wf.util'

local commands = {}

wf__ipc_command_callback = function(id, command_name, args)
    local cmd = commands[command_name]
    if not cmd then
        local msg = string.format('Unknown command ' % s '', command_name)
        return true, msg, 1
    end
    local cb = cmd.handler

    local result = nil
    local error_code = 0

    --- An ipc command promise.
    --
    -- An ipc command is either a simple _'request-response'_ command or a
    -- _'watcher'_ command. The command should go as follows:
    --
    -- - For _'request-response'_ commands: The command must only resolve or
    --   reject the promise. The command may resolve or reject at any time.
    --
    -- - For _'watcher'_ commands: The command must first
    --   `Promise:begin_notifications` before then sending any amount of
    --   notifications at any time. The command may `Promise:end_notifications`
    --   to signal the end of the notification stream. The command may reject
    --   only before the call to `Promise:begin_notifications`.
    --
    -- In both types of command, the promise will be cancelled in the event of a
    -- connection drop. This event can be listened for with the
    -- `Promise:hook_cancel` method.
    --
    -- @type Promise
    local promise = {
        id = id,
        pending = true,
        notifying = nil,
        cancel_hook = util.Hook {},

        -- Sync resolve

        --- Resolve the promise sending a result string to the client.
        -- @tparam Promise self the promise object.
        -- @tparam string result_ the result string to send to the client.
        resolve = function(self, result_)
            assert(self.pending, 'Promise already resolved.')
            result = tostring(result_)
            self.pending = false
        end,

        --- Signal the begining of the notification stream.
        -- @tparam Promise self the promise object.
        begin_notifications = function(self)
            assert(self.pending, 'Promise already resolved.')
            -- Synchronous notifications accumulate in this result table.
            result = {}
            self.pending = false
            self.notifying = true
        end,

        --- Signal the end of the notification stream.
        -- @tparam Promise self the promise object.
        end_notifications = function(self)
            assert(self.notifying == true,
                   'begin_notifications() has not been called.')
            -- This is actually just a special notification.
            table.insert(result, false);
        end,

        --- Send a notification message.
        -- @tparam Promise self the promise object.
        -- @tparam string notification the notification to send.
        notify = function(self, notification)
            assert(self.notifying ~= nil,
                   'begin_notifications() has not been called.')
            assert(self.notifying ~= false,
                   'cannot send notification after end_notifications()' ..
                       ' has been called.')

            table.insert(result, tostring(notification))
        end,

        reject_impl = function(self, result_, error_code_)
            assert(self.pending, 'Promise already resolved.')
            result = tostring(result_)
            error_code = error_code_
            self.pending = false
        end,

        --- Reject the promise with an error message.
        --
        -- @tparam Promise self the promise object.
        -- @tparam string result_ the error string to send to the client.
        reject = function(self, result_)
            self:reject_impl(result_, ffi.C.WFLUA_IPC_COMMAND_ERROR)
        end,

        --- Reject the promise because of invalid arguments.
        --
        -- @tparam Promise self the promise object.
        -- @tparam string msg the error string to send to the client.
        reject_invalid_arguments = function(self, msg)
            msg = string.format('Invalid arguments given to %s: %s\nUsage: %s',
                                command_name, msg, cmd.usage)
            self:reject_impl(msg, ffi.C.WFLUA_IPC_COMMAND_INVALID_ARGS)
        end,

        --- Hook into the promise being cancelled.
        --
        -- A promise can be cancelled if the connection to the client drops
        -- while the promise is still pending. It is useful to hook into this
        -- event in order to cleanly cancel any pending state for the command.
        --
        -- @tparam Promise self the promise object.
        -- @tparam fn() handler the callback.
        hook_cancel = function(self, handler)
            return self.cancel_hook:hook(handler)
        end,

        --- Unhook from the promise being cancelled.
        --
        -- @tparam Promise self the promise object.
        -- @tparam fn() handler the callback.
        unhook_cancel = function(self, handler)
            return self.cancel_hook:unhook(handler)
        end
    }

    cb(promise, args)

    if promise.pending or promise.notifying == true then
        promise.end_notifications = function(self)
            assert(self.notifying == true,
                   'begin_notifications() has not been called.')
            ffi.C.wflua_ipc_command_notify(self.id, nil)
            self.notifying = false
        end
        promise.notify = function(self, notification)
            assert(self.notifying ~= nil,
                   'begin_notifications() has not been called.')
            assert(self.notifying == true,
                   'cannot send notification after end_notifications()' ..
                       ' has been called.')
            ffi.C.wflua_ipc_command_notify(self.id, notification)
        end
    end

    if promise.pending then
        -- Async resolve
        promise.resolve = function(self, result)
            assert(self.pending, 'Promise already resolved.')
            result = tostring(result)
            ffi.C.wflua_ipc_command_resolve(self.id, result)
            self.pending = false
        end
        promise.reject_impl = function(self, result, error_code)
            assert(self.pending, 'Promise already resolved.')
            result = tostring(result)
            ffi.C.wflua_ipc_command_reject(self.id, result, error_code or
                                               ffi.C.WFLUA_IPC_COMMAND_ERROR)
            self.pending = false
        end

        promise.begin_notifications = function(self)
            assert(self.pending, 'Promise already resolved.')
            ffi.C.wflua_ipc_command_begin_notifications(self.id)
            self.pending = false
            self.notifying = true
        end

        return 0, nil, nil, function()
            promise.pending = false
            promise.cancel_hook:call()
        end
    elseif promise.notifying ~= nil then
        assert(promise.pending == false)
        assert(type(result) == 'table')
        return 2, result, nil, function() promise.cancel_hook:call() end
    else
        return 1, result, error_code, nil
    end
end

---Functions
-- @section

local M = {}

--- Define a new IPC command.
--
-- Parameters are passed in a single array table.
--
-- The first argumment is the name of the command.
--
-- The second argument must contain the following in this order:
--
-- - A single sentence summary ending with a `.`.
-- - `USAGE:` followed by a single line usage synopsis.
-- - Any amount of trailing text to be included as additional documentation.
--
-- The third argument is a function to handle the command. This function is
-- given as its arguments when it is called a `Promise` and an array of command
-- arguments.
--
-- @usage 
-- -- An example "request-response" command. 
-- -- Can be run with 'wf-msg wait_for <APPID>'.
--
-- local wf_ipc = require('wf.ipc')
--
-- wf_ipc.def_cmd {
--     'wait_for', [[
-- Wait for a view with the given app id to be mapped.
-- 
-- USAGE:
--     wait_for <APPID>
--
-- A message will be returned saying 'View mapped!' followed by the title of the
-- mapped view.
-- ]], function(promise, args)
--         if #args == 0 then
--             promise:reject_invalid_arguments('No arguments given.')
--             return
--         end
-- 
--         local handler
--         handler = wf.outputs:hook('view-mapped', function(output, data)
--             if data.view:get_app_id() == args[1] then
--                 promise:resolve('View mapped! ' .. data.view:get_title())
--                 wf.outputs:unhook('view-mapped', handler)
--             end
--         end)
--
--         -- Clean up if the client shutsdown the connection before the command
--         -- is resolved.
--         promise:hook_cancel(function() 
--             print('Promise cancelled. Cleaning up.')
--             wf.outputs:unhook('view-mapped', handler)
--         end)
--     end
-- }
--
-- @usage 
-- -- An example "watcher" command. 
-- -- Can be run with 'wf-msg watch_for <APPID>'.
--
-- local wf_ipc = require('wf.ipc')
--
-- wf_ipc.def_cmd {
--     'watch_for', [[
-- Watch for views with the given app id to be mapped.
-- 
-- USAGE:
--     watch_for <APPID>
--
-- A message will be sent saying 'View mapped!' followed by the title of the
-- mapped view.
-- ]], function(promise, args)
--         if #args == 0 then
--             promise:reject_invalid_arguments('No arguments given.')
--             return
--         end
--
--         promise:begin_notifications()
-- 
--         local handler
--         handler = wf.outputs:hook('view-mapped', function(output, data)
--             if data.view:get_app_id() == args[1] then
--                 promise:notify('View mapped! ' .. data.view:get_title())
--             end
--         end)
--
--         -- Clean up when the client shutsdown the connection.
--         promise:hook_cancel(function() 
--             print('Promise cancelled. Cleaning up.')
--             wf.outputs:unhook('view-mapped', handler)
--         end)
--     end
-- }
-- @tparam {string,string,fn(promise,args)} args The definition of the command.
function M.def_cmd(args)
    if type(args) ~= 'table' or #args ~= 3 then
        error([[The arguments to def_cmd should be passed in the form: 
def_cmd { 
    'command_name', 
    'Summary. USAGE: usage\nRest of help message.',
    function(promise, args) 
        -- Handler
    end,
}]], 2)
    end

    if commands[args[1]] then
        error('Command `' .. args[1] .. '` already defined!', 2)
    end

    local summary, usage, desc =
        args[2]:match '^%s*([^.]*.).-USAGE:%s*([^\n]+)%s*(.-)%s*$'

    if not summary then
        error([[Invalid format given for docstring.
The second argument to def_cmd needs to contain the following in this order:
- A single sentence summary ending with a `.`.
- `USAGE:` followed by a single line usage synopsis.
- Any amount of trailing text to be included as additional documentation.]], 2)
    end

    commands[args[1]] = {
        summary = summary,
        usage = usage,
        description = desc,
        handler = args[3]
    }
end

return M
