-- Practically taken from:
-- https://raw.githubusercontent.com/sgraf812/push/
-- with coding style and minor updates by: Timo Teräs

local cqueues = require 'cqueues'
local recorders = { }

local Property = {}
Property.__index = Property

function Property:push_to(pushee)
	self.__tos[pushee] = pushee
	pushee(self.__value)
	return function() self.__tos[pushee] = nil end
end

function Property:peek()
	return self.__value
end

function Property:writeproxy(proxy)
	return setmetatable({ }, {
		__tostring = function(t)
			return "(proxied) " .. tostring(self)
		end,
		__index = self,
		__call = function(t, nv)
			if nv ~= nil then
				return self(proxy(nv))
			else
				return self()
			end
		end
	})
end

function Property:__tostring()
	return "Property " .. self.name .. ": " .. tostring(self.__value)
end

function Property:__call(nv)
	if nv ~= nil and nv ~= self.__value then
		local ov = self.__value
		self.__value = nv
		for p in pairs(self.__tos) do p(nv, ov) end
	elseif nv == nil then
		for r in pairs(recorders) do r(self) end
	end
	return self.__value
end

function Property:forceupdate()
	local v = self.__value
	for p in pairs(self.__tos) do p(v, v) end
	return v
end

local P = { action={} }

function P.action.on(trigger, action)
	return function(val, oldval)
		if val == trigger and oldval ~= trigger then
			action()
		end
	end
end

function P.action.timed(action)
	local down_time = nil
	return function(val)
		local now = cqueues.monotime()
		if val == true then
			down_time = now
		elseif val == false then
			if down_time then action(now-down_time) end
			down_time = nil
		end
	end
end

function P.property(v, name)
	return setmetatable({
		__value = v,
		__tos = { },
		name = name or "<unnamed>",
	}, Property)
end

function P.record_pulls(f)
	local sources = { }
	local function rec(p)
		sources[p] = p
	end
	recorders[rec] = rec
	local status, res = pcall(f)
	recorders[rec] = nil
	if not status then
		return false, res
	else
		return sources, res
	end
end

function P.readonly(self)
	return self:writeproxy(function(nv)
		return error("attempted to set readonly property '" .. tostring(self) .. "' with value " .. tostring(nv))
	end)
end

function P.computed(reader, writer, name)
	local p = property(nil, name or "<unnamed>")
	p.__froms = { }

	local function update()
		if not p.__updating then
			p.__updating = true
			local newfroms, res = P.record_pulls(reader)
			if not newfroms then
				p.__updating = false
				error(res)
			end
			for f, remover in pairs(p.__froms) do
				if not newfroms[f] then
					p.__froms[f] = nil
					remover()
				end
			end
			for f in pairs(newfroms) do
				if not p.__froms[f] then
					p.__froms[f] = f:push_to(update)
				end
			end
			p(res)
			p.__updating = false
		end
	end

	update()

	if not writer then
		return P.readonly(p)
	else
		return p:writeproxy(function(nv)
			if p.__updating then return end

			p.__updating = true
			local status, res = pcall(writer, nv)
			p.__updating = false

			return status and res or error(res)
		end)
	end
end

return P
