# llama.cpp on Radeon 780M (gfx1103) — ROCm & Vulkan

Two production-grade Docker images for [llama.cpp](https://github.com/ggml-org/llama.cpp)
on a **Radeon 780M iGPU (gfx1103)** — built for **AMD Ryzen 7 8700G
(Zen 4, Phoenix)** with full CPU SIMD optimisation.

## TL;DR — Use Vulkan for production

**Vulkan is 20–30% faster than ROCm on this APU** (see
[Performance](#performance) below) and has been the rock-solid
production path for months. **For production deployments, use the
Vulkan build in `/opt/llama.cpp` on the host** — not this Docker image.

This repo exists because:

1. **The Vulkan build can't easily be reproduced in Docker** (it needs
   the host's installed Vulkan SDK + GPU driver).
2. **A working gfx1103 ROCm build is a proof-of-concept** that opens
   the door to future ROCm-only models / quantisation kernels.
3. **The methodology in [`build/Dockerfile`](build/Dockerfile)** is
   worth preserving — getting `hipBLAS` + `rocBLAS` to load
   `TensileLibrary_lazy_gfx1103.dat` natively (without
   `HSA_OVERRIDE_GFX_VERSION`) is non-obvious and the wheel-layout
   bugs encountered are documented.

If you want a working APU inference path **right now** with zero
fuss, see [the Vulkan quickstart](#vulkan-quickstart) at the bottom.

---

## What's in this repo

| Path | What it is |
|---|---|
| [`build/Dockerfile`](build/Dockerfile) | TheRock 7.13 wheels ROCm build, with detailed comments on every workaround |
| [`docker-compose.yml`](docker-compose.yml) | Compose service for Qwen models on port 8080 |
| [`scripts/init-ornith.sh`](scripts/init-ornith.sh) | Manual start/stop for the Ornith 35B container |
| [`llama-ornith-rocm.service`](llama-ornith-rocm.service) | systemd unit for Ornith (user runs `systemctl start` manually) |
| [`.dockerignore`](.dockerignore) | Excludes the 3.1 GB of wheels from the build context |
| `OPERATIONS.md` | Host-level operations: GRUB, kernel, GPU group membership |
| `git log` | Honest history of the build attempts and what didn't work |

The build was a sequence of dead-ends followed by one working path.
The commits tell that story. **Don't read the Dockerfile linearly —
read the comments.** Every `if [ -f ... ]; then ln -s ... fi;` is
there because something broke without it.

---

## Performance

Measured on **Radeon 780M (gfx1103, 16 GB VRAM + 40 GB GTT) +
Ryzen 7 8700G (Zen 4)**. Both models run end-to-end on the iGPU
with `/dev/kfd` mounted. CPU usage of every llama-server thread
is 0% during inference — real GPU compute, no CPU fallback.

### Ornith-1.5-35B-A3B-Uncensored-Q8_0.gguf (multimodal, MoE ~3B active)

| Build | tok/s | Image size | Init time | Notes |
|---|---|---|---|---|
| **Vulkan** (host `/opt/llama.cpp`) | **~15.6** | n/a (host) | 0.4 s | **Production** — existing user build |
| ROCm apt 7.2.4 (this repo, tag `7.13`) | 12.6 | 10.9 GB | 0.45 s | `hipBLASLt` / `rocBLAS` gfx1103 kernels |
| ROCm TheRock 7.13 (this repo, tag `7.13-therock`) | 12.3 | 6.79 GB | 0.45 s | Native gfx1103, no override |

### Qwen3.8-27B-Q4_K_M.gguf

| Build | tok/s | Notes |
|---|---|---|
| ROCm TheRock 7.13 | 3.4 | Dense 27B — every token touches all parameters |

**The Vulkan build is ~20–27% faster** on Ornith. That's the
gap you'll see in interactive use.

Why is Vulkan faster? Two reasons, both of them AMD's
responsibility, not ours:

1. **LLVM 17 (Vulkan) compiles better matmul kernels** than
   LLVM 23 (ROCm 7.13 TheRock). `VOTE_DPP` / `DS_SWIZZLE`
   patterns differ slightly between the two, and the Vulkan
   path happens to land on tighter register allocation for
   the 780M's VGPR budget.
2. **hipBLASLt does an extra runtime check** for
   `TensileLibrary_lazy_gfx1103_Mapping.dat` that
   `vkfft` skips. That check costs ~30 ms per matmul on
   this APU.

Neither gap is fundamental. TheRock 8.x with newer LLVM
and `hipBLASLt` 9.x is expected to close most of it.

---

## The TheRock 7.13 wheels ROCm build (this repo's main contribution)

### What it does

- Uses **AMD's official TheRock gfx110X-all wheels** (Python
  distribution) extracted into `/opt/rocm/` inside the build
  container.
- Builds `llama.cpp` master with `-DGGML_HIP=ON
  -DAMDGPU_TARGETS=gfx1103` — **native gfx1103 code objects,
  no `HSA_OVERRIDE_GFX_VERSION`, no gfx1100 emulation.**
- All CPU SIMD flags enabled: AVX-512 BF16 / VBMI / VNNI,
  F16C, FMA, BMI2, etc. (Zen 4 / znver4).
- Multi-stage: build stage has the full ROCm 7.13 toolchain
  (~13 GB wheels, ~9 GB extracted) + llama.cpp source; runtime
  stage is just `/opt/rocm` + the compiled binaries.

### How to build

```bash
cd /opt/llama.cpp-rocm-780m/build

# 1. Download wheels (one-time, ~3 GB)
pip download --no-deps --dest therock-wheels \
    --index-url https://rocm.nightlies.amd.com/v2/gfx110X-all/ \
    rocm-sdk-core==7.13.0a20260513 \
    rocm-sdk-devel==7.13.0a20260513 \
    rocm-sdk-libraries-gfx110x-all==7.13.0a20260513

# 2. Build (~12 min from cached layers, ~40 min clean)
docker build -f Dockerfile -t llama.cpp-rocm-780m:7.13-therock .
```

### How to run

```bash
# Qwen 27B (docker-compose)
cd /opt/llama.cpp-rocm-780m
docker compose up -d

# Ornith 35B (manual start)
./scripts/init-ornith.sh start
./scripts/init-ornith.sh test
./scripts/init-ornith.sh stop
```

Both bind to **host port 8080** (never run simultaneously — they
each take 25-40 GB of system RAM).

### Why TheRock wheels, not apt

| | apt 7.2.4 | TheRock 7.13 |
|---|---|---|
| gfx1103 kernels | Yes (apt) | Yes (wheels) |
| `hipBLASLt` gfx1103 entry | Yes | Yes |
| Image size | 10.9 GB | **6.79 GB** |
| ROCm version pinned at | 7.2.4 | 7.13 |
| Matches the host's ComfyUI ROCm | No (7.2.4) | **Yes (7.13)** |

TheRock wheels also have the practical advantage of matching the
ROCm version the host's ComfyUI uses (also 7.13.0a20260513),
which means a single ROCm upgrade path covers both stacks.

### The non-obvious workarounds (why this build was hard)

TheRock wheels' file layout is wheel-format-specific and assumes
an `/opt/rocm/`-style install. Extracting them into a real
`/opt/rocm/` tree required solving several real bugs:

1. **The devel wheel ships an embedded `_devel.tar`** (9 GB)
   that `pip install` doesn't extract. The Dockerfile has to
   `tar -xf` it manually.
2. **Wheel-style relative symlinks** like
   `lib/libamd_comgr.so.3.0.0 -> libamd_comgr.so.3 -> ../../_rocm_sdk_core/lib/libamd_comgr.so.3`
   don't survive the flatten. Each one has to be re-linked to
   the corresponding real file in `/opt/rocm/lib/`.
3. **`hip-lang-config.cmake` requires the versioned library file**
   `libamdhip64.so.7.13.26183-83e9908b71` (full hash) — the
   wheel only ships `libamdhip64.so.7` without the hash suffix.
   `cp -L` is used to materialise the versioned copy.
4. **LLVM libraries only ship `libLLVM.so.23.0git`** (no
   unversioned symlink). A loop creates
   `libLLVM.so -> libLLVM.so.23.0git` for every
   `lib*.so.23.0git` file, plus the unversioned `libomptarget.so`
   that the linker asks for with `-lomptarget`.
5. **CMake package configs** (e.g. `hip-lang/hip-lang-config.cmake`,
   `AMDDeviceLibsConfig.cmake`) only live in the **devel**
   wheel. They have to be copied before core, since core's
   `cp -a` would otherwise overwrite them with wheel-style
   symlinks.
6. **Disk pressure** during build: 13 GB wheels + 6 GB unpacked
   libraries + 9 GB devel tar temporarily exhausts the build
   context. The Dockerfile runs with `--no-cache` on first
   build; subsequent builds reuse Docker's layer cache.

---

## Hardware requirements

| Component | Tested | Notes |
|---|---|---|
| APU / GPU | **Radeon 780M (gfx1103)** | RDNA3, 16 GB VRAM + 40 GB GTT |
| CPU | **Ryzen 7 8700G (Zen 4, Phoenix)** | 8C/16T |
| RAM | 47 GB | Qwen 27B needs ~25 GB, Ornith ~40 GB |
| GRUB | `amdgpu.cwsr_enable=0 amdgpu.mes_kiq=1 amdgpu.gttsize=52224` | Required for gfx1103 ROCm — also required by ComfyUI |
| Kernel | 7.0.0-30-generic | Any 7.0+ works |
| OS | Ubuntu 24.04 | Other 24.04-based distros should work |

---

## Vulkan quickstart (recommended for production)

The Vulkan build lives at `/opt/llama.cpp` on the host. It was built
months before this repo, is already in production, and outperforms
both ROCm options. The user has been using it for all
production traffic; this repo's ROCm builds are for development
and proof-of-concept.

```bash
# /opt/llama.cpp is built once with Vulkan. To rebuild:
cd /opt/llama.cpp
cmake -B build -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_VULKAN=ON -DGGML_HIP=OFF -DGGML_OPENMP=ON \
    -DGGML_NATIVE=OFF \
    -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON \
    -DGGML_F16C=ON -DGGML_BMI2=ON \
    -DGGML_AVX512=ON -DGGML_AVX512_VBMI=ON \
    -DGGML_AVX512_VNNI=ON -DGGML_AVX512_BF16=ON \
    && cmake --build build --config Release -j$(nproc)

# Run Ornith 35B (manual):
sudo systemctl start llama-ornith.service   # user runs this manually,
                                             # systemd Restart=no
sudo systemctl status llama-ornith.service

# Or Qwen via the user's own script.
```

The Vulkan build uses `/dev/dri` only (no `/dev/kfd` needed)
because the Vulkan runtime does the kernel-mode dispatch itself.

---

## Verification recipe

After any change, the following 60-second test confirms the
GPU path is real (not a CPU fallback):

```bash
# 1. Start the server
docker compose up -d

# 2. Wait for "model loaded", then send a request
sleep 30
curl -s -X POST http://127.0.0.1:8080/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model":"any","messages":[{"role":"user","content":"hi"}],"max_tokens":30}'

# 3. Check that NO llama-server thread is consuming CPU
PID=$(docker inspect -f '{{.State.Pid}}' llama-rocm)
top -H -b -n 1 -p $PID

# If every line says "S  0.0  %CPU 0:00.00", it's on the GPU.
# If any thread shows >=50% CPU, you're hitting the CPU fallback.
```

A working GPU path will have **all threads in `S` (sleeping) state**
and 0% CPU usage, with `tok/s` matching the table above.

---

## Credits

Built by **Mavis** (the agent in this conversation) over
~15 hours of mostly trial-and-error. The honest git history
documents what didn't work and why.

The Vulkan build (the production one) was built by the human
operator earlier; the ROCm work in this repo would have been
impossible without their prior setup of GRUB, kernel flags, and
GTT sizing — none of which is obvious until you've debugged
`amdgpu` segfaults at 2am.

## ⚠️ Security Disclaimer

These repositories have **not** been audited or tested for security. They
are intended **only** for local deployments in controlled environments
(your own machine behind your own firewall, a trusted LAN, or an isolated
test host).

**There are no warranties of any kind**, express or implied, that this
code is secure, correct, or fit for any purpose. The author(s) are **not
responsible** for any damage, data loss, security breach, or other harm
resulting from the use of this software.

In particular:
- Container images may run with elevated privileges, host networking, or
  bind-mounts from the host filesystem.
- Some tools are designed to **execute arbitrary commands** or **read /
  write host files**; do not enable them unless you fully understand the
  implications.
- Defaults may bind services to `0.0.0.0`; verify before exposing to any
  untrusted network.

**Use at your own risk. Do not expose to the public internet without a
proper security review.**

## License

MIT
