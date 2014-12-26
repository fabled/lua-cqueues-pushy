--
-- Very simple HTTP server.
--
-- httpd.srv [bind-address [bind-port]]
--

local cqueues = require"cqueues"
local socket = require"cqueues.socket"
local errno = require"cqueues.errno"

local M = {}

local function handle_connection(params, con)
	local _, ip, port = con:peername()

	print(("%s:%d: connected"):format(ip, port))

	local ok, why = pcall(function()
		con:setmode("tl", "tf")

		local get, why = con:read("*l")
		if not get then
			print(("%s:%d: no request (%s)"):format(ip, port, errno.strerror(why)))
			return
		end

		print(("%s:%d: %s"):format(ip, port, get))

		local hdr = {}

		for h in con:lines("*h") do
			local f, b = h:match("^([^:%s]+)%s*:%s*(.*)$")
			hdr[f] = b
		end

		con:read("*l") -- discard header/body break

		local path = get:match("^%w+%s+/?([^%s]+)") or "/dev/null"
		if not path then
			print(("%s:%d: no path specified"):format(ip, port))
			return
		end

		print(("%s:%d: path: %s"):format(ip, port, path))
		if params.uri[path] then
			local code, text, hdrs = params.uri[path]()
			con:write(("HTTP/1.1 %d %s\n"):format(code, text))
			print(code, text, hdrs)
			if hdrs then con:write(table.concat(hdrs, "\n"), "\n") end
			con:write("Connection: close\n\n")
		else
			con:write("HTTP/1.1 404 Not Found\n")
			con:write("Connection: close\n\n")
		end

		con:flush()
		con:shutdown("w")
		con:read(1)
		con:shutdown("r")
	end)

	if ok then
		print(("%s:%d: disconnected"):format(ip, port))
	else
		print(("%s:%d: %s"):format(ip, port, why))
	end

	con:close()
end

function M.new(loop, p)
	local srv = socket.listen(p.local_addr or "127.0.0.1", tonumber(p.port or 8000))
	loop:wrap(function()
		for con in srv:clients() do
			loop:wrap(function() handle_connection(p, con) end)
		end
	end)
end

return M
