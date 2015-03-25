local socket = require 'cqueues.socket'
local M = {}

function M.get(ip, port, uri, cookies)
	return pcall(function()
		local s = socket.connect{
			host = ip,
			port = port,
			nodelay = true,
		}

		if s:connect(1.0) == nil then
			s:close()
			return nil
		end

		s:write(("GET %s HTTP/1.1\nHost: %s\nConnection: Close\n\n"):format(uri, ip))
		s:flush()

		local stat = s:read("*l")
		local http, status, msg = stat:match("([^ ]*) (%d+) (.*)")
		--print("!", status)
		for hdr in s:lines("*h") do
			--print("|", hdr)
		end
		s:read("*l")
		for line in s:lines("*L") do
			--print("+", line)
		end
		s:close()
		return tonumber(status, 10)
	end)
end

return M
