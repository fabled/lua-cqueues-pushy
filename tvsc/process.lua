local signal = require 'cqueues.signal'
local posix = require 'posix'
local push = require 'tvsc.push'

local all_processes = {}

local Process = { }
Process.__index = Process

function Process:run()
	if self.running() then return end
	local pid = posix.fork()
	print(pid, "Fork", self.command)
	if pid == -1 then
		return error("Fork failed")
	elseif pid == 0 then
		local nulfd = posix.open("/dev/null", posix.O_RDWR)
		posix.dup2(nulfd, 0)
		posix.dup2(nulfd, 1)
		posix.dup2(nulfd, 2)
		posix.close(nulfd)
		posix.execp(self.command)
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

local M = {}
function M.run(loop)
	loop:wrap(function()
		signal.block(signal.SIGCHLD)
		local s = signal.listen(signal.SIGCHLD)
		while true do
			s:wait()
			while true do
				local pid, reason, exit_status = posix.wait(-1)
				if not pid then break end
				local c = all_processes[pid]
				print(pid, "Exited", reason, exit_status, c)
				if c then
					c.running(false)
					c.__pid = nil
					all_processes[pid] = nil
				end
			end
		end
	end)
end

function M.create(cmd)
	return setmetatable({
		command = cmd,
		running = push.property(false, "Child running")
	}, Process)
end

return M
