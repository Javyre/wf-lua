local wf = require('wf')

print('Hello, lua!')

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
        data.view:set_geometry({1, 2, 500, 300})

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
