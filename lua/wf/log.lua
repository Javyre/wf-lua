local ffi = require 'ffi'

local Log = {}

local function to_strings(list)
    for i, a in ipairs(list) do list[i] = tostring(a) end
    return list
end

local function log(lvl, ...)
    ffi.C.wflua_log(lvl, table.concat(to_strings({...}), ' '))
end

function Log.err(...) return log(ffi.C.WFLUA_LOGLVL_ERR,  ...) end
function Log.warn(...) return log(ffi.C.WFLUA_LOGLVL_WARN, ...) end
function Log.debug(...) return log(ffi.C.WFLUA_LOGLVL_DEBUG, ...) end

return Log
