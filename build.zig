const std = @import("std");

const Builder = std.build.Builder;
const Step = std.build.Step;
const WriteFileStep = std.build.WriteFileStep;
const InstallDir = std.build.InstallDir;

pub fn build(b: *Builder) !void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    // NOTE: Wayfire paths aren't read from pkg-config as the values set by
    // wayfire are all absolute paths and thus would not respect the
    // installation prefix.
    const wf_plugin_dir = "lib/wayfire";
    const wf_metadata_dir = "share/wayfire/metadata";
    const lua_runtime_dir = b.option(
        []const u8,
        "lua-runtime-dir",
        "The directory where lua files are installed." ++
            " (relative to the install prefix)",
    ) orelse "share/wayfire/lua";

    const cpp_command =
        "clang++ $(pkg-config --cflags wayfire) " ++
        "-Wall -Wextra -Werror -O3 -g -std=c++17 " ++
        "-fPIC -DWLR_USE_UNSTABLE -DWAYFIRE_PLUGIN ";

    // TODO: cache this somehow. (makefile?)
    const cpp_sources = [_][]const u8{ "wf", "wf-plugin" };
    var cpp_objs = std.ArrayList(*std.build.RunStep).init(b.allocator);
    var cpp_cleanup = std.ArrayList(*std.build.RunStep).init(b.allocator);
    inline for (cpp_sources) |source| {
        try cpp_objs.append(b.addSystemCommand(&[_][]const u8{
            "sh",
            "-c",
            b.fmt(
                cpp_command ++
                    "-c src/" ++ source ++ ".cpp " ++
                    "-o {s}/" ++ source ++ ".o",
                .{b.cache_root},
            ),
        }));
        try cpp_cleanup.append(b.addSystemCommand(&[_][]const u8{
            "rm", b.fmt("{s}/" ++ source ++ ".o", .{b.cache_root}),
        }));
    }

    const plugin = b.addSharedLibrary(
        "wf-lua",
        "src/wf-lua.zig",
        .unversioned,
    );
    {
        inline for (cpp_sources) |source| {
            plugin.addObjectFile(
                b.fmt("{s}/" ++ source ++ ".o", .{b.cache_root}),
            );
        }
        plugin.addIncludeDir("src");
        // TODO: change to linkLibCpp when zig version is bumped
        plugin.linkSystemLibrary("c++");
        plugin.linkSystemLibrary("wayfire");
        plugin.linkSystemLibrary("luajit");

        plugin.defineCMacro("WLR_USE_UNSTABLE");
        plugin.defineCMacro("WAYFIRE_PLUGIN");
        plugin.addBuildOption(
            []const u8,
            "LUA_RUNTIME",
            b.fmt("{s}/{s}", .{ b.install_prefix, lua_runtime_dir }),
        );

        plugin.setBuildMode(mode);
        plugin.override_dest_dir = InstallDir{ .Custom = wf_plugin_dir };
        plugin.force_pic = true;
        plugin.rdynamic = true;

        // Plugin depends on C++ Objects
        for (cpp_objs.items) |obj_step| {
            plugin.step.dependOn(&obj_step.step);
        }

        const install_plugin = b.addInstallArtifact(plugin);

        // C++ Objects Cleanup depends on Plugin
        // Install Plugin      depends on C++ Objects Cleanup
        for (cpp_cleanup.items) |cleanup| {
            cleanup.step.dependOn(&plugin.step);
            install_plugin.step.dependOn(&cleanup.step);
        }

        b.getInstallStep().dependOn(&install_plugin.step);
    }

    b.installFile(
        "metadata/wf-lua.xml",
        b.fmt("{s}/wf-lua.xml", .{wf_metadata_dir}),
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

    b.installFile("lua/wf.lua", b.fmt("{s}/wf.lua", .{lua_runtime_dir}));
    b.installDirectory(.{
        .source_dir = "lua/wf",
        .install_dir = InstallDir{ .Custom = lua_runtime_dir },
        .install_subdir = "wf",
    });
    installFromWriteFile(.{
        .builder = b,
        .wfs = gen_lua_header,
        .base_name = "wf_h.lua.out",
        .dest_rel_path = b.fmt("{s}/wf/wf_h.lua", .{lua_runtime_dir}),
    });

    const wfmsg = b.addExecutable("wf-msg", "src/wf-msg.zig");
    wfmsg.addIncludeDir("src");
    wfmsg.install();

    var main_tests = b.addTest("src/wf-lua.zig");
    main_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
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
