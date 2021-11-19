local Log = {
    log_level = 0
}

local function to_strings(list)
    for i, a in ipairs(list) do list[i] = tostring(a) end
    return list
end

local function log(lvl, color, ...)
    if Log.log_level < lvl then
        return
    end

    io.stderr:write('[' .. color .. 'm')
    io.stderr:write(unpack(to_strings({...})))
    io.stderr:write('[m\n')
end

function Log.err(...) return log(0, 31, 'EE: ', ...) end
function Log.warn(...) return log(1, 33, 'WW: ', ...) end
function Log.debug(...) return log(2, 0, 'DD: ', ...) end

return Log
