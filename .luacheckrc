-- asobi-defold luacheck config
std = "lua54"

-- Defold runtime symbols (available globally inside the engine; we stub
-- them in tests to load the SDK outside Defold).
globals = {
	"websocket",
	"json",
	"http",
	"hash",
	"sys",
	"timer",
	"factory",
	"go",
	"vmath",
	"msg",
	"socket",
	"gui",
	"render",
	"physics",
	"particlefx",
	"sound",
	"sprite",
	"label",
	"tilemap",
	"collectionfactory",
	"collectionproxy",
	"window",
	"html5",
	"iac",
	"iap",
	"push",
	"webview",
	"zlib",
	"crash",
	"profiler",
	"resource",
	"buffer",
	"image",
	"b2d",
}

-- Defold script lifecycle callbacks are declared as bare globals.
-- Examples intentionally show full callback signatures (self, data,
-- changed, etc.) so readers can see what's available - underscoring
-- them would teach a confusing pattern. Suppress the noise instead.
files["example/**/*.lua"] = {
	globals = {"init", "final", "update", "fixed_update", "on_message",
		"on_input", "on_reload"},
	ignore = {
		"212", -- unused argument (engine/callback signatures)
		"432", -- shadowing upvalue argument (per-callback `err`)
	},
}
files["smoke_tests/**/*.lua"] = {
	globals = {"init", "final", "update", "fixed_update", "on_message",
		"on_input", "on_reload"},
}

-- Tests stub Defold runtime modules; allow setting/mutating those globals.
files["tests/**/*.lua"] = {
	ignore = {"111", "112", "113"},
}
