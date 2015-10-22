local cq = require 'cqueues'
local condition = require 'cqueues.condition'
local notify = require 'cqueues.notify'
local posix = require 'posix'
local struct = require 'struct'
local push = require 'cqp.push'
local pfd = require 'cqp.posixfd'

local function map_led_value(val)
	if val == 2 then return 2 end
	return val and 1 or 0
end

-- XKeys controller object

local XKeys = {}
XKeys.__index = XKeys

function XKeys:init()
	self.__users = 0
	self.__keys = {}
	self.joystick = {
		x = push.property(0, "XKeys X-axis"),
		y = push.property(0, "XKeys Y-axis"),
		z = push.property(0, "XKeys Z-axis relative"),
		z_abs = push.property(0, "XKeys Z-axis absolute"),
	}
	self.program_key = push.property(false, "XKeys Program Key")
	self.green_led = push.property(true, "XKeys Green Led")
	self.green_led:push_to(function(val) if self.__led_gree then self:__led_green(map_led_value(val)) end end)
	self.red_led = push.property(false, "XKeys Red Led")
	self.red_led:push_to(function(val) if self.__led_red then self:__led_red(map_led_value(val)) end end)
	self.key = function(ndx)
		local k = self.__keys[ndx]
		if k then return k end
		k = {
			blue_led = push.property(false, ("XKeys Button #%d Blue Led"):format(ndx)),
			red_led = push.property(false, ("XKeys Button #%d Red Led"):format(ndx)),
			state = push.property(false, ("XKeys Button #%d State"):format(ndx)),
		}
		k.red_led:push_to(function(val) if self.__keyled_red then self:__keyled_red(ndx, map_led_value(val)) end end)
		k.blue_led:push_to(function(val) if self.__keyled_blue then self:__keyled_blue(ndx, map_led_value(val)) end end)
		self.__keys[ndx] = k
		return k
	end
end

function XKeys:send(fd, ...)
	local msg = table.pack(...)
	for i = msg.n+1, 36 do msg[i] = 0 end
	local data = string.char(table.unpack(msg))
	fd:write(data)
end

function XKeys:sync_leds()
	self.green_led:forceupdate()
	self.red_led:forceupdate()
	for _, key in pairs(self.__keys) do
		key.blue_led:forceupdate()
		key.red_led:forceupdate()
	end
end

function XKeys:reset_state()
	self.joystick.x(0)
	self.joystick.y(0)
	self.joystick.z(0)
	self.joystick.z_abs(0)
	self.program_key(false)
	for _, key in pairs(self.__keys) do key.state(false) end
	self.__led_green = nil
	self.__led_red = nil
	self.__keyled_blue = nil
	self.__keyled_red = nil
end

function XKeys:main_xk(fd, devinfo)
	local old_ts, old_z, timeout

	self:send(fd, 0, 182, 0, 0)		-- Turn off LEDs bank 0
	self:send(fd, 0, 182, 1, 0)		-- Turn off LEDs bank 1
	self:send(fd, 0, 187, 255, 255)		-- Full backlighting intensity
	self:send(fd, 0, 180, 64)		-- LED blink speed (~ 1 sec)

	self.__led_green = function(self, val) self:send(fd, 0, 179, 6, val) end
	self.__led_red  = function(self, val) self:send(fd, 0, 179, 7, val) end
	self.__keyled_blue = function(self, ndx, val) self:send(fd, 0, 181, ndx, val) end
	self.__keyled_red = function(self, ndx, val) self:send(fd, 0, 181, ndx + devinfo.redled_offs, val) end
	self:sync_leds()

	while true do
		local res = cq.poll(fd, timeout)
		if res == nil then break end

		if type(res) == "number" then
			timeout = nil
			self:send(fd, 0, 177)
		elseif res == fd then
			res = fd:read(32)
			if res == nil then break end

			self.program_key(bit32.extract(struct.unpack("B", res, 2), 0) == 1)
			for i = 0, devinfo.key_cnt do
				local byte = struct.unpack("B", res, devinfo.key_offs+i)
				for j = 0, 7 do
					local p = self.__keys[i*8+j]
					if p then p.state(bit32.extract(byte, j) == 1) end
				end
			end

			local new_ts = struct.unpack(">I4", res, devinfo.ts_offs)
			diff_ts = old_ts and bit32.band(new_ts - old_ts + 0x100000000, 0xffffffff)
			old_ts = new_ts

			if devinfo.joy_offs and diff_ts then
				local x, y, z, diff_z = struct.unpack(">bbB", res, devinfo.joy_offs)

				diff_z = old_z and struct.unpack("b", struct.pack("b", 0x100 + z - old_z)) or 0
				old_z = z

				diff_z = diff_z * 200 / diff_ts / 32.0
				diff_z = 0.2 * diff_z + 0.8 * self.joystick.z() or 0
				if diff_z < 0.1 and diff_z > -0.1 then
					diff_z = 0
				else
					timeout = 0.08
				end

				-- print(diff_ts, x, y, z, old_z, diff_z)
				self.joystick.x( x / 128.0)
				self.joystick.y(-y / 128.0)
				self.joystick.z(diff_z)
				self.joystick.z_abs((z - 128.0) / 128.0)
			end

		end
	end
