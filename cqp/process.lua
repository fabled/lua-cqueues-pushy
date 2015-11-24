local cqueues = require 'cqueues'
local condition = require 'cqueues.condition'
local signal = require 'cqueues.signal'
local posix = require 'posix'
local posixfd = require 'cqp.posixfd'
local push = require 'cqp.push'

local all_processes = nil
local nulfd = posix.open("/dev/null", posix.O_RDWR)

local function spawn(info, ...)
	local pid = posix.fork()
	print(pid, "Fork", ...)
	if pid == -1 then
		return error("Fork failed")
	elseif pid == 0 then
		info = info or {}
		posix.dup2(info.stdin or nulfd, 0)
		posix.dup2(info.stdout or nulfd, 1)
		posix.dup2(info.stderr or nulfd, 2)
		posix.execp(...)
		os.exit(0)
	end
	return pid
end

-- Async Process object

local Async = {}
Async.__index = Async

function Async:kill(signo)
	local pid = self.__pid
	if pid then posix.kill(pid, signo or 15) end
end

function Async:wait()
	self.__cond:wait()
	return self.__status
end

-- Process object

local Process = { }
Process.__index = Process

function Process:run()
	if self.running() then return end
	local pid = spawn(nil, self.command, table.unpack(self.arguments))
	all_processes[pid] = self
	self.running(true)
	self.__pid = pid
end

function Process:kill(signo)
	local pid = self.__pid
	if pid then posix.kill(pid, signo or 15) end
end

-- Module interface

local function grim_reaper()
	signal.block(signal.SIGCHLD)
	local s = signal.listen(signal.SIGCHLD)
	while true do
		s:wait()
		while true do
			local pid, reason, exit_status = posix.wait(-1, posix.WNOHANG)
			if pid == nil or pid == 0 then break end

			local c = all_processes[pid]
			print(pid, "Exited", reason, exit_status, c)
			if c then
				c.__pid = nil
				c.__status = exit_status
				all_processes[pid] = nil
				if c.running then
					c.running(false)
				end
				if c.__cond then
					c.__cond:signal()
				end
				if c.respawn then
					cqueues.running():wrap(function()
						cqueues.poll(1.0)
						c:run()
					end)
				end
			end
		end
	end
end

local M = {}
function M.init()
	if not all_processes then
		all_processes = {}
		cqueues.running():wrap(grim_reaper)
	end
end

function M.create(opts, ...)
	M.init()
	if type(opts) == "string" then
		opts = { command = opts, arguments = { ... } }
	end
	return setmetatable({
		command = opts.command,
		arguments = opts.arguments or {},
		respawn = opts.respawn or false,
		running = push.property(false, "Child running")
	}, Process)
end

function M.spawn(...)
	M.init()
	local obj = setmetatable({
		__cond = condition.new(),
		__pid = spawn(nil, ...),
	}, Async)
	all_processes[obj.__pid] = obj
	return obj
end

function M.popen(...)
	M.init()
	local rfd, wfd = posix.pipe()
	posix.fcntl(rfd, posix.F_SETFD, posix.FD_CLOEXEC)
	posix.fcntl(rfd, posix.F_SETFL, posix.O_NONBLOCK)
	local obj = setmetatable({
		__cond = condition.new(),
		__pid = spawn({stdout=wfd}, ...),
	}, Async)
	posix.close(wfd)
	all_processes[obj.__pid] = obj
	return posixfd.openfd(rfd, "r")
end

function M.popenw(...)
	M.init()
	local rfd, wfd = posix.pipe()
	posix.fcntl(rfd, posix.F_SETFD, posix.FD_CLOEXEC)
	posix.fcntl(rfd, posix.F_SETFL, posix.O_NONBLOCK)
	local obj = setmetatable({
		__cond = condition.new(),
		__pid = spawn({stdin=rfd}, ...),
	}, Async)
	posix.close(rfd)
	all_processes[obj.__pid] = obj
	return posixfd.openfd(wfd, "w")
end

function M.run(...)
	return M.spawn(...):wait()
end

function M.killall(signo)
	for pid, obj in pairs(all_processes) do
		posix.kill(pid, signo or 15)
	end
end

return M
