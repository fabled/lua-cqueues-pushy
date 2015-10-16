local ldbus = require 'ldbus'
local cqueues = require 'cqueues'
local condition = require 'cqueues.condition'

local M = {}
local BUS = {}
BUS.__index = BUS
local PROXY = {}
PROXY.__index = PROXY

function PROXY:request(interface, method, timeout)
	return self.bus:request(self.service, self.path, interface, method, timeout or self.timeout)
end

function BUS:get_proxy(service, path, timeout)
	return setmetatable({bus=self,service=service,path=path,timeout=timeout}, PROXY)
end

function BUS:request(service, path, interface, method, timeout)
	local args
	if type(service) ~= "table" then
		args = {
			service = service,
			path = path,
			interface = interface,
			method = method,
			timeout = timeout
		}
	else
		args = service
	end

	collectgarbage()

	local msg = ldbus.message.new_method_call(args.service, args.path, args.interface, args.method)
	if msg == nil then return nil, "Out of memory" end

	local event = condition.new()
	local pending = self.__bus:send_with_reply(msg, args.timeout or 1.0)
	pending:set_notify(function() event:signal() end)
	event:wait()

	local reply = pending:steal_reply()
	if reply == nil then return nil, "Timeout" end

	local t = reply:get_type()
	if t ~= "method_return" then
		return nil, reply:get_error_name()
	end

	local msg = { }
	local iter = reply:iter_init()
	if iter then
		repeat
			table.insert(msg, iter:get_basic())
		until not iter:next()
	end
	print("Result", method, table.unpack(msg))
	return table.unpack(msg)
end

function M.get_bus(bus_name)
	local bus = ldbus.bus.get(bus_name or "session")
	local obj = {__bus=bus}

	local disp = condition.new()
	cqueues.running():wrap(function()
		while true do
			repeat until bus:dispatch() ~= "data_remains"
			disp:wait()
		end
	end)

	function obj.dispatch_changed()
		disp:signal()
	end

	bus:set_dispatch_status_function(obj.dispatch_changed)

	local timeouts = {}

	function obj.timeout_add(t)
		--print("Adding timeout", t)
		local cond = condition.new()
		timeouts[t] = cond
		cqueues.running():wrap(function()
			while timeouts[t] == cond do
				local n = t:get_enabled() and t:get_interval() or nil
				--print(t, "polling", n)
				if cqueues.poll(cond, n) ~= cond then
					t:handle()
				end
			end
			--print(t, "exit")
		end)
	end
	function obj.timeout_del(t)
		--print("Removing timeout", t)
		local to = timeouts[t]
		to:signal()
		timeouts[t] = nil
	end
	function obj.timeout_mod(t)
		--print("Toggle timeout", t)
		timeouts[t]:signal()
	end

	local watchers = {}
	function obj.watch_add(w)
		local cond = condition.new()
		watchers[w] = cond
		cqueues.running():wrap(function()
			local fd = w:get_unix_fd()
			local fdobj = { pollfd = fd }
			while watchers[w] == cond do
				local n, flags = nil, 0
				if w:get_enabled() then
					flags = w:get_flags()
					fdobj.events = (bit32.band(flags, ldbus.watch.READABLE) ~= 0 and "r" or "")..
						       (bit32.band(flags, ldbus.watch.WRITABLE) ~= 0 and "w" or "")
					n = fdobj
				end
				--print(w, "polling", n and fd or nil, n and fdobj.events or nil)
				if cqueues.poll(cond, n) ~= cond then
					--print(w, "event", fd)
					w:handle(flags)
				end
			end
			cqueues.running():cancel(fd)
			--print(w, "exit")
		end)
	end
	function obj.watch_del(w)
		local wc = watchers[w]
		watchers[w] = nil
		wc:signal()
	end
	function obj.watch_mod(w)
		watchers[w]:signal()
	end

	bus:set_timeout_functions(obj.timeout_add, obj.timeout_del, obj.timeout_mod)
	bus:set_watch_functions(obj.watch_add, obj.watch_del, obj.watch_mod)

	return setmetatable(obj, BUS)
end

return M
