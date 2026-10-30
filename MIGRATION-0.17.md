# Zig 0.17 migration notes

Branch: `upgrade-0.17` (base commit `7547063`, "Upgrade dependencies", which was Zig 0.14 era).

Status: `zig build`, `zig build test` and `zig build -Doptimize=...` succeed on
`x86_64-linux-gnu`; the demo window opens, renders (Vulkan / NVIDIA RTX 5070 Ti)
and exits without leak reports from the debug allocator.

## Dependencies after the upgrade

| dep | before | after |
|----|--------|-------|
| zglfw | `feeeff9` (0.10.0-dev, Zig 0.14) | `2450fe3` (0.10.0-dev, `minimum_zig_version 0.17.0`) |
| zmath | `05799b3` (0.11.0-dev) | `4325020` (0.11.0-dev, Zig 0.17) |
| zstbi | `a70604a` (0.11.0-dev) | `6b9bea1` (0.11.0-dev, Zig 0.17) |
| wgpu bindings | `bronter/wgpu_native_zig` v6.5.0 (git dep, wgpu-native **25.0.2.1**) | **vendored fork** in `deps/wgpu_native_zig` (v6.5.0 = `ed408d5`, patched for 0.17) |

`zig fetch --save=... git+https://github.com/zig-gamedev/<dep>#<sha>` was used for
the zig-gamedev deps. They compile against the pinned commits above, so they are
effectively "latest" (both repos publish no tags; `main` is the release line).

## Why the wgpu bindings had to be vendored

`bronter/wgpu_native_zig` is stale (last upstream push 2025-08, `minimum_zig_version
0.14.0`) and its **build script** is what breaks under 0.17, not its bindings. Since
a dependency's `build.zig` is executed, the only way to keep using it is to own a
patched copy. `deps/wgpu_native_zig` is that copy;
`deps/wgpu_native_zig-6.5.0-zig0.17.patch` records the diff against pristine v6.5.0
so the fork can be re-created from an upstream clone:

```sh
git clone --branch v6.5.0 https://github.com/bronter/wgpu_native_zig deps/wgpu_native_zig
git -C deps/wgpu_native_zig apply ../../wgpu_native_zig-6.5.0-zig0.17.patch
```

The fork is now fully 0.17-clean (its own `zig build`, `zig build test`,
`zig build compute-tests` pass). Patch groups:

1. `callconv(.C)` → `callconv(.c)` (~135 call sites, `std.lang.CallingConvention` lost `.C`).
2. Linking API moved from `Compile` to `Module`: `c.linkSystemLibrary2/linkLibrary/linkFramework/
   addLibraryPath/addObjectFile/linkLibC()/linkLibCpp()` → `c.root_module.*`
   (`linkFramework`/`linkSystemLibrary` now take an options struct, `linkLibC()` became
   `root_module.link_libc = true`).
3. Misc build/stdlib: `b.getInstallPath(.lib, "")` → `b.path("zig-out/lib")`,
   `Run.addPathDir` → `Run.addDirectoryArg`, `std.builtin.OptimizeMode` → `std.builtin.Optimize`,
   optimize enum literals `.Debug` → `.debug`, and `std.Thread.sleep` → a local
   `pollSleep()` using `std.c.nanosleep` in `src/adapter.zig`/`src/instance.zig`
   (better: replace the busy-wait with `wgpuInstanceWaitAny`, present in both 25 and 29).

## What changed in this repo (95 insertions / 63 deletions, 8 files)

* `build.zig.zon`: `minimum_zig_version = "0.17.0"`, deps bumped, wgpu bindings switched
  from `url`+`hash` to `.path = "deps/wgpu_native_zig"`, `deps` added to `.paths`.
* `build.zig`: `exe.linkLibrary(...)` → `exe.root_module.linkLibrary(...)`; the
  `if (b.args) |args| run_cmd.addArgs(args)` block was **removed** — `std.Build.args` no
  longer exists and `zig build run -- foo bar` no longer forwards anything (proved by
  experiment: the run step only receives the artifact path). Forward explicitly with
  `run_cmd.addArg(...)` if the app needs CLI args.
* `src/main.zig`:
  * `pub fn main(init: std.process.Init) !void` replaces `std.heap.GeneralPurposeAllocator`
    (deleted in 0.17; `init.gpa` is leak-checked in debug, `init.io` is the I/O manager,
    `init.arena` the per-process arena). `std.os.argv` is gone too (`init.args.iterate()`).
  * `std.time.microTimestamp()` → `std.Io.Timestamp.now(io, .awake)` +
    `from.durationTo(to).toNanoseconds()`; the FPS math is now in ns (`1e9 / …`).
    `std.time` now only keeps the unit constants; clocks live in `std.Io.Clock`
    (`real`, `awake`, `boot`, `cpu_process`, `cpu_thread` — there is **no** `.monotonic`).
  * `glfw.Window.create` gained a 5th parameter (`share`), and title is `[:0]const u8`.
  * `zstbi.init` now returns `!void` (`try zstbi.init(alloc)`).
  * Uniform structs stay `[4][4]f32` but are filled with `@bitCast(...)` (see gotcha below).
  * The procedural checkerboard texture became `[512][512][4]u8` instead of
    `[512][512]@Vector(4, u8)`.
* `src/shader.zig`: file reading is `std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(...))`
  (`std.fs.cwd().openFile(...).readToEndAllocOptions` is gone); `std.meta.fields(T)` →
  `@typeInfo(T).@"struct".field_names / .field_types` (the `fields` array was replaced by
  parallel arrays).
