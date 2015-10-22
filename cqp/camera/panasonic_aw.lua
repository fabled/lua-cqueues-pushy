local cqueues = require 'cqueues'
local condition = require 'cqueues.condition'
local push = require 'cqp.push'
local http = require 'cqp.http'

local PanasonicAW = {}
PanasonicAW.__index = PanasonicAW

local function limit(val, _min, _max)
	if val < _min then return _min end
	if val > _max then return _max end
	return val
end

local function scale(val)
	return limit(50+50*val, 0, 99)
end

function PanasonicAW:init(ip)
	self.__ip = ip
	self.__cmdold = {}
	self.__cmdqueue = nil
	self.__cmdcond = condition.new()
	self.__pan = 50
	self.__tilt = 50

	self.power = push.property(true, ("AW %s - Power"):format(self.__ip))
	self.tally = push.property(false, ("AW %s - Tally"):format(self.__ip))

	self.pan = push.property(0, ("AW %s - Pan"):format(self.__ip))
	self.tilt = push.property(0, ("AW %s - Tilt"):format(self.__ip))
	self.zoom = push.property(0, ("AW %s - Zoom"):format(self.__ip))

	self.power:push_to(function(val, oval) self:aw_ptz(true, "O", "%d", val and 1 or 0) end)
	self.tally:push_to(function(val, oval) print("Tally", val, oval) self:aw_ptz(true, "DA", "%d", val and 1 or 0) end)
	self.pan:push_to(function(val)  self.__pan  = scale(val) self:aw_ptz(false, "PTS", "%02d%02d", self.__pan, self.__tilt) end)
	self.tilt:push_to(function(val) self.__tilt = scale(val) self:aw_ptz(false, "PTS", "%02d%02d", self.__pan, self.__tilt) end)
	self.zoom:push_to(function(val) self.__zoom = scale(val) self:aw_ptz(false, "Z", "%02d", self.__zoom) end)
end

function PanasonicAW:aw_ptz(force, cmd, fmt, ...)
	local val = fmt:format(...)
	if force or self.__cmdold[cmd] ~= val then
		self.__cmdqueue = self.__cmdqueue or {}
		self.__cmdqueue[cmd] = val
		self.__cmdold[cmd] = val
		self.__cmdcond:signal(1)
	end
end

function PanasonicAW:goto_preset(no) self:aw_ptz(true, "R", "%02d", no-1) end
function PanasonicAW:save_preset(no) self:aw_ptz(true, "M", "%02d", no-1) end

function PanasonicAW:main()
	while true do
		local sleep = true
		for cmd, val in pairs(self.__cmdqueue) do
			local uri = ("/cgi-bin/aw_ptz?cmd=%%23%s%s&res=1"):format(cmd, val)
			local status = http.get(self.__ip, 80, uri)
			print("Posting", self.__ip, uri, status)
			if status == 200 and self.__cmdqueue[cmd] == val then
				-- ACK command from queue (unless we got new already)
				self.__cmdqueue[cmd] = nil
			elseif status == nil then
				-- HTTP failed, throttle resend
				cqueues.sleep(1.0)
			end

			sleep = false
			break
		end
		if sleep then self.__cmdcond:wait() end
	end
end

local M = {}

function M.new(ip)
	local o = setmetatable({}, PanasonicAW)
	o:init(ip)
	cqueues.running():wrap(function() o:main() end)
	return o
end

return M
