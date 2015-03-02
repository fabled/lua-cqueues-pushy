local cq = require 'cqueues'
local struct = require 'struct'
local push = require 'tvsc.push'
local pfd = require 'tvsc.posixfd'

local XKeys = {}
XKeys.__index = XKeys

local devices = {
	[0x0429] = { name="XK-12 Joy", key_offs=3, key_cnt=4,  joy_offs=7,  ts_offs=13, redled_offs=32 },
	[0x045d] = { name="XK-68 Joy", key_offs=3, key_cnt=10, joy_offs=15, ts_offs=19, redled_offs=80 },
}

local function map_led_value(val)
	if val == 2 then return 2 end
	return val and 1 or 0
end

function XKeys:init(hidrawbase)
	self.__devname = ("/dev/hidraw%d"):format(hidrawbase)
	self.__devname2 = ("/dev/hidraw%d"):format(hidrawbase+2)
	self.__keys = {}
	self.joystick = {
		x = push.property(0, "XKeys X-axis"),
		y = push.property(0, "XKeys Y-axis"),
		z = push.property(0, "XKeys Z-axis"),
	}
	self.green_led = push.property(true, "XKeys Green Led")
	self.green_led:push_to(function(val) if self.__devdata then self:send(179, 6, map_led_value(val)) end end)
	self.red_led = push.property(false, "XKeys Red Led")
	self.red_led:push_to(function(val) if self.__devdata then self:send(179, 7, map_led_value(val)) end end)
	self.key = function(ndx)
		local k = self.__keys[ndx]
		if k then return k end
		k = {
			blue_led = push.property(false, ("XKeys Button #%d Blue Led"):format(ndx)),
			red_led = push.property(false, ("XKeys Button #%d Red Led"):format(ndx)),
			state = push.property(false, ("XKeys Button #%d State"):format(ndx)),
		}
		k.blue_led:push_to(function(val) if self.__devdata then self:send(181, ndx, map_led_value(val)) end end)
		k.red_led:push_to(function(val) if self.__devdata then self:send(181, ndx+self.__devdata.redled_offs, map_led_value(val)) end end)
		self.__keys[ndx] = k
		return k
	end
end

function XKeys:send(...)
	local msg = table.pack(0, ...)
	for i = msg.n+1, 36 do msg[i] = 0 end
	local data = string.char(table.unpack(msg))
	if self.__pfd then self.__pfd:write(data) end
end

function XKeys:read_events()
	local res, old_ts, old_z, timeout

	-- Detect device
	self:send(214)

	while true do
		local ret = cq.poll(self.__pfd, self.__pfd2, timeout)
		if ret == nil then break end

		if type(ret) == "number" then
			timeout = nil
			self:send(177)
		elseif ret == self.__pfd2 then
			self.__pfd2:read(32)
		elseif ret == self.__pfd then
			timeout = 60.0
			res = self.__pfd:read(32)
			if res == nil then break end

			if res:byte(2, 2) == 214 then
				local pid = struct.unpack("<I2", res, 12)
				self.__devdata = devices[pid]
				print(("Detect X-Keys PID %04x, model %s"):format(pid, self.__devdata.name or "unknown"))

				self:send(182, 0, 0)		-- Turn off LEDs bank 0
				self:send(182, 1, 0)		-- Turn off LEDs bank 1
				self:send(187, 255, 255)	-- Full backlighting intensity
				self:send(180, 64)		-- LED blink speed (~ 1 sec)

				-- And synchronize led states
				self.green_led:forceupdate()
				self.red_led:forceupdate()
				for _, key in pairs(self.__keys) do
					key.blue_led:forceupdate()
					key.red_led:forceupdate()
				end

				-- Request status report
				self:send(177)
			elseif self.__devdata then
				local devdata = self.__devdata
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

					diff_z = old_z and struct.unpack("b", struct.pack("b", 0x100 + z - old_z)) or 0
					old_z = z

					diff_z = diff_z * 200 / diff_ts / 32.0
					diff_z = 0.2 * diff_z + 0.8 * self.joystick.z() or 0
					if diff_z < 0.1 and diff_z > -0.1 then
						diff_z = 0
					else
						timeout = 0.08
					end

					--print(diff_ts, x, y, z, old_z, diff_z)
					self.joystick.x( x / 128.0)
					self.joystick.y(-y / 128.0)
					self.joystick.z(diff_z)
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
		self.__pfd2 = pfd.open(self.__devname2, "rw")
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

local M = {
	Led = { Off = false, On = true, Blink = 2 },
}
function M.new(loop, hidrawbase)
	local o = setmetatable({}, XKeys)
	o:init(hidrawbase)
	loop:wrap(function() o:main(loop) end)
	return o
end

return M
