pub usingnamespace @cImport({
    @cInclude("unistd.h");
    @cInclude("stdlib.h");

    @cInclude("lua.h");
    @cInclude("lauxlib.h");
    @cInclude("lualib.h");
    @cInclude("luajit.h");

    @cInclude("xkbcommon/xkbcommon.h");
    @cInclude("wlr/types/wlr_keyboard.h");
    @cInclude("wlr/types/wlr_seat.h");
    @cInclude("wayland-server-core.h");

    @cInclude("wf.h");
    @cInclude("wf-lua.h");
});
