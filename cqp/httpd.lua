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

	local ok, why = pcall(function()
		con:setmode("tl", "tf")
		con:onerror(function(sock, method, error, level) return error end)

		local req, why = con:read("*l")
		if not req then
			print(("%s:%d: no request (%s)"):format(ip, port, errno.strerror(why)))
			return
		end

		local hdr = {}
		for h in con:lines("*h") do
			local f, b = h:match("^([^:%s]+)%s*:%s*(.*)$")
			hdr[f] = b
		end

		con:read("*l") -- discard header/body break
		local method, path = req:match("^(%w+)%s+/?([^%s]+)")
		print(("%s:%d: method: %s, path: %s"):format(ip, port, method, path))
		if not path then
			print(("%s:%d: no path specified"):format(ip, port))
			return
		end

		local body = nil
		if hdr["Content-Length"] then
			body = con:read(tonumber(hdr["Content-Length"]))
		end

		if params.uri[path] then
			local args = {}
			if method == "POST" and body then
				for key, val in body:gmatch("([^&=]+)=?([^&]+)") do
					args[key] = val
				end
			end

			local code, text, hdrs = params.uri[path](hdr, args)
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

function M.new(p)
	local srv = socket.listen(p.local_addr or "127.0.0.1", tonumber(p.port or 8000))
	srv:onerror(function(sock, method, error, level) return error end)
	cqueues.running():wrap(function()
		for con in srv:clients() do
			cqueues.running():wrap(function() handle_connection(p, con) end)
		end
	end)
end

return M
