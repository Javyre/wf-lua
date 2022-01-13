const std = @import("std");

const Builder = std.build.Builder;
const Step = std.build.Step;
const WriteFileStep = std.build.WriteFileStep;
const InstallDir = std.build.InstallDir;

pub fn build(b: *Builder) !void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const shared = .{
        // NOTE: Wayfire paths aren't read from pkg-config as the values set by
        // wayfire are all absolute paths and thus would not respect the
        // installation prefix.
        .wf_plugin_dir = "lib/wayfire",
        .wf_metadata_dir = "share/wayfire/metadata",
        .lua_runtime_dir = x: {
            const val = b.option(
                []const u8,
                "lua-runtime-dir",
                "The directory where lua files are installed." ++
                    " (relative to the install prefix)",
            ) orelse "share/wayfire/lua";
            break :x val;
        },

        .plugin_cpp_objects = b.addSystemCommand(&.{ "make", "plugin_objs" }),
    };

    const plugin = b.addSharedLibrary(
        "wf-lua",
        "src/wf-lua.zig",
        .unversioned,
    );
    {
        addLibs(b, shared, plugin);
        defineConstants(b, shared, plugin);

        plugin.setBuildMode(mode);
        plugin.override_dest_dir = InstallDir{ .Custom = shared.wf_plugin_dir };
        plugin.force_pic = true;
        plugin.rdynamic = true;

        const install_plugin = b.addInstallArtifact(plugin);

        install_plugin.step.dependOn(&plugin.step);

        b.getInstallStep().dependOn(&install_plugin.step);
    }

    b.installFile(
        "metadata/wf-lua.xml",
        b.fmt("{s}/wf-lua.xml", .{shared.wf_metadata_dir}),
    );

    const gen_lua_header = b.addWriteFile("wf_h.lua.out", gen_lua_header: {
        var src = std.ArrayList(u8).init(b.allocator);
        defer src.deinit();

        const writer = src.writer();
        try writer.writeAll(
            \\ local ffi = require 'ffi'
            \\ 
            \\ ffi.cdef [[
            \\
        );

        try writeAllFile(writer, b.fmt("{s}/src/wf.h", .{b.build_root}));
        try writeAllFile(writer, b.fmt("{s}/src/wf-lua.h", .{b.build_root}));

        try writer.writeAll(
            \\ ]]
        );
        break :gen_lua_header src.toOwnedSlice();
    });

    b.installFile("lua/wf.lua", b.fmt("{s}/wf.lua", .{shared.lua_runtime_dir}));
    b.installDirectory(.{
        .source_dir = "lua/wf",
        .install_dir = InstallDir{ .Custom = shared.lua_runtime_dir },
        .install_subdir = "wf",
    });
    installFromWriteFile(.{
        .builder = b,
        .wfs = gen_lua_header,
        .base_name = "wf_h.lua.out",
        .dest_rel_path = b.fmt("{s}/wf/wf_h.lua", .{shared.lua_runtime_dir}),
    });

    const wfmsg = b.addExecutable("wf-msg", "src/wf-msg.zig");
    wfmsg.addIncludeDir("src");
    wfmsg.install();

    var main_tests = b.addTest("src/wf-lua.zig");
    addLibs(b, shared, main_tests);
    defineConstants(b, shared, main_tests);
    main_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}

fn addLibs(b: *Builder, shared: anytype, step: *std.build.LibExeObjStep) void {
    inline for (.{ "src/wf.o", "src/wf-plugin.o" }) |source| {
        step.addObjectFile(
            b.fmt("{s}/cxx/" ++ source, .{b.cache_root}),
        );
    }
    step.step.dependOn(&shared.plugin_cpp_objects.step);

    step.addIncludeDir("src");
    // TODO: change to linkLibCpp when zig version is bumped
    step.linkSystemLibrary("c++");
    step.linkSystemLibrary("wayfire");
    step.linkSystemLibrary("luajit");
    step.linkSystemLibrary("xkbcommon");
}

fn defineConstants(
    b: *Builder,
    shared: anytype,
    step: *std.build.LibExeObjStep,
) void {
    step.defineCMacro("WLR_USE_UNSTABLE");
    step.defineCMacro("WAYFIRE_PLUGIN");
    step.addBuildOption(
        []const u8,
        "LUA_RUNTIME",
        b.fmt("{s}/{s}", .{ b.install_prefix, shared.lua_runtime_dir }),
    );
}

const InstallFromWriteFileOpts = struct {
    builder: *Builder,
    wfs: *WriteFileStep,
    base_name: []const u8,
    dest_rel_path: []const u8,
};

fn installFromWriteFile(opts: InstallFromWriteFileOpts) void {
    const step = InstallFromWriteFileStep.create(opts);
    step.step.dependOn(&opts.wfs.step);
    opts.builder.getInstallStep().dependOn(&step.step);
}

const InstallFromWriteFileStep = struct {
    const This = @This();

    builder: *Builder,
    wfs: *WriteFileStep,
    base_name: []const u8,
    dest_rel_path: []const u8,
    step: Step,

    pub fn create(opts: InstallFromWriteFileOpts) *This {
        const self = opts.builder.allocator.create(This) catch unreachable;

        self.* = .{
            .builder = opts.builder,
            .wfs = opts.wfs,
            .base_name = opts.base_name,
            .dest_rel_path = opts.dest_rel_path,
            .step = Step.init(
                .Custom,
                opts.builder.fmt("install generated {s}", .{opts.base_name}),
                opts.builder.allocator,
                This.make,
            ),
        };
        return self;
    }

    fn make(step: *Step) !void {
        const self = @fieldParentPtr(This, "step", step);
        const src_path = self.wfs.getOutputPath(self.base_name);
        const full_src_path = self.builder.pathFromRoot(src_path);

        const full_dest_path = self.builder.getInstallPath(
            .Prefix,
            self.dest_rel_path,
        );
        try self.builder.updateFile(full_src_path, full_dest_path);
    }
};

/// Write a file's contents to a writer.
/// Path must be absolute.
fn writeAllFile(writer: anytype, path: []const u8) !void {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    var buffer: [256]u8 = undefined;
    while (true) {
        const amt = try file.read(&buffer);
        if (amt == 0)
            break;
        try writer.writeAll(buffer[0..amt]);
    }
}
