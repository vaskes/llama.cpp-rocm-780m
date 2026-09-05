# llama.cpp + ROCm on Radeon 780M (gfx1103) — Production Setup

> **Complete, working, reproducible** setup for running
> [llama.cpp](https://github.com/ggml-org/llama.cpp) on a **Radeon 780M iGPU
> (gfx1103)** with **TheRock ROCm 7.13** in Docker, with full Zen 4
> (Ryzen 7 8700G) CPU SIMD optimisation.

Native gfx1103 build. No `HSA_OVERRIDE_GFX_VERSION` shim, no gfx1100
emulation, no `AMDGPU_TARGETS=gfx1100` shenanigans.

---

## What this is

A versioned, reproducible Docker image for llama-server on RDNA3 iGPU.
Pinned versions of every dependency for deterministic rebuilds.

- **TheRock gfx110X-all wheels** for native gfx1103 inference
  (ROCm 7.13.0a20260513 — see "Why 7.13 not 7.14" below)
- **Full Zen 4 CPU backend** via `-march=znver4 -mtune=znver4` plus
  explicit SIMD flags
- **Multi-stage build**: `build` stage has the toolchain (~3.2 GB),
  `runtime` stage is just the compiled binaries + runtime libs (~1.4 GB)
- **Persistent build cache** via bind-mount, so incremental rebuilds
  after `git pull` of llama.cpp source only recompile the changed files
- **Production entrypoint**: `llama-server` on port 8080 (host 8082)

### Verified working on

Ubuntu 24.04 + Linux kernel 7.0.0-30-generic + Radeon 780M
(gfx1103, 16 GB VRAM + 40 GB GTT APU) + `amdgpu.cwsr_enable=0`
GRUB fix (already required for ComfyUI on this GPU — see
[ROCm issue #5590](https://github.com/RadeonOpenCompute/ROCm/issues/5590)).

---

## Why TheRock gfx110X-all wheels

PyTorch and HIP wheels from the **official PyTorch index** don't have
`gfx1103` in their supported architectures for older ROCm releases.
The `HSA_OVERRIDE_GFX_VERSION=11.0.0` (gfx1100 emulation) trick works
for synthetic matmuls but **segfaults inside
`rocr::AMD::GpuAgent::InitDma()`** on real workloads on 780M.

**TheRock** is AMD's open-source build system for HIP/ROCm, and it ships
**native gfx110X code paths** (MIOpen, rocBLAS, etc.) for RDNA3 iGPUs.
The wheels are published at
`https://rocm.nightlies.amd.com/v2/gfx110X-all/`. We use the gfx110X-all
package (not the multi-arch `nightly.repo.amd.com` index) because the
gfx110X-all is verified to work on the 780M (it's the same package the
[comfyui-rocm-780m](https://github.com/vaskes/comfyui-rocm-780m) project
uses, and ComfyUI on 780M is also known-good).

### Why 7.13 not 7.14

The latest TheRock wheels (`7.14.0a20260612`) have a **regression on
gfx1103**: `hipMalloc` segfaults inside
`rocr::AMD::GpuAgent::InitDma()` after the HSA runtime loads, even
though `rocm-smi` works fine. The same wheels at `7.13.0a20260513`
(used by [comfyui-rocm-780m](https://github.com/vaskes/comfyui-rocm-780m))
work correctly. We pin to 7.13.

---

## Hardware requirements

| Component        | Minimum          | Tested                              |
|------------------|------------------|-------------------------------------|
| APU / GPU        | RDNA3 iGPU       | **Radeon 780M** (Ryzen 7 8700G)    |
| CPU              | Zen 4            | **Ryzen 7 8700G** (Phoenix, 8C/16T)|
| RAM              | 16 GB            | 47 GB + 29 GB swap                  |
| BIOS: GTT size   | 8 GB             | **40 GB**                           |
| BIOS: VRAM size  | 4 GB             | **16 GB**                           |
| Disk             | 5 GB (runtime)   | 100+ GB (for model files)           |

The 780M is an APU — no HBM. "VRAM" (16 GB) and "GTT" (40 GB) are both
partitions of system RAM, just with different allocation policies in
the amdgpu kernel module.

### Confirmed CPU instruction set (Zen 4, Phoenix)

`avx avx2 fma f16c bmi1 bmi2 avx512f avx512dq avx512ifma avx512bw
avx512cd avx512vl avx512vbmi avx512_vbmi2 avx512_vnni avx512_bitalg
avx512_vpopcntdq avx512_bf16 gfni vaes vpclmulqdq sha_ni`

The build enables all of these via `-march=znver4` + explicit
`GGML_AVX512_VBMI`/`VNNI`/`BF16` CMake options.

---

## Software prerequisites

- **OS**: Ubuntu 24.04 (other 24.04-based distros should work)
- **Kernel**: any 7.0.0-30+ (tested: 7.0.0-30-generic)
- **Docker**: 27+ with compose plugin
- **GPU group membership**: `render` (GID 992) and `video` (GID 44)
- **GRUB fix**: `amdgpu.cwsr_enable=0` must be set on the host (see
  the comfyui-rocm-780m docs for instructions)

The host ROCm version doesn't matter — the container has its own
ROCm 7.13 from TheRock, and we don't use any host ROCm libraries.

---

## Quickstart (5 minutes)

```bash
# 1. Clone this repo
git clone https://github.com/vaskes/llama.cpp-rocm-780m.git
cd llama.cpp-rocm-780m

# 2. Build the Docker image (~10-15 min, ~1.4 GB runtime image)
docker build -f build/Dockerfile -t llama.cpp-rocm-780m:7.13 build/

# 3. Edit docker-compose.yml to point at your model
#    (change the `command:` model path under services.llama-server)
vim docker-compose.yml

# 4. Start the server
docker compose up -d

# 5. Tail logs
docker compose logs -f llama-server

# 6. Smoke-test the API
curl -s http://127.0.0.1:8082/v1/models
curl -s -X POST http://127.0.0.1:8082/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model": "any", "messages": [{"role": "user", "content": "Say hi in 5 words."}]}'
```

The server listens on `http://localhost:8082` (host) → `8080` (container)
and is compatible with the OpenAI `/v1/*` and Anthropic `/v1/messages`
API shapes.

---

## How it works

### Build stage

1. `ubuntu:24.04` base
2. Install C++ toolchain (g++, cmake, ninja)
3. Create Python venv, install three TheRock wheels pinned to 7.13.0a20260513:
   - `rocm-sdk-core` (compiler/utility tools, including hipcc/amdclang/rocm-smi)
   - `rocm-sdk-libraries-gfx110x-all` (MIOpen/rocBLAS for gfx1103)
   - `rocm-sdk-devel` (headers, dev libs)
4. Symlink the unversioned `.so` files (`libamdhip64.so`,
   `libhiprtc.so`, `libamd_comgr.so`) into the locations where
   `hipcc`'s hard-coded linker paths expect them
5. `git clone` llama.cpp
6. `cmake -B build -G Ninja` with all the SIMD flags +
   `-DAMDGPU_TARGETS=gfx1103`
7. `cmake --build build -j$(nproc)`

### Runtime stage

1. `ubuntu:24.04` base
2. Install only `rocm-sdk-core` and `rocm-sdk-libraries-gfx110x-all`
   (no compiler → ~1.4 GB instead of ~3.2 GB)
3. Symlink `libamdhip64.so` for runtime loader
4. `COPY --from=build` the compiled `build/bin/` and `build/lib/`
5. `ENTRYPOINT llama-server` with sensible production defaults

### Persistent build cache

The `build/` directory on the host is bind-mounted to `/opt/build/`
inside the build container, so:

- The first build does a full `cmake` configure + compile (~10 min)
- A subsequent build after editing the Dockerfile only re-runs the
  changed layers (CMake cache preserved → instant)
- A subsequent build after `git pull` of llama.cpp source triggers
  the CMake-rebuild flow (only modified files recompiled, ~1-3 min)

---

## Performance notes

The 780M is slow for LLM inference compared to a discrete GPU.
Realistic numbers on this APU (16 GB VRAM + 40 GB GTT):

| Model size | Quant  | ctx  | tok/s (decode, GPU) | Notes |
|------------|--------|------|---------------------|-------|
| 0.5B       | Q4_K_M | 4K   | ~15-20              | Quick chat, fits in VRAM |
| 1.5B       | Q4_K_M | 4K   | ~8-12               | |
| 3B         | Q4_K_M | 4K   | ~5-7                | |
| 7B         | Q4_K_M | 4K   | ~2-4                | Spills to GTT, slower |
| 27B        | Q4_K_M | 4K   | ~0.7-1.0            | Most of model in GTT |

These are estimates based on similar APU tests. Run your own benchmarks.

### Why GTT matters

The TheRock wheels for gfx1103 **write torch tensors to GTT, not VRAM**
(this is consistent with the comfyui-rocm-780m finding that
`mem_info_vram_used` stays at ~110 MiB even with 12 GB loaded in GPU
memory). For an APU, this is correct — both are GPU-accessible DDR5
system RAM, just with different allocation policies.

For llama.cpp, you can monitor via:

```bash
watch -n 1 'cat /sys/class/drm/card0/device/mem_info_{vram,gtt}_used'
```

---

## Repository layout

```
llama.cpp-rocm-780m/
├── README.md                  # this file
├── OPERATIONS.md              # day-to-day operations cheatsheet
├── .gitignore                 # excludes build/ and logs/
├── .dockerignore              # excludes build/ from image context
├── docker-compose.yml         # production deployment
├── build/
│   └── Dockerfile             # multi-stage: build → runtime
├── logs/                      # bind-mount target for llama-server logs
└── scripts/
    ├── start.sh               # convenience start (uses compose)
    ├── restart.sh             # restart with model re-pick
    ├── stop.sh                # graceful stop
    ├── shell.sh               # docker exec into running container
    └── test-api.sh            # smoke-test the OpenAI-compatible API
```

---

## Credits

- The [llama.cpp](https://github.com/ggml-org/llama.cpp) project
- The [TheRock](https://github.com/ROCm/TheRock) project for native
  gfx110X wheels
- The [comfyui-rocm-780m](https://github.com/vaskes/comfyui-rocm-780m)
  project for the working gfx1103 setup pattern
- The [ROCm](https://github.com/RadeonOpenCompute/ROCm) project

Built on **llmhost2** (Radeon 780M, Ryzen 7 8700G, Ubuntu 24.04).
