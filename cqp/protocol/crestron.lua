local cqueues = require 'cqueues'
local socket = require 'cqueues.socket'
local errno = require 'cqueues.errno'
local struct = require 'struct'
local push = require 'cqp.push'

local CIP = { }
CIP.__index = CIP

function CIP:init(ip)
	self.__ip = ip
	self.__ipid = 3
	self.__connected = false
	self.power = push.property(nil, "RoomView Power")
	self.ack = push.property(false, "RoomView Command ack")
	self.power:push_to(function(val)
		-- power on  05 00 06 00 00 03 00 04 00
		-- power off 05 00 06 00 00 03 00 05 00
		self:digital_pulse(val and 0x0004 or 0x0005)
	end)
end

function CIP:send(msg, ...)
	local payload = string.char(...)
	-- print(("XMIT 0x%02x, len: %d, data:%s"):format(msg, #payload, payload:gsub(".", function(s) return (" %02x"):format(s:byte(1)) end)))
	self.__sock:write(struct.pack(">i1i2", msg, #payload) .. payload)
end

function CIP:digital_control(id, on)
	self:send(0x05, 0x00, 0x00, 0x03, 0x00, bit32.band(id, 0xff), bit32.bor(on and 0x00 or 0x80, bit32.rshift(bit32.band(id, 0xff00), 8)))
end

function CIP:digital_pulse(id)
	if not self.__connected then return end
	self:digital_control(id, true)
	cqueues.poll(1.0)
	self:digital_control(id, false)
end

function CIP:handle_02(msg)
	-- IP ID Reply
	if msg == string.char(0xff, 0xff, 0x02) then
		-- IP ID does not exists. Potentially booting up.
	elseif #msg == 4 then
		-- IP ID registration successful
		self.__connected = true
		-- Send update request
		self:send(0x05, 0x00, 0x00, 0x02, 0x03, 0x00)
	end
end

function CIP:handle_05(msg)
	-- Data update
	if msg:byte(4) == 0x00 then
		-- Digital
		local id = struct.unpack("<i2", msg, 5)
		print(("  Digital %d: %s"):format(bit32.band(id, 0x7fff), bit32.band(id, 0x8000) == 0 and "true" or "false"))
		if id == 2 then
			self.ack(true)
			self.ack(false)
		end
	elseif msg:byte(4) == 0x14 then
		-- Analog
		local id, val = struct.unpack(">i2<i2", msg, 5)
		print(("  Analog %d: %d"):format(id, val))
	elseif msg:byte(4) == 0x15 then
		-- Serial (string)
		local id = struct.unpack("<i2", msg, 6)
		local val = msg:sub(8, -1)
		print(("  Serial %d: %s"):format(id, val))
	end
end

function CIP:handle_0f(msg)
	-- Processor response
	if msg == string.char(0x02) then
		-- IP ID Register request
		self:send(0x01, 0x7f, 0x00, 0x00, 0x01, 0x00, self.__ipid, 0x40)
	end
end

function CIP:recv()
	local hdr, err = self.__sock:read(3)
	if not hdr then
		if err == errno.ETIMEDOUT then
			if self.__alive == false then return false end
			self.__sock:clearerr()
			self.__alive = false
			-- Send Heartbeat (keep alive)
			self:send(0x0d, 0x00, 0x00)
			return true
		end
		return false
	end
	self.__alive = true

	local msg, len = struct.unpack(">i1i2", hdr)
	local payload = self.__sock:read(len)
	if not payload then return false end

	-- print(("RECV 0x%02x, len: %d, data:%s"):format(msg, len, payload:gsub(".", function(s) return (" %02x"):format(s:byte(1)) end)))

	local handler = self[("handle_%02x"):format(msg)]
	if handler then handler(self, payload) end

	return true
end

function CIP:main()
	while true do
		local status, ret

		self.__sock = socket.connect{host=self.__ip, port=41794, type=socket.SOCK_STREAM, nodelay=true}
		self.__sock:setmode("bn", "bn")
		self.__sock:onerror(function(sock, method, error, level) return error end)
		self.__sock:settimeout(5.0)
		repeat
			status, ret = pcall(self.recv, self)
		until not (status and ret)
		self.__sock:close()

		cqueues.sleep(5.0)
	end
end

local M = {}

function M.new(ip)
	local o = setmetatable({}, CIP)
	o:init(ip)
	cqueues.running():wrap(function() o:main() end)
	return o
end

return M
