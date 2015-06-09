local cqueues = require 'cqueues'
local push = require 'cqp.push'
local pfd = require 'cqp.posixfd'

local M = {}

function M.input(id)
	local p = push.property(nil, ("GPIO %d - Input"):format(id))
	cqueues.running():wrap(function()
		local f = pfd.open(("/sys/class/gpio/gpio%d/value"):format(id), "r")
		while true do
			f:seek(0)
			p(tonumber(f:read(32)) == 1)
			-- FIXME: Should use interrupt driven GPIO when
			-- cqueues supports polling POLLPRI + POLLERR
			cqueues.poll(2.0)
		end
		f:close()
	end)
	return p
end

return M
