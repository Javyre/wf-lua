M = {}

function M.Set(initial)
    local _data = {}
    if initial then for _, i in pairs(initial) do _data[i] = true end end

    return {
        _data = _data,
        add = function(self, elem) self._data[elem] = true end,
        remove = function(self, elem) self._data[elem] = nil end,
        has = function(self, elem) return self._data[elem] end,
        is_empty = function(self) return not next(self._data) end,
        for_each = function(self, fn)
            local i = 0
            for elem, _ in pairs(self._data) do
                fn(elem, i)
                i = i + 1
            end
        end
    }
end

function M.Hook(handlers)
    local _hooked = {}
    if handlers then for _, h in pairs(handlers) do _hooked[h] = true end end

    return {
        _hooked = _hooked,
        is_empty = function(self) return not next(self._hooked) end,
        hook = function(self, cb) self._hooked[cb] = true end,
        unhook = function(self, cb) self._hooked[cb] = nil end,
        call = function(self, ...)
            for h, _ in pairs(self._hooked) do h(...) end
        end
    }
end

return M
