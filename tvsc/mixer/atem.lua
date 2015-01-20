local cqueues = require 'cqueues'
local socket = require 'cqueues.socket'
local struct = require 'struct'

local push = require 'tvsc.push'
local httpd = require 'tvsc.httpd'

--- ATEM Stuff
local AtemMixer = {
	CMD_ACK		= 0x8000,
	CMD_RESEND	= 0x2000,
	CMD_HELLO	= 0x1000,
	CMD_ACKREQ	= 0x0800,
	CMD_LENGTHMASK	= 0x07ff,
}
AtemMixer.__index = AtemMixer

function AtemMixer:init(ip)
	self.__ip = ip
	self.__sock = socket.connect{host=ip, port=9910, type=socket.SOCK_DGRAM}
	self.__sock:setmode("bn", "bn")
	self.__channels = {}
	self.__connected = false
	self.online = push.property(0, ("Atem %s - Online"):format(self.__ip))
	self.preview = push.property(0, ("Atem %s - Preview Channel"):format(self.__ip))
	self.program = push.property(0, ("Atem %s - Program Channel"):format(self.__ip))
	self.fade_to_black_enabled = push.property(0, ("Atem %s - FTB Enabled"):format(self.__ip))
	self.channel = function(ndx)
		print(self, self.__channels, ndx)
		local k = self.__channels[ndx]
		if k then return k end
		k = {
			preview_tally = push.property(false, ("Atem %s - Channel #%d - Preview Tally"):format(self.__ip, ndx)),
			program_tally = push.property(false, ("Atem %s - Channel #%d - Program Tally"):format(self.__ip, ndx)),
		}
		self.__channels[ndx] = k
		return k
	end
end


function AtemMixer:send(flags, payload, ack_id)
	--print("sending to", self.__ip, self.__connected)
	if not self.__connected then return end
	self.__sock:write(struct.pack(">HHHHHH", bit32.bor(6*2 + #payload, flags), self.__atem_uid, ack_id or 0, 0, 0, self.__packet_id) .. payload)
	if bit32.band(flags, AtemMixer.CMD_ACK) == 0 then
		self.__packet_id = self.__packet_id + 1
	end
end

function AtemMixer:sendCmd(cmd, data)
	data = data or ""
	local pkt = struct.pack(">HHc4", 8+#data, 0, cmd)..data
	self:send(AtemMixer.CMD_ACKREQ, pkt)
end

function AtemMixer:do_auto_dsk(id)
	self:sendCmd("DDsA", struct.pack(">i1i1i2", id, 0, 0))
end

function AtemMixer:do_cut()
	self:sendCmd("DCut", struct.pack(">i4", 0))
end

function AtemMixer:do_auto()
	self:sendCmd("DAut", struct.pack(">i4", 0))
end

function AtemMixer:do_fade_to_black()
	self:sendCmd("FtbA", struct.pack(">i1i1i2", 0, 2, 0))
end

function AtemMixer:set_preview(ndx)
	print("set preview", ndx)
	self:sendCmd("CPvI", struct.pack(">i2i2", 0, ndx))
end

function AtemMixer:set_program(ndx)
	self:sendCmd("CPgI", struct.pack(">i2i2", 0, ndx))
end

function AtemMixer:onPrvI(data)
	local _, ndx = struct.unpack(">HH", data)
	self.preview(ndx)
end

function AtemMixer:onPrgI(data)
	local _, ndx = struct.unpack(">HH", data)
	self.program(ndx)
end

function AtemMixer:onFtbS(data)
	local _, enabled, fading, framecount = struct.unpack("i1i1i1i1", data)
	self.fade_to_black_enabled(enabled == 1 or fading == 1)
end

function AtemMixer:onTlIn(data)
	local num = data:byte(2)
	for i = 1, num do
		local chan = self.__channels[i]
		if chan then
			local b, p = data:byte(i+2)
			chan.program_tally(bit32.band(b, 1) == 1)
			chan.preview_tally(bit32.band(b, 2) == 2)
		end
	end
end

function AtemMixer:recv()
	local pkt, err = self.__sock:read("*a")
	if err then
		-- print(("AtemMixer: disconnected %s"):format(self.__ip))
		self.__connected = false
		return false
	end
	if #pkt < 6 then return true end

	--print(("Got %d bytes from ATEM"):format(#pkt))
	local flags, uid, ack_id, _, _, packet_id = struct.unpack(">HHHHHH", pkt)
	local length = bit32.band(flags, AtemMixer.CMD_LENGTHMASK)

	self.__atem_uid = uid
	if bit32.band(flags, bit32.bor(AtemMixer.CMD_ACKREQ, AtemMixer.CMD_HELLO)) ~= 0 then
		self:send(AtemMixer.CMD_ACK, "", packet_id)
	end
	if bit32.band(flags, AtemMixer.CMD_HELLO) ~= 0 then
		self.__connected = true
		self.online(true)
		print(("AtemMixer: connected %s"):format(self.__ip))
		return true
	end

	-- handle payload
	local off = 12
	while off + 8 < #pkt do
		local len, _, type = struct.unpack(">HHc4", pkt, off+1)
		-- print(("  --> %s len %d"):format(type, len))
		local handler = "on"..type
		if self[handler] then self[handler](self, pkt:sub(off+1+8,off+len)) end
		off = off + len
	end

	return true
end

function AtemMixer:send_hello()
	self.__sock:settimeout(5)
	self.__sock:clearerr()
	self.__atem_uid = 0x1337
	self.__packet_id = 0
	self.__connected = true
	self:send(AtemMixer.CMD_HELLO, string.char(0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x00))
	self.__connected = false
end

function AtemMixer:main()
	while true do
		self:send_hello()
		while self:recv() do end

		-- Reset internal state to zeroes
		for _, ch in pairs(self.__channels) do
			ch.program_tally(false)
			ch.preview_tally(false)
		end
		self.preview(0)
		self.program(0)
		self.online(false)

		cqueues.sleep(5.0)
	end
end

local M = {}

function M.new(loop, ip)
	local o = setmetatable({}, AtemMixer)
	o:init(ip)
	loop:wrap(function() o:main() end)
	return o
end

return M
