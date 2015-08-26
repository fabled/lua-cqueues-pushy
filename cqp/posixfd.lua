local cq = require 'cqueues'
local posix = require 'posix'

local File = {}
File.__index = File

function File:pollfd() return self.__fd end
function File:events() return self.__mode end
function File:timeout() return nil end

function File:seek(offs)  return posix.lseek(self.__fd, offs, posix.SEEK_SET) end
function File:read(bytes) return posix.read(self.__fd, bytes) end
function File:write(data) return posix.write(self.__fd, data) end

function File:close()
	if not self.__fd then return end
	cq.cancel(self.__fd)
	posix.close(self.__fd)
	self.__fd = nil
	self.__mode = nil
end

function File:__gc()
	self:close()
end

local M = {}

function M.openfd(fd, mode)
	return setmetatable({ __fd = fd, __mode = mode}, File)
end

local modemap = {
	["rw"] = posix.O_RDWR + posix.O_NONBLOCK,
	["r"]  = posix.O_RDONLY + posix.O_NONBLOCK,
	["w"]  = posix.O_WRONLY + posix.O_NONBLOCK,
	["p"]  = posix.O_RDONLY + posix.O_NONBLOCK,
}

function M.open(filename, mode)
	local fd = posix.open(filename, modemap[mode])
	if not fd then return nil end
	return M.openfd(fd, mode)
end

return M
