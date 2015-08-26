-- Hitachi HD44780 LCD controller via a I2C PCF8574 port expander

local cqueues = require 'cqueues'
local condition = require 'cqueues.condition'
local i2c = require 'cqp.protocol.i2c'
local posix = require 'posix'

local LCD = {}
LCD.__index = LCD

local RS, RW, E, BACKLIGHT = 1, 2, 4, 8

function LCD:init(bus, id)
	self.__fd = posix.open(bus, posix.O_RDWR)
	self.__cond = condition.new()
	self.__output = nil
	self.__control = BACKLIGHT
	i2c.I2C_SLAVE(self.__fd, id)
end

function LCD:write_lcd(b, control)
	local datah = bit32.bor(self.__control, control or 0, bit32.band(b, 0xf0))
	local datal = bit32.bor(self.__control, control or 0, bit32.lshift(bit32.band(b, 0x0f), 4))
	posix.write(self.__fd,
		string.char(datah, E + datah, datah,
			    datal, E + datal, datal))
	cqueues.poll(0.000050)
end

function LCD:goto_xy(x, y)
	self:write_lcd(0x80 + bit32.band(0x7f, y*0x40+x))
end

function LCD:paint(output)
	-- Clear LCD
	self:write_lcd(0x01)
	cqueues.poll(0.002)

	-- Send updates to screen
	for y = 1, #output do
		local str = output[y]
		for x = 1, #str do
			self:goto_xy(x-1, y-1)
			self:write_lcd(str:sub(x,x):byte(), RS)
		end
	end
end

function LCD:main()
	-- Clear LCD
	self:write_lcd(0x01)
	cqueues.poll(0.002)
	-- Cursor & blink off
	self:write_lcd(0x08 + 0x04)

	local out = nil
	while true do
		out, self.__output = self.__output, nil
		if out ~= nil then self:paint(out) end
		if self.__output == nil then self.__cond:wait() end
	end
end

function LCD:output(...)
	self.__output = table.pack(...)
	self.__cond:signal()
end

local M = {}
M.DEFAULT_ID = 0x27

function M.new(bus, id)
	local o = setmetatable({}, LCD)
	o:init(bus, id or M.DEFAULT_ID)
	cqueues.running():wrap(function() o:main() end)
	return o
end

return M
