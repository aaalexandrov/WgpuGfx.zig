const std = @import("std");

/// Minimal replacement for the hand-written `wgpu_native_zig` bindings:
/// expose the prebuilt wgpu-native release archives as
///   * `module("wgpu")`   - `webgpu.h` + `wgpu.h` translated to Zig by translate-C,
///                          already carrying the `libwgpu_native` object file and
///                          the C/C++ runtime link flags,
///   * `namedLazyPath("wgpu-native-obj")` - the same object file, for compile steps
///                          that need to link it directly (unit tests).
///
/// Add the system libraries/frameworks your target needs to `wgpu_mod` below.
fn link_windows_system_libraries(mod: *std.Build.Module, is_gnu: bool) void {
    const linkSystemLibrary = std.Build.Module.linkSystemLibrary;

    if (is_gnu) {
        // The gnu archive can't resolve a static d3dcompiler; ld looks for
        // "libd3dcompiler.a" instead of "d3dcompiler.lib".
        linkSystemLibrary(mod, "d3dcompiler_47", .{});
        // windows-result crate dependency
        linkSystemLibrary(mod, "api-ms-win-core-winrt-error-l1-1-0", .{});
    } else {
        linkSystemLibrary(mod, "d3dcompiler", .{});
        // GetClientRect is unresolved otherwise
        linkSystemLibrary(mod, "user32", .{});
        linkSystemLibrary(mod, "RuntimeObject", .{});
    }
    linkSystemLibrary(mod, "opengl32", .{});
    linkSystemLibrary(mod, "gdi32", .{});
    linkSystemLibrary(mod, "OleAut32", .{});
    linkSystemLibrary(mod, "Ole32", .{});
    // rust stdlib
    linkSystemLibrary(mod, "ws2_32", .{});
    linkSystemLibrary(mod, "userenv", .{});
    // windows-rs
    linkSystemLibrary(mod, "propsys", .{});
}

fn link_mac_frameworks(mod: *std.Build.Module) void {
    mod.linkFramework("Foundation", .{});
    mod.linkFramework("QuartzCore", .{});
    mod.linkFramework("Metal", .{});
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const link_mode = b.option(
        std.builtin.LinkMode,
        "wgpu_link_mode",
        "Link libwgpu_native statically or dynamically(default).",
    ) orelse .dynamic;

    const tr = target.result;
    const abi_str = switch (tr.os.tag) {
        .ios => switch (tr.abi) {
            .simulator => "_simulator",
            else => "",
        },
        .windows => switch (tr.abi) {
            .msvc => "_msvc",
            else => "_gnu",
        },
        else => "",
    };
    const mode_str = switch (optimize) {
        .Debug => "debug",
        else => "release",
    };
    const target_name = std.fmt.allocPrint(
        b.allocator,
        "wgpu_{s}_{s}{s}_{s}",
        .{ @tagName(tr.os.tag), @tagName(tr.cpu.arch), abi_str, mode_str },
    ) catch @panic("out of memory");

    for (b.available_deps) |dep| {
        if (std.mem.eql(u8, dep[0], target_name)) break;
    } else {
        std.debug.panic("wgpu-native: no prebuilt dependency named '{s}' in deps/wgpu_native/build.zig.zon", .{target_name});
    }

    const wgpu_dep = b.lazyDependency(target_name, .{}) orelse
        std.debug.panic("wgpu-native: lazy dependency {s} not fetched", .{target_name});

    // The C headers *are* the API; translate-C generates the whole Zig binding.
    const translateWgpu = b.addTranslateC(.{
        .root_source_file = wgpu_dep.path("include/webgpu/wgpu.h"),
        .target = target,
        .optimize = optimize,
    });
    const wgpu_mod = translateWgpu.addModule("wgpu");
    wgpu_mod.resolved_target = target;

    const is_windows = tr.os.tag == .windows;
    const is_mac = tr.os.tag == .macos or tr.os.tag == .ios;

    var obj_path: ?std.Build.LazyPath = null;
    // The shared object/dylib/dll the dependee should ship next to its binary when
    // linking dynamically; re-exported so a dependee can install it.
    var shared_path: ?std.Build.LazyPath = null;

    if (is_windows) {
        // wgpu-native's msvc archives need the C runtime rather than libc++.
        wgpu_mod.link_libcpp = tr.abi != .msvc;
        wgpu_mod.link_libc = true;
        link_windows_system_libraries(wgpu_mod, tr.abi == .gnu);
        if (link_mode == .static) {
            obj_path = if (tr.abi == .msvc)
                wgpu_dep.path("lib/wgpu_native.lib")
            else
                wgpu_dep.path("lib/libwgpu_native.a");
        } else {
            shared_path = wgpu_dep.path("lib/wgpu_native.dll");
        }
    } else if (is_mac) {
        wgpu_mod.link_libcpp = true;
        wgpu_mod.link_libc = true;
        if (link_mode == .static) {
            obj_path = wgpu_dep.path("lib/libwgpu_native.a");
        } else {
            shared_path = wgpu_dep.path("lib/libwgpu_native.dylib");
        }
        link_mac_frameworks(wgpu_mod);
    } else {
        wgpu_mod.link_libcpp = true;
        wgpu_mod.link_libc = true;
        if (link_mode == .static) {
            obj_path = wgpu_dep.path("lib/libwgpu_native.a");
        } else {
            shared_path = wgpu_dep.path("lib/libwgpu_native.so");
        }
    }

    if (obj_path) |obj| {
        wgpu_mod.addObjectFile(obj);
        b.addNamedLazyPath("wgpu-native-obj", obj);
    }
    if (shared_path) |shared| {
        // The dependee links with `-L <wgpu-native-lib.dirname()> -lwgpu_native` so the
        // DT_NEEDED entry is the SONAME, installs `wgpu-native-lib` next to its
        // binary and adds an rpath for it.
        b.addNamedLazyPath("wgpu-native-lib", shared);
    }
    // Dynamic linking needs the library search path and an rpath on the *final*
    // link, which the dependee knows; see the `wgpu_link_mode` option there.

}
