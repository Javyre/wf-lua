local Log = {}

local function to_strings(list)
    for i, a in ipairs(list) do list[i] = tostring(a) end
    return list
end

local function log(color, ...)
    io.stderr:write('[' .. color .. 'm')
    io.stderr:write(unpack(to_strings({...})))
    io.stderr:write('[m\n')
end

function Log.err(...) return log(31, 'EE: ', ...) end
function Log.warn(...) return log(33, 'WW: ', ...) end
function Log.debug(...) return log(0, 'DD: ', ...) end

return Log
