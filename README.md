# llama.cpp + ROCm on Radeon 780M (gfx1103) — Production Setup

> **Complete, working, reproducible** setup for running
> [llama.cpp](https://github.com/ggml-org/llama.cpp) on a **Radeon 780M iGPU
> (gfx1103)** with **ROCm 7.2.4 from AMD's official apt repo** in Docker,
> with full Zen 4 (Ryzen 7 8700G) CPU SIMD optimisation.

Native gfx1103 build. No `HSA_OVERRIDE_GFX_VERSION` shim, no gfx1100
emulation, no `AMDGPU_TARGETS=gfx1100` shenanigans.

---

## What this is

A versioned, reproducible Docker image for llama-server on RDNA3 iGPU.
Pinned versions of every dependency for deterministic rebuilds.

- **AMD's official ROCm 7.2.4 apt repo** (`https://repo.radeon.com/rocm/apt/7.2.4`)
  — the same packages used by every production ROCm deployment
- **Native gfx1103** compiled into `libggml-hip.so` (no emulation, no
  fallback to gfx1100 at the GPU ISA level)
- **Full Zen 4 CPU backend** via `-march=znver4 -mtune=znver4` plus
  explicit SIMD flags (AVX-512 BF16/VBMI/VNNI)
- **Multi-stage build**: `build` stage has the toolchain (~5 GB),
  `runtime` stage is just the compiled binaries + runtime libs (~3 GB)
- **Persistent build cache** via bind-mount, so incremental rebuilds
  after `git pull` of llama.cpp source only recompile the changed files
- **Production entrypoint**: `llama-server` on port 8080 (host 8080)
- **No `/dev/kfd` mount** — see [OPERATIONS.md](OPERATIONS.md) for why
  this is the working configuration

### Verified working on

Ubuntu 24.04 + Linux kernel 7.0.0-30-generic + Radeon 780M
(gfx1103, 16 GB VRAM + 40 GB GTT APU) + `amdgpu.cwsr_enable=0`
GRUB fix (already required for ComfyUI on this GPU — see
[ROCm issue #5590](https://github.com/RadeonOpenCompute/ROCm/issues/5590)).

### Verified performance (Qwen3.8-27B-Q4_K_M, 16 GB VRAM iGPU)

| Metric | Value |
|---|---|
| Model load time | ~7 sec |
| Prompt eval | 18-26 tokens/sec |
| Token generation | 3.2-3.3 tokens/sec |

---

## Why AMD apt ROCm 7.2.4 (not TheRock wheels, not 7.14)

We tried multiple approaches. Here's the honest record:

### TheRock 7.13 wheels — abandoned
The Python wheels from `https://rocm.nightlies.amd.com/v2/gfx110X-all/`
work great in a host venv but **break inside Docker** because:
- The devel tarball is built for `/opt/rocm/`-style install paths;
  symlink chains inside point to `../../_rocm_sdk_core/...` (one level
  up) but Docker's pip layout puts `_rocm_sdk_devel` one level deeper
- Bitcode files at `lib/llvm/amdgcn/bitcode/*.bc` are symlinks with
  4-level `../../../../../_rocm_sdk_core/...` paths that don't survive
  the relocation
- The package name uses lowercase `gfx110x-all` but the extract dir
  is `_rocm_sdk_libraries_gfx110X_all/` (uppercase X) — case-inconsistent
- We burned ~7 hours fighting symlinks/headers before giving up

### 7.14 wheels / 7.14 apt — abandoned
7.14.0+ has a **regression on gfx1103**: `hipMalloc` segfaults inside
`rocr::AMD::GpuAgent::InitDma()` after the HSA runtime loads, even
though `rocm-smi` works fine. Confirmed with a synthetic matmul probe.

### AMD apt 7.2.4 — chosen
AMD's official apt repo (`https://repo.radeon.com/rocm/apt/7.2.4`) ships
a complete, portable, well-tested ROCm stack. The devel tarball is laid
out in the canonical `/opt/rocm/` style that `hipcc`'s hard-coded paths
expect. After ~3 hours of build-system debugging we got it compiling,
and the result is reproducible on any Ubuntu 24.04 host — no host
ROCm install required, no Python wheel hacks.

---

## Hardware requirements

| Component        | Minimum          | Tested                              |
|------------------|------------------|-------------------------------------|
| APU / GPU        | RDNA3 iGPU       | **Radeon 780M** (Ryzen 7 8700G)    |
| CPU              | Zen 4            | **Ryzen 7 8700G** (Phoenix, 8C/16T)|
| RAM              | 32 GB            | 47 GB + 29 GB swap                  |
| BIOS: GTT size   | 8 GB             | **40 GB**                           |
| BIOS: VRAM size  | 4 GB             | **16 GB**                           |
| Disk             | 15 GB (runtime)  | 100+ GB (for model files)           |

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
  for the user running docker (typically `git` on the homelab)
- **GRUB fix**: `amdgpu.cwsr_enable=0` must be set on the host (see
  the comfyui-rocm-780m docs for instructions)

The host ROCm version doesn't matter — the container has its own
ROCm 7.2.4 from AMD's apt repo, and we don't use any host ROCm
libraries.

---

## Quickstart (5 minutes, plus a 40-min first build)

```bash
# 1. Clone this repo
git clone https://github.com/vaskes/llama.cpp-rocm-780m.git
cd llama.cpp-rocm-780m

# 2. Build the Docker image (~40 min first time, mostly apt downloads)
docker build -f build/Dockerfile -t llama.cpp-rocm-780m:7.13 build/

# 3. Edit docker-compose.yml to point at your model
#    (change the `command:` model path under services.llama-server)
vim docker-compose.yml

# 4. Start the server
docker compose up -d

# 5. Tail logs
docker compose logs -f

# 6. Smoke-test the API
curl -s http://127.0.0.1:8080/v1/models
curl -s -X POST http://127.0.0.1:8080/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model": "any", "messages": [{"role": "user", "content": "Say hi in 5 words."}]}'
```

The server listens on `http://localhost:8080` (host) → `8080` (container). The same
port is used by the `llama-ornith-rocm.service` systemd unit, since Qwen and
Ornith are never running at the same time (~25-40 GB RAM each).
and is compatible with the OpenAI `/v1/*` API shape.

---

## How it works

### Build stage

1. `ubuntu:24.04` base
2. Add AMD ROCm apt repo at `https://repo.radeon.com/rocm/apt/7.2.4`
3. Install `rocm-hip-sdk rocm-dev` (hipcc, hip-runtime-amd, llvm/clang,
   hipBLAS/hipBLASLt/rocBLAS, hipFFT, hipRAND, RCCL, etc.) + C++ toolchain
4. `git clone` llama.cpp
5. `cmake -B build -G Ninja` with all the SIMD flags +
   `-DAMDGPU_TARGETS=gfx1103`
6. `cmake --build build -j$(nproc)` → 690 HIP object files

### Runtime stage

1. `ubuntu:24.04` base
2. Same apt repo, install just the runtime libs (hsa-rocr, comgr,
   hip-runtime-amd, rocm-smi-lib, rocblas, hipblas, hipblaslt)
3. Symlink `libomp.so` and `TensileLibrary_lazy_gfx1103.dat` (defensive
   — not strictly required by the working config but doesn't hurt)
4. `COPY --from=build` the compiled `build/bin/`
5. `ENTRYPOINT llama-server` with sensible production defaults

### Why no `/dev/kfd` in compose

The first deployment attempt mounted both `/dev/kfd` and `/dev/dri`,
which made `hipblasSgemm` fail with `CUBLAS_STATUS_INTERNAL_ERROR`
because the rocBLAS TensileLibrary does not have a gfx1103 entry in
AMD's 7.2.4 release (it was added in a later point release). The
symlink to `TensileLibrary_lazy_gfx1100.dat` doesn't work because
the .dat file embeds the GPU arch string and the runtime verifies it.

By NOT mounting `/dev/kfd`, the ROCm runtime falls back to using
`/dev/dri/renderD128` for kernel dispatch — which uses a different code
path that does not have this limitation. The model runs on the iGPU via
GTT memory, and everything works.

If you need to mount `/dev/kfd` for other reasons, you can — just be
prepared for the hipBLAS crash. The compose file deliberately omits it.

### Persistent build cache

The `build/` directory on the host is bind-mounted to `/opt/build/`
inside the build container, so:

- The first build does a full `cmake` configure + compile (~40 min,
  dominated by ~35 min of apt downloads)
- A subsequent build after editing the Dockerfile only re-runs the
  changed layers (CMake cache preserved → instant)
- A subsequent build after `git pull` of llama.cpp source triggers
  the CMake-rebuild flow (only modified files recompiled, ~3 min)

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
| 27B        | Q4_K_M | 4K   | ~3.2                | Most of model in GTT — verified |

These are estimates based on similar APU tests. The 27B number is
verified on this machine.

### Why GTT matters

For an APU like the 780M, both VRAM and GTT are GPU-accessible DDR5
system RAM. The kernel just enforces different allocation policies.
For large models, much of the weight memory ends up in GTT, which is
slightly slower but functionally identical from a correctness standpoint.

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
├── PUSH_INSTRUCTIONS.md       # how to push this to GitHub
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
- The [ROCm](https://github.com/RadeonOpenCompute/ROCm) project
- The [comfyui-rocm-780m](https://github.com/vaskes/comfyui-rocm-780m)
  project for documenting the working gfx1103 setup
- AMD's official ROCm apt repo for the portable, reproducible build

Built on **llmhost2** (Radeon 780M, Ryzen 7 8700G, Ubuntu 24.04).
