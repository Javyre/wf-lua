local wf = require('wf')
local wf_ipc = require('wf.ipc')

print('Hello, lua!')

wf_ipc.def_cmd {
    'wait_for', [[
Wait for a view with the given app id to be mapped.

USAGE:
    wait_for [-w] <APPID>

A message will be returned saying "View mapped!" followed by the title of the
mapped view. Pass -w to watch for this event indefinitely.
]], function(promise, args)
        if #args == 0 then
            promise:reject_invalid_arguments('No arguments given.')
            return
        end

        local watch = false
        local app_id = args[1]
        if #args == 2 and args[1] == '-w' then
            watch = true
            app_id = args[2]
            promise:begin_notifications()
        end

        local handler
        handler = wf.outputs:hook('view-mapped', function(output, data)
            if data.view:get_app_id() == app_id then
                local msg = "View mapped! " .. data.view:get_title()
                if watch then
                    promise:notify(msg)
                else
                    promise:resolve(msg)
                    wf.outputs:unhook('view-mapped', handler)
                end
            end
        end)

        -- Clean up if the client shutsdown the connection before the command is
        -- resolved.
        promise:hook_cancel(function()
            print('Promise cancelled. Cleaning up.')
            wf.outputs:unhook('view-mapped', handler)
        end)
    end
}

wf.set {
    'zoom',
    interpolation_method = 0 -- Linear interpolation
}

local function print_output(output)
    print('output:          ' .. tostring(output))
    print('output workarea: ' .. tostring(output:get_workarea()))
end

local function print_view(view)
    print('view:                 ' .. tostring(view))
    print('view title:           ' .. tostring(view:get_title()))
    print('view app_id:          ' .. tostring(view:get_app_id()))
    print('view wm_geometry:     ' .. tostring(view:get_wm_geometry()))
    print('view output_geometry: ' .. tostring(view:get_output_geometry()))
    print('view bounding_box:    ' .. tostring(view:get_bounding_box()))
    print('view output:          ' .. tostring(view:get_output()))
end

local handler
handler = wf.outputs:hook('view-mapped', function(output, data)
    print('>>>> View mapped! <<<<')
    print_output(output)
    print_view(data.view)

    if data.view:get_app_id() == 'foot' then
        -- data.view:set_geometry({1, 2, 500, 300})

        data.view:hook('title-changed', function(view, data)
            print('>>> View title changed! New title:', data.view:get_title())

            local output = view:get_output()
            output:ensure_visible(view)
            output:focus_view(view)

            assert(view == data.view)
        end)

        wf.outputs:unhook('view-mapped', handler)
    end
end)

wf.outputs:hook('view-unmapped', function(output, data)
    print('>>>> View UNmapped! <<<<')
    print_output(output)
    print_view(data.view)
end)

-- Whatever the wayfire config file says, override the option value as soon as
-- it's reloaded.
do
    local my_settings = function()
        wf.set {'core', background_color = '#344B5DFF'}
    end

    local core = wf.get_core()
    core:hook('reload-config', function(core, data)
        print('Config was reloaded!')

        my_settings()
    end)

    my_settings()
end
