--
-- Very simple HTTP server.
--
-- httpd.srv [bind-address [bind-port]]
--

local cqueues = require"cqueues"
local socket = require"cqueues.socket"
local errno = require"cqueues.errno"
local url = require"socket.url"
local plstringx = require"pl.stringx"
local json = require"cjson.safe"

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
	[415] = "Unsupported Media Type",
	[422] = "Unprocessable Entity",
	[500] = "Internal Server Error",
	[501] = "Not Implemented",
	[505] = "HTTP Version Not Supported",
	[520] = "Unknown Error",
}

local function parseurl(u)
	local u = url.parse(u)
	local s = url.parse_path(u.path)
	local args = {}
	if u.query then
		for k,v in u.query:gmatch('([^&=?]-)=([^&=?]+)' ) do
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

	repeat
		con:settimeout(5.0)
		local req, why = con:read("*l")
		if not req then
			print(("%s:%d: no request (%s)"):format(ip, port, why and errno.strerror(why) or "client closed connection"))
			break
		end

		local method, path, version = req:match("^(%w+)%s+/?([^%s]+) HTTP/([%d.]+)")
		version = tonumber(version)
		if not path or not version then
			print(("%s:%d: no path/version specified"):format(ip, port))
			break
		end

		con:settimeout(15.0)
		local hdr = {}
		for h in con:lines("*h") do
			local f, b = h:match("^([^:%s]+)%s*:%s*(.*)$")
			hdr[f:lower()] = b
		end
		con:read("*l") -- discard header/body break

		local keep_alive = version >= 1.1
		for _, option in ipairs(plstringx.split(hdr["connection"] or "", "[ .]+")) do
			if option == "keep-alive" then keep_alive = true
			elseif option == "close" then keep_alive = false end
		end

		local body = nil
		if hdr["content-length"] then
			body = con:read(tonumber(hdr["content-length"]))
		end

		local paths, args = parseurl(path)
		if body then
			local content_type = (hdr["content-type"] or ""):match("^([^;]+)")
			if content_type == "application/x-www-form-urlencoded" then
				for key, val in body:gmatch("([^&=]+)=?([^&]+)") do
					args[key] = val
				end
			elseif content_type == "application/json" then
				args = json.decode(body)
			end
		end

		local code, reply = nil, { headers = {} }
		if version >= 0.9 and version < 2.0 then
			local ctx = {
				http_version = version,
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
			code, body = ctx:route(reply, params.uri, true)
		else
			code, body = 505, nil
		end

		code = code or 500
		if (code >= 100 and code <= 199) or code == 204 or code == 304 then body = nil
		else body = body or "" end

		local rhdrs = reply.headers
		if type(body) == "table" then
			body = json.encode(body)
			if body then
				rhdrs["Content-Type"] = "application/json"
			else
				code, body = 500, ""
			end
		end

		print(("%s:%d: %s %s: %3d (%d bytes)"):format(ip, port, method, path, code, body and #body or 0))

		con:write(("HTTP/1.1 %d %s\n"):format(code, reply.status_text or http_errors[code]))
		if version == 1.0 and keep_alive then rhdrs.Connection = "keep-alive"
		elseif version > 1.0 and not keep_alive then rhdrs.Connection = "close"
		else rhdrs.Connection = nil end
		if body then rhdrs["Content-Length"] = tostring(#body) end

		for hdr, val in pairs(rhdrs) do
			con:write(hdr, ": ", val, "\n")
		end
		con:write("\n")

		if body and method ~= "HEAD" then con:xwrite(body, "bn") end
		con:flush()
	until not keep_alive

	con:shutdown("w")
	con:read(1)
	print(("%s:%d: disconnected"):format(ip, port))
end

function M.new(p)
	local srv = socket.listen(p.local_addr or "127.0.0.1", tonumber(p.port or 8000))
	srv:onerror(function(sock, method, error, level) return error end)
	cqueues.running():wrap(function()
		for con in srv:clients() do
			cqueues.running():wrap(function()
				local ok, err = pcall(handle_connection, p, con)
				if not ok then print(err) end
				con:close()
			end)
		end
	end)
end

return M
