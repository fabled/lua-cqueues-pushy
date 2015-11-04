--
-- Very simple HTTP server.
--
-- httpd.srv [bind-address [bind-port]]
--

local cqueues = require"cqueues"
local socket = require"cqueues.socket"
local errno = require"cqueues.errno"
local url = require"socket.url"

local M = {}

local http_errors = {
	[100] = "Continue",
	[200] = "OK",
	[201] = "Created",
	[202] = "Accepted",
	[203] = "Non-Authoritative Information",
	[204] = "No Content",
	[205] = "Reset Content",
	[300] = "Multiple Choices",
	[301] = "Moved Permanently",
	[302] = "Found",
	[303] = "See Other",
	[304] = "Not Modified",
	[307] = "Temporary Redirect",
	[308] = "Permanent Redirect",
	[400] = "Bad Request",
	[401] = "Unauthorized",
	[403] = "Forbidden",
	[404] = "Not Found",
	[405] = "Method Not Allowed",
	[406] = "Not Acceptable",
	[408] = "Request Timeout",
	[409] = "Conflict",
	[500] = "Internal Server Error",
	[501] = "Not Implemented",
	[505] = "HTTP Version Not Supported",
	[520] = "Unknown Error",
}

local function parseurl(u)
	local u = url.parse(u)
	local s = url.parse_path(u.path)
	local args = {}
	if s.query then
		for k,v in s.query:gmatch('([^&=?]-)=([^&=?]+)' ) do
			args[k] = url.unescape(v)
		end
	end
	return s, args
end

local function route_request(ctx, reply, uri, no_method)
	if no_method == nil then
		uri = uri[ctx.method]
		if uri == nil then return 405 end
	end

	local paths = ctx.paths
	for i = ctx.path_pos, #paths do
		local p = paths[i]
		if type(uri) ~= "table" then break end
		local node = uri[p]
		if node == nil then break end
		uri = node
		ctx.path_pos = i + 1
	end

	if type(uri) == "function" then
		return uri(ctx, reply)
	end

	return uri and 500 or 404
end

local function handle_connection(params, con)
	local _, ip, port = con:peername()

	con:setmode("tl", "tf")
	con:onerror(function(sock, method, error, level) return error end)

	local req, why = con:read("*l")
	if not req then
		print(("%s:%d: no request (%s)"):format(ip, port, why and errno.strerror(why) or "timeout"))
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

	local paths, args = parseurl(path)
	if method == "POST" and body and hdr["Content-Type"] == "application/x-www-form-urlencoded" then
		for key, val in body:gmatch("([^&=]+)=?([^&]+)") do
			args[key] = val
		end
	end

	local ctx = {
		ip = ip,
		port = port,
		method = method,
		path = path,
		paths = paths,
		headers = hdr,
		body = body,
		args = args,
		route = route_request,
		path_pos = 1,
	}
	local reply = {
		headers = {},
	}

	local code, body = ctx:route(reply, params.uri, true)
	code = code or 500
	con:write(("HTTP/1.1 %d %s\n"):format(code, reply.status_text or http_errors[code]))
	print(code, text)
	hdrs = reply.headers
	if hdrs then
		hdrs["Connection"] = "close"
		for hdr, val in pairs(hdrs) do
			con:write(hdr, ": ", val, "\n")
		end
	end
	con:write("\n")
	if body then con:write(body) end
	con:flush()
	con:shutdown("w")
	con:read(1)
	print(("%s:%d: disconnected"):format(ip, port))
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
