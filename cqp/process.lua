local cqueues = require 'cqueues'
local signal = require 'cqueues.signal'
local posix = require 'posix'
local push = require 'cqp.push'

local all_processes = nil

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
				all_processes[pid] = nil
				c.running(false)
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
function M.create(opts)
	if not all_processes then
		all_processes = {}
		cqueues.running():wrap(grim_reaper)
	end

	if type(opts) == "string" then
		opts = { command = opts }
	end

	return setmetatable({
		command = opts.command,
		arguments = opts.arguments or {},
		respawn = opts.respawn or false,
		running = push.property(false, "Child running")
	}, Process)
end

return M