end

function XKeys:main_xks79(fd)
	local leds_changed = condition.new()
	local update_leds = true
	local backlights = 0

	self.__keyled_red = function(self, ndx, val)
		backlights = bit32.replace(backlights, val==0 and 0 or 1, ndx)
		update_leds = true
		leds_changed:signal()
	end
	self:sync_leds()

	while true do
		if update_leds then
			self:send(fd, 2, 187, 0, 0, 0, 0, bit32.rshift(backlights, 8), bit32.band(backlights, 255))
			update_leds = false
		end

		local res = cq.poll(fd, leds_changed)
		if res == nil then break end

		if res == fd then
			res = fd:read(32)
			if res == nil then break end
			for i = 0, 3 do
				local byte = struct.unpack("B", res, 2+i)
				for j = 0, 3 do
					local p = self.__keys[j*4+i]
					if p then p.state(bit32.extract(byte, j) == 1) end
				end
			end
		end
	end
end

function XKeys:main_extra(fd)
	while true do
		local res = cq.poll(fd)
		if res == nil then break end
		res = fd:read(32)
		if res == nil then break end
	end
end

-- Manager object

local XKeysManager = {}
XKeysManager.__index = XKeysManager

local function readvals(fn)
	local map = {}
	local f = io.open(fn, "r")
	if not f then return nil end
	for l in f:lines() do
		local k, v = l:match("([^=]*)=(.*)")
		map[k] = v
	end
	f:close()
	return map
end

function XKeysManager:map_xkeys(devname, sysfsinfo, devinfo)
	local phys = sysfsinfo.HID_PHYS or ""
	local physid, physinput = phys:match("([^/]+)/(.*)")

	if self.__phys[phys] then return end

	local xkeys = self.__phys[physid]
	if xkeys == nil then
		for v, xk in pairs(self.__units) do
			if xk.__users == 0 then
				xkeys = xk
				break
			end
		end
	end

	print("Binding", devname, physid, physinput, xkeys)

	if not xkeys then return end

	self.__phys[physid] = xkeys
	self.__phys[phys] = xkeys
	xkeys.__users = xkeys.__users + 1

	cq.running():wrap(function()
		local fd = pfd.open(("/dev/%s"):format(devname), "rw")
		local method = (physinput == "input0" and devinfo.main or XKeys.main_extra)
		method(xkeys, fd, devinfo)
		fd:close()
		xkeys:reset_state()
		xkeys.__users = xkeys.__users - 1
		if xkeys.__users == 0 then self.__phys[physid] = nil end
		self.__phys[phys] = nil

		print("Unbound", devname, physid, physinput, xkeys)
	end)
end

local xkeys_devices = {
	[0x02b5] = { name="XKS-79-USB-R Stick 16", main = XKeys.main_xks79 },
	[0x0429] = { name="XK-12 Joy", main = XKeys.main_xk, key_offs=3, key_cnt=4,  joy_offs=7,  ts_offs=13, redled_offs=32 },
	[0x045d] = { name="XK-68 Joy", main = XKeys.main_xk, key_offs=3, key_cnt=10, joy_offs=15, ts_offs=19, redled_offs=80 },
}

function XKeysManager:main()
	local ntfy = notify.opendir("/dev", notify.CREATE)
	repeat
		for _, fn in pairs(posix.glob("/dev/hidraw*") or {}) do
			local devname = fn:sub(6)
			local sysfsinfo = readvals(("/sys/class/hidraw/%s/device/uevent"):format(devname))
			local bus, vid, pid = ((sysfsinfo and sysfsinfo.HID_ID) or ""):match("(%x+):(%x+):(%x+)")
			if sysfsinfo and bus and vid and pid then
				if tonumber(bus, 16) == 3 and tonumber(vid, 16) == 0x05f3 then
					-- PI Engineering product
					local devinfo = xkeys_devices[tonumber(pid, 16)]
					if devinfo then self:map_xkeys(devname, sysfsinfo, devinfo) end
				end
			end
		end
	until ntfy:get() == nil
end

function XKeysManager:new()
	local o = setmetatable({}, XKeys)
	o:init()
	table.insert(self.__units, o)
	return o
end

-- Module interface

local M = {
	Led = { Off = false, On = true, Blink = 2 },
}
function M.manager(loop)
	if not M.__manager then
		loop = loop or cq.running()
		local mgr = setmetatable({ __units = {}, __phys = {} }, XKeysManager)
		loop:wrap(function() mgr:main() end)
		M.__manager = mgr
	end
	return M.__manager
end

function M.new()
	return M.manager():new()
end

return M
