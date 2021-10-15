local wf = require('wf')

print('Hello, lua!')

wf.set{
    'zoom',
    interpolation_method = 0, -- Linear interpolation
}

local function print_output(output)
    print('output:          '..tostring(output))
    print('output workarea: '..tostring(output:get_workarea()))
end

local function print_view(view)
    print('view:        '..tostring(view))
    print('view title:  '..tostring(view:get_title()))
    print('view app_id: '..tostring(view:get_app_id()))
end

local handler
handler = wf.outputs:hook('view-mapped', function(output, data)
    print('>>>> View mapped! <<<<')
    print_output(output)
    print_view(data.view)

    -- wf.outputs:unhook('view-mapped', handler)
end)

wf.outputs:hook('view-unmapped', function(output, data)
    print('>>>> View UNmapped! <<<<')
    print_output(output)
    print_view(data.view)
end)
