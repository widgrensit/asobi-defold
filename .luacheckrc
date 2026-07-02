std = "lua54"
max_line_length = 120

-- Callback signatures (Defold websocket/http handlers, test stubs) routinely
-- receive positional args they do not use; unused locals are still reported.
unused_args = false

-- Defold engine globals available at runtime (subset the SDK relies on;
-- socket + websocket come from the defold-websocket / LuaSocket extensions).
read_globals = {
	"sys",
	"json",
	"http",
	"socket",
	"websocket",
	"hash",
	"msg",
	"go",
	"timer",
	"window",
	"sound",
	"crash",
	"html5",
	"sys",
}

-- The pure-Lua unit tests stub Defold globals via _G before requiring the SDK.
files["tests/"] = {
	globals = { "websocket", "http", "hash", "json", "socket" },
}
