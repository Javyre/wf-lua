pub usingnamespace @cImport({
    @cInclude("unistd.h");
    @cInclude("stdlib.h");

    @cInclude("lua.h");
    @cInclude("lauxlib.h");
    @cInclude("lualib.h");
    @cInclude("luajit.h");

    @cInclude("wayland-server-core.h");

    @cInclude("wf.h");
    @cInclude("wf-lua.h");
});
