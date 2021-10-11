local wf = require('wf')

print('Hello, lua!')

wf.set{
    'zoom',
    interpolation_method = 0, -- Linear interpolation
}

local handler
handler = wf.outputs:hook('view-mapped', function(output, data)
    print('>>>> View mapped! <<<<', output, data.view, ':',
        data.view:get_title(), ':', data.view:get_app_id())

    -- wf.outputs:unhook('view-mapped', handler)
end)

wf.outputs:hook('view-unmapped', function(output, data)
    print('>>>> View UNmapped! <<<<', output, data.view)
end)
