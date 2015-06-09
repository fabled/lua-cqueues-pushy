local signal = require 'cqueues.signal'
local posix = require 'posix'
local push = require 'cqp.push'

local all_processes = {}

-- Process object

local Process = { }
Process.__index = Process

function Process:run()
	if self.running() then return end
	local pid = posix.fork()
	print(pid, "Fork", self.command, table.unpack(self.arguments))
	if pid == -1 then
		return error("Fork failed")
	elseif pid == 0 then
		local nulfd = posix.open("/dev/null", posix.O_RDWR)
		posix.dup2(nulfd, 0)
		posix.dup2(nulfd, 1)
		posix.dup2(nulfd, 2)
		posix.close(nulfd)
		posix.execp(self.command, table.unpack(self.arguments))
		os.exit(0)
	else
		all_processes[pid] = self
		self.running(true)
		self.__pid = pid
	end
end

function Process:kill(signo)
	local pid = self.__pid
	if pid then posix.kill(pid, signo or 15) end
end

-- Manager object

local Manager = {}
Manager.__index = Manager

function Manager:main()
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
				all_processes[pid] = nil
				c.running(false)
			end
		end
	end
end

function Manager:create(cmd, ...)
	return setmetatable({
		command = cmd,
		arguments = table.pack(...),
		running = push.property(false, "Child running")
	}, Process)
end

-- Module interface

local M = {}
function M.manager(loop)
	local mgr = setmetatable({}, Manager)
	loop:wrap(function() mgr:main(loop) end)
	return mgr
end

return M
