# Raw C import of wgpu-native (`webgpu.h` / `wgpu.h`)

Branch: `raw-c-import` (on top of `upgrade-0.17`). The hand-written
`wgpu_native_zig` bindings are gone; the project now calls wgpu-native straight
from its shipped C headers through `std.Build.addTranslateC`.

## What changed

| before | after |
|---|---|
| `deps/wgpu_native_zig` (vendored, patched fork of `bronter/wgpu_native_zig` 6.5.0, 4398 lines, wgpu-native **25.0.2.1**) | `deps/wgpu_native` (a ~150-line build package: lazy per-target wgpu-native **29.0.1.1** release zips + translate-C of `wgpu.h`) |
| `wgpu.BufferUsages.copy_dst`, `device.createBuffer(desc).?` | `wgpu.WGPUBufferUsage_CopyDst`, `device.wgpuDeviceCreateBuffer(&desc)` |
| bindings' Zig enums (`wgpu.TextureFormat.rgba8_unorm`) + `std.enums.tagName` | C enums as integer aliases + `WGPU*` constants; small `switch` name helpers in `device.zig` |
| `util.releaseObj(&x)` | `util.releaseObj(wgpu.wgpuBufferRelease, &x)` |
| — | `src/handles.zig`: non-optional handle aliases + `stringView`/`stringSlice` |
| `src/math.zig` (598 lines, unused) | deleted |

Net diff vs `upgrade-0.17`: **+1183 / −8054** lines. App-side churn was
~1376 changed lines over 12 files (`main`, `device`, `surface`, `commands`,
`shader`, `resources`, `downsample`, `font_render`, `fixed_font`, `util`,
`wgfx`, new `handles`) — the app only had 191 `wgpu.*` references / 69 distinct
symbols to translate.

## How the build wiring works

`deps/wgpu_native/build.zig`:

* picks the prebuilt archive package name `wgpu_<os>_<arch>[_<abi>]_<debug|release>`
  from `b.available_deps`, exactly as the old bindings did, and `b.lazyDependency`
  fetches only the one actually used;
* `b.addTranslateC(wgpu_dep.path("include/webgpu/wgpu.h"))` → `module("wgpu")`;
* attaches `lib/libwgpu_native.a` (or `.lib`/`.dll.lib` on Windows) to that module,
  plus `link_libc`/`link_libcpp` and the Windows system libs / macOS frameworks;
* `-Dwgpu-link-mode=dynamic` switches to `linkSystemLibrary("wgpu_native")` and
  installs the shipped `.so`/`.dylib`/`.dll`.

`build.zig` (main project) then only needs:

```zig
const wgpu_native = b.dependency("wgpu_native", .{});
exe_mod.addImport("wgpu", wgpu_native.module("wgpu"));
if (target.result.abi != .msvc) { exe_mod.link_libc = true; exe_mod.link_libcpp = true; }
if (target.result.abi != .msvc) exe.bundle_ubsan_rt = true;
```

All 30 platform zips of v29.0.1.1 are declared as lazy deps (same set the old
bindings had). To bump wgpu-native:

```sh
cd deps/wgpu_native
zig fetch --save=wgpu_linux_x86_64_release https://github.com/gfx-rs/wgpu-native/releases/download/vXX.YY.ZZ/wgpu-linux-x86_64-release.zip
# ... repeat per platform, then set `.lazy = true` on each entry
```

## Gotchas found while porting (all reproduced/observed here)

1. **`wgpuInstanceWaitAny` is `unimplemented!()` in wgpu-native** (25 and 29): calling it
   aborts. Adapter/device requests use `WGPUCallbackMode_AllowProcessEvents` plus a spin on
   `wgpuInstanceProcessEvents` (`Device.waitFor`).
2. **translate-C defaults every C enum field to `0` = `Undefined`.** The old bindings had
   hand-written defaults; those must be restored explicitly or wgpu rejects the descriptor:
   * `WGPUSamplerDescriptor`: `lodMaxClamp = 32`, `maxAnisotropy = 1`
     (otherwise `Invalid anisotropic clamp: 0`);
   * `WGPUTextureDescriptor`: `dimension = 2D`, `mipLevelCount = 1`, `sampleCount = 1`,
     `size.depthOrArrayLayers = 1` (otherwise `Dimension Z is zero`);
   * `WGPUTextureViewDescriptor`: `arrayLayerCount = WGPU_ARRAY_LAYER_COUNT_UNDEFINED`,
     `aspect = All`;
   * `WGPUBindGroupEntry.size == 0` → wgpu-native `panic!("invalid size")`; use
     `WGPU_WHOLE_SIZE` (done in `Shader.createBindGroupFromEntries`);
   * `WGPUPrimitiveState`/`WGPUMultisampleState`/`WGPUStencilFaceState`/
     `WGPUColorTargetState.writeMask`/`WGPURenderPassColorAttachment.depthSlice` filled in.
3. **C enums are integer aliases, not Zig enums** — `std.enums.tagName` is gone, so the four
   name-printing sites use small `switch` helpers (`logLevelName`, `backendTypeName`,
   `adapterTypeName`, `formatName`). Assigning a constant to an enum-typed field sometimes
   needs `@intCast` (`c_int` constant vs `c_uint` field).
4. **`nextInChain` is `[*c]WGPUChainedStruct` (non-nullable)** in translate-C output; chain
   helpers return non-optional pointers and `@constCast` is used for const locals.
5. **Wayland needs `glfw.windowHint(.client_api, .no_api)`** before window creation, or
   `wgpuSurfaceConfigure` fails with `Validation Error: Invalid surface` (GLFW grabs an EGL
   surface and wgpu's Vulkan WSI cannot take the `wl_surface`).
6. Re-configuring a configured surface is cleaner with an explicit `wgpuSurfaceUnconfigure`
   (done in `Surface.configure`).
7. `WGPUPresentMode` values are now the real WebGPU ones, so the old
   `Unrecognized present mode 1000361000` warning is gone — the bindings' `PresentMode`
   values had been Rust-internal numbers that wgpu-native silently ignored.
8. naga in wgpu 29 is stricter about WGSL (declare `struct` before the `var<uniform>` that
   uses it; `@location(0)` on a fragment return). `data/plain.wgsl`/`data/downsample.wgsl`
   already satisfied this.

## Verification (Zig 0.17.0, RTX 5070 Ti, Vulkan, KDE/Wayland)

```
zig build                            OK
zig build test                       OK
zig build -Doptimize=ReleaseSafe     OK
zig build -Doptimize=ReleaseFast     OK
WGPU_MAX_FRAMES=300 ./zig-out/bin/wgpu
  Adapter: NVIDIA GeForce RTX 5070 Ti, type: discreteGPU, backend: vulkan
  Surface format: rgba8unorm-srgb
  Frames: 300, seconds: 0.186, FPS: 1615.053
ReleaseSafe: Frames: 200, seconds: 0.120, FPS: 1669.214
ReleaseFast: Frames: 200, seconds: 0.118, FPS: 1689.115
```

No validation errors, no panics, no present-mode warning.

`WGPU_MAX_FRAMES=<n>` is a new opt-in smoke-test knob in `main.zig` for headless/CI runs.

Cross-target builds (`-Dtarget=aarch64-linux`, `x86_64-windows-*`) fail on
`unable to find dynamic system library "X11"` — that comes from zglfw needing a sysroot and
fails identically on `upgrade-0.17`, so it is not a regression from this port.

## Reference PoC

`/home/alex/wgpu-c-poc` (outside the repo) is the standalone proof of concept the port was
derived from; its README lists the same gotchas.