* `src/device.zig`: carries an `io: std.Io` field so `Shader`/`Texture` helpers can do file I/O;
  `callconv(.c)`.
* `src/font_render.zig`: `std.ArrayList(T)` is now the **unmanaged** list in 0.17
  (`std.ArrayListUnmanaged == std.ArrayList`): `.init(alloc)` → `.empty` / `.initCapacity(gpa, n)`,
  `append(item)` → `append(gpa, item)` (or `appendAssumeCapacity`), `resize(0)` →
  `clearRetainingCapacity()`, `deinit()` → `deinit(gpa)`. An `alloc` field was added.
* `src/util.zig` + `src/fixed_font.zig`: replaced the `widthInt.ptr - fontfile.ptr`
  pointer-arithmetic trick with explicit `start`/`end` indices (`findFirstIntegerRange`).
* `src/math.zig` (598 lines) is **dead code** — nothing imports it; kept as-is.

## Zig 0.17 gotchas that actually bit

1. **`@Vector` alignment.** `@Vector(4, u8)` is now aligned to its natural SIMD width, so
   arrays of small vectors get padded: the 512×512 `@Vector(4,u8)` texture became 4 MiB
   and tripped the `bytesPerRow*height == content.len` assertion. Keep CPU-side image and
   uniform buffers as plain arrays; `@Vector` types in `switch` (e.g. `getVertexFormat`)
   are fine as *types*, just never as memory layout. `vec.arr` is also gone.
2. **`extern struct` + SIMD.** zmath 0.11 defines `Mat = [4]@Vector(4, f32)`, and extern
   structs reject vector fields ("vectors have no guaranteed in-memory representation"), so
   uniforms are `[4][4]f32` assigned with `@bitCast(mat)`.
3. **Release builds need the ubsan runtime bundled.** The prebuilt wgpu-native
   `debug`/`release` archives reference `__ubsan_handle_*`; Zig bundles that runtime
   automatically in Debug only, so `zig build -Doptimize=ReleaseSafe|ReleaseFast` failed to
   link until `build.zig` sets `exe.bundle_ubsan_rt = true`. (Also note the dep's build script
   picks the *release* prebuilt for every non-debug mode, i.e. `ReleaseSafe` links a release
   `libwgpu_native.a`.)
4. **`build.zig.zon` fingerprints are validated**: a wrong/foreign `0x...` fingerprint is now
   a hard error and zig prints the value to use. Regenerate (delete the field, `zig build`)
   for any package you fork.
5. **Compile steps are pointers** (`*std.Build.Step.Compile`) and all linking knobs moved to
   `Module` — this is what broke three of the four dependency build scripts, not the deps' Zig code.
6. `std.Thread.sleep`, `std.time.microTimestamp/nanoTimestamp`, `std.os.argv`,
   `std.heap.GeneralPurposeAllocator`, `std.Build.args`, `Run.addPathDir`,
   `Compile.linkLibC/linkLibCpp/linkSystemLibrary2/linkFramework/addLibraryPath/addObjectFile`,
   `std.meta.fields`, `callconv(.C)`, `OptimizeMode`, `.Debug/.ReleaseFast` literals — all removed
   or renamed. `std.Io` (Threaded/Uring/Kqueue), `std.fs.File` → `std.Io.File`,
   `std.ArrayList` = unmanaged: the whole "0.17 I/O overhaul".

## Remaining work / open choices

* **wgpu bindings are pinned to wgpu-native 25.0.2.1** via prebuilt zips in the vendored fork's
  lazy deps. Latest wgpu-native is **29.0.1.1**. I compared the two headers for every API this
  project touches: only `wgpuRenderPassEncoderSetPushConstants`,
  `wgpuComputePassEncoderSetPushConstants`, `wgpuRenderBundleEncoderSetPushConstants` (unused here)
  and `WGPUSurfaceGetCurrentTextureStatus_{DeviceLost,OutOfMemory}` (caught by the existing
  `else =>` arm in `surface.zig`) went away; `WGPUSurfaceConfiguration`, `WGPUTextureDescriptor`,
  `WGPUCommandBufferDescriptor`, `WGPUAdapterInfo`, `WGPULimits`, `WGPUPresentMode_Immediate`
  are unchanged. So upgrading bindings is a *bindings-layer* job (no fork exists that is both
  0.17-ready and on 29: the active candidates are `substepgames/`, `gstrainovic/`, `Tired-Fox/`
  forks at 6.5.0/25.x and the greenfield `thng292/wgpu-native-zig` at 29.0.1.1 but 0.16-era),
  then bumping the lazy `wgpu_<os>_<arch>_<mode>` URLs to the 29.0.1.1 zips. Estimate:
  a day, mostly build-graph + prebuilt-binary plumbing and re-running the samples.
* `wgpu.PresentMode.immediate` is accepted by the bindings but rejected at runtime by
  wgpu-native 25 (`Unrecognized present mode 1000361000`); `.fifo` or `.mailbox` is the intent.
* Runtime validation noise (`VUID-vkQueueSubmit-pSignalSemaphores-00067`) comes from
  wgpu-native's swapchain semaphore reuse on Vulkan, not from this migration.
* Consider replacing the vendored fork's busy-wait in `requestAdapterSync/requestDeviceSync`
  with `wgpuInstanceWaitAny`.
* Debug binary is ~161 MB and ReleaseFast ~100 MB because the static `libwgpu_native.a` is linked in.
