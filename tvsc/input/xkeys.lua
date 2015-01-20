local cq = require 'cqueues'
local struct = require 'struct'
local push = require 'tvsc.push'
local pfd = require 'tvsc.posixfd'

local XKeys = {}
XKeys.__index = XKeys

local devices = {
	[0x0429] = { name="XK-12 Joy", key_offs=3, key_cnt=4,  joy_offs=7,  ts_offs=13 },
	[0x045d] = { name="XK-68 Joy", key_offs=3, key_cnt=10, joy_offs=15, ts_offs=19 },
}

function XKeys:init(hidrawbase)
	self.__devname = ("/dev/hidraw%d"):format(hidrawbase)
	self.__devname2 = ("/dev/hidraw%d"):format(hidrawbase+2)
	self.__keys = {}
	self.joystick = {
		x = push.property(0, "XKeys X-axis"),
		y = push.property(0, "XKeys Y-axis"),
		z = push.property(0, "XKeys Z-axis"),
	}
end

function XKeys:key(ndx)
	local k = self.__keys[ndx]
	if k then return k end
	k = {
		blue_led = push.property(false, ("XKeys Button #%d Blue Led"):format(ndx)),
		red_led = push.property(false, ("XKeys Button #%d Red Led"):format(ndx)),
		state = push.property(false, ("XKeys Button #%d State"):format(ndx)),
	}
	k.blue_led:push_to(function(val) self:send(181, ndx, val and 1 or 0) end)
	k.red_led:push_to(function(val) self:send(181, ndx+32, val and 1 or 0) end)
	self.__keys[ndx] = k
	return k
end

function XKeys:send(...)
	local msg = table.pack(0, ...)
	for i = msg.n+1, 36 do msg[i] = 0 end
	local data = string.char(table.unpack(msg))
	if self.__pfd then self.__pfd:write(data) end
end

function XKeys:read_events()
	local devdata, res, old_ts, old_z

	-- Detect device
	self:send(214)

	while true do
		local ret = cq.poll(self.__pfd, self.__pfd2)
		if ret == nil then break end

		if ret == self.__pfd2 then
			self.__pfd2:read(32)
		elseif ret == self.__pfd then
			res = self.__pfd:read(32)
			if res == nil then break end

			if res:byte(2, 2) == 214 then
				local pid = struct.unpack("<I2", res, 12)
				devdata = devices[pid] or {}
				--print(("Detect X-Keys PID %04x, model %s"):format(pid, devdata.name or "unknown"))

				-- Turn off all back lights
				self:send(182, 0, 0)
				self:send(182, 1, 0)

				-- And synchronize led states
				for _, key in pairs(self.__keys) do
					key.blue_led:forceupdate()
					key.red_led:forceupdate()
				end

				-- Request status report
				self:send(177)
			elseif devdata then
				for i = 0, devdata.key_cnt do
					local byte = struct.unpack("B", res, devdata.key_offs+i)
					for j = 0, 7 do
						local p = self.__keys[i*8+j]
						if p then p.state(bit32.extract(byte, j) == 1) end
					end
				end

				local new_ts = struct.unpack(">I4", res, devdata.ts_offs)
				diff_ts = old_ts and bit32.band(new_ts - old_ts + 0x100000000, 0xffffffff)
				old_ts = new_ts

				if devdata.joy_offs and diff_ts then
					local x, y, z, diff_z = struct.unpack(">bbB", res, devdata.joy_offs)

					diff_z = old_z and struct.unpack("b", struct.pack("b", 0x100 + z - old_z)) * 200 / diff_ts
					old_z = z

					--print(diff_ts, x, y, z, old_z, diff_z)
					self.joystick.x( x / 128.0)
					self.joystick.y(-y / 128.0)
					if diff_z then self.joystick.z(diff_z / 64.0) end
				end

			end
		end
	end

	-- Reset input state to zero
	self.joystick.x(0)
	self.joystick.y(0)
	self.joystick.z(0)
	for _, key in pairs(self.__keys) do
		key.state(false)
	end
end

function XKeys:main(loop)
	while true do
		self.__pfd = pfd.open(self.__devname, "rw")
		self.__pfd2 = pfd.open(self.__devname2, "r")
		if self.__pfd then
			self:read_events()
			self.__pfd:close()
			self.__pfd2:close()
			self.__pfd = nil
			self.__pfd2 = nil
		end
		cq.sleep(2)
	end
end

local M = {}
function M.new(loop, hidrawbase)
	local o = setmetatable({}, XKeys)
	o:init(hidrawbase)
	loop:wrap(function() o:main(loop) end)
	return o
end

return M
