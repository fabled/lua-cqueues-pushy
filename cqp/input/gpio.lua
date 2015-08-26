local cqueues = require 'cqueues'
local push = require 'cqp.push'
local pfd = require 'cqp.posixfd'

local M = {}

function M.input(id)
	local p = push.property(nil, ("GPIO %d - Input"):format(id))
	cqueues.running():wrap(function()
		local f = pfd.open(("/sys/class/gpio/gpio%d/value"):format(id), "p")
		while true do
			f:seek(0)
			p(tonumber(f:read(32)) == 1)
			cqueues.poll(f)
		end
		f:close()
	end)
	return p
end

return M
