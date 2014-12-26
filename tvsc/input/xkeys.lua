local cq = require 'cqueues'
local struct = require 'struct'
local push = require 'tvsc.push'
local pfd = require 'tvsc.posixfd'

local XKeys = {}
XKeys.__index = XKeys

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
	local old_res, res, timeout

	-- Turn off all back lights
	self:send(182, 0, 0)
	self:send(182, 1, 0)

	-- And synchronize led states
	for _, key in pairs(self.__keys) do
		print(key.blue_led, key.blue_led())
		key.blue_led:forceupdate()
		key.red_led:forceupdate()
	end

	-- Request status report
	self:send(177)

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

			-- buttons
			for i = 0, 3 do
				local byte = res:byte(3+i, 3+i)
				for j = 0, 7 do
					local p = self.__keys[i*8+j]
					if p then p.state(bit32.extract(byte, j) == 1) end
				end
			end

			-- axis values
			if old_res then
				local old_z, _, old_ts = struct.unpack(">BI3I4", old_res, 9)
				local x, y, new_z, _, new_ts = struct.unpack(">bbBI3I4", res, 7)
				diff_ts = struct.unpack("i4", struct.pack("i4", new_ts - old_ts + 0x100000000))
				z = struct.unpack("b", struct.pack("b", 0x100 + new_z - old_z)) * 200 / diff_ts
				if new_z ~= old_z then timeout = 0.4 end

				print(diff_ts, x, y, z, new_z, old_z)
				self.joystick.x( x / 128.0)
				self.joystick.y(-y / 128.0)
				self.joystick.z( z / 64.0)
			end

			old_res = res
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
