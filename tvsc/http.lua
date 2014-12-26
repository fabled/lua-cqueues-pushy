local socket = require 'cqueues.socket'
local M = {}

function M.get(ip, port, uri, cookies)
	return pcall(function()
		local s = socket.connect{
			host = ip,
			port = port,
			nodelay = true,
		}

		s:write(("GET %s HTTP/1.1\nHost: %s\nConnection: Close\n\n"):format(uri, ip))
		s:flush()

		local status = s:read("*l")
		--print("!", status)
		for hdr in s:lines("*h") do
			--print("|", hdr)
		end
		s:read("*l")
		for line in s:lines("*L") do
			--print("+", line)
		end
		s:close()
		return status
	end)
end

return M
