const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // We will also create a module for our other entry point, 'main.zig'.
    const exe_mod = b.createModule(.{
        // `root_source_file` is the Zig "entry point" of the module. If a module
        // only contains e.g. external object files, you can make this `null`.
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // This creates another `std.Build.Step.Compile`, but this one builds an executable
    // rather than a static library.
    const exe = b.addExecutable(.{
        .name = "wgpu",
        .root_module = exe_mod,
    });

    // webgpu.h + wgpu.h translated to Zig by translate-C, already wired to the
    // prebuilt libwgpu_native archive for the selected target (see deps/wgpu_native).
    const wgpu_link_mode = b.option(
        std.builtin.LinkMode,
        "wgpu_link_mode",
        "Link libwgpu_native statically or dynamically (default).",
    ) orelse .dynamic;
    const wgpu_native = b.dependency("wgpu_native", .{ 
        .target = target, 
        .optimize = optimize, 
        .wgpu_link_mode = wgpu_link_mode
    });

    exe_mod.addImport("wgpu", wgpu_native.module("wgpu"));

    // Linking flags live on the module in Zig 0.17. `msvc` archives pull in their own
    // C++ runtime and static libs; see deps/wgpu_native/build.zig.
    if (target.result.abi != .msvc) {
        exe_mod.link_libc = true;
        exe_mod.link_libcpp = true;
        exe.bundle_ubsan_rt = true; // needed by wgpu-native
    }

    const sdl_dep = b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
    });
    const sdl_lib = sdl_dep.artifact("SDL3");
    exe_mod.linkLibrary(sdl_lib);

    const translateSdl = b.addTranslateC(.{
        .root_source_file = b.path("deps/sdl3.h"),
        .target = target,
        .optimize = optimize,
    });
    translateSdl.addIncludePath(sdl_dep.path("include"));
    exe_mod.addImport("sdl3", translateSdl.createModule());

    const zmath = b.dependency("zmath", .{});
    exe.root_module.addImport("zmath", zmath.module("root"));

    const zstbi = b.dependency("zstbi", .{});
    exe.root_module.addImport("zstbi", zstbi.module("root"));

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    if (wgpu_link_mode == .dynamic) {
        // Link by SONAME (`-L <package>/lib -lwgpu_native`) and ship the library
        // next to the binary, with rpaths for both locations.
        exe.root_module.addLibraryPath(wgpu_native.namedLazyPath("wgpu-native-lib").dirname());
        exe.root_module.linkSystemLibrary("wgpu_native", .{});
        switch (target.result.os.tag) {
            .linux => exe.root_module.addRPathSpecial("$ORIGIN"),
            .macos => exe.root_module.addRPathSpecial("@loader_path"),
            else => {},
        }
        exe.each_lib_rpath = true;
        const subPath = getSubPath(wgpu_native.namedLazyPath("wgpu-native-lib"));
        const lib_name = std.fs.path.basename(subPath);
        const lib_path = std.fs.path.join(b.allocator, &[_][]const u8{ "bin", lib_name }) catch unreachable;
        const install_lib = b.addInstallFile(wgpu_native.namedLazyPath("wgpu-native-lib"), lib_path);
        b.getInstallStep().dependOn(&install_lib.step);
    }

    // copy contents of data/ to the output dir
    b.installDirectory(.{
        .install_dir = .bin,
        .source_dir = b.path("data"),
        .install_subdir = "data",
    });

    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    // NOTE: `std.Build.args` was removed in Zig 0.17; `zig build run -- args` is
    // no longer forwarded by the build script. Forward arguments explicitly with
    // `run_cmd.addArg(...)` (or a build option) if the app needs them.

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}

fn getSubPath(p: std.Build.LazyPath) []const u8 {
    return switch (p) {
        .cwd_relative => |cr| cr,
        .dependency => |dp| dp.sub_path,
        .generated => |gn| gn.sub_path,
        .relative => |rl| rl.sub_path,
        .src_path => |sp| sp.sub_path,
    };
}
