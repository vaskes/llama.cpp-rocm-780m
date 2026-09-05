# Operations Cheatsheet

Day-to-day management of llama.cpp on llmhost2 (Radeon 780M, gfx1103).

## TL;DR

```bash
# Status
docker ps | grep llama-rocm
curl -s http://127.0.0.1:8080/v1/models | head

# Start / stop / restart
cd /opt/llama.cpp-rocm-780m
./scripts/start.sh
./scripts/stop.sh
./scripts/restart.sh

# Logs
./scripts/logs.sh               # tail -f
./scripts/logs.sh 500            # last 500 lines

# Shell into the container
./scripts/shell.sh

# Smoke test the API
./scripts/test-api.sh "Hello world"
```

## What's where

| Path | What's in it |
|---|---|
| `/opt/llama.cpp-rocm-780m/` | Git repo, source of truth |
| `/opt/llama.cpp-rocm-780m/build/` | CMake build cache (bind-mounted into container) |
| `/opt/llama.cpp-rocm-780m/logs/` | llama-server stdout/stderr (bind-mounted) |
| `/opt/models/` | Host GGUF models, read-only into container as `/models/` |
| `/opt/llama.cpp/build/bin/` | The compiled `llama-server`, `llama-cli`, etc. (inside container) |

## Container

| | |
|---|---|
| Name | `llama-rocm` |
| Image | `llama.cpp-rocm-780m:7.13` (10.7 GB on disk, 3.25 GB compressed) |
| Command | `llama-server` with `--model`, `--ctx-size 32768`, `--n-gpu-layers 99`, `--cache-type-k q8_0`, `--cache-type-v q8_0`, `--flash-attn auto`, `--jinja` |
| Env | `HSA_ENABLE_SDMA=0`, `HSA_USE_SVM=0` |
| GPU | `/dev/dri` (NOT /dev/kfd — see "Why no /dev/kfd" below) + GID 992 (render), 44 (video) |
| Network | bridge, port 8080:8080 (same as Ornith unit — never run together) |
| Restart | `unless-stopped` |
| Models | bind-mounted from `/opt/models` (read-only) |

## How it's built

- **Base**: `ubuntu:24.04` (noble)
- **ROCm**: AMD's official apt repo `https://repo.radeon.com/rocm/apt/7.2.4 noble main` (pinned above Ubuntu)
- **Compiler**: `gcc 13.3.0` for host C/C++, `/opt/rocm/llvm/bin/clang++` for HIP
- **CPU ISA**: `-march=znver4 -mtune=znver4` (AVX-512 BF16/VBMI/VNNI enabled)
- **GPU ISA**: `AMDGPU_TARGETS="gfx1103"` — **native**, no `HSA_OVERRIDE_GFX_VERSION`
- **llama.cpp ref**: `master` (build via `git clone --depth 1`)

The build is reproducible and works on any Ubuntu 24.04 host — no host
ROCm install required, no Python wheel hacks, no symlink gymnastics.

## Why no /dev/kfd in the device list

The docker-compose mounts only `/dev/dri`, not `/dev/kfd`. This is
intentional and matches the working configuration on the host.

When you mount `/dev/kfd` into the container, the ROCm runtime (hipBLAS)
uses the KFD path for kernel dispatch — which on gfx1103 (Radeon 780M)
fails because the **rocBLAS TensileLibrary does not have a gfx1103 entry**
in AMD's 7.2.4 release (it was added in a later point release). The
symlink fallback to `TensileLibrary_lazy_gfx1100.dat` doesn't work
because the .dat file embeds the GPU arch string and the runtime
verifies it.

By NOT mounting `/dev/kfd`, the ROCm runtime falls back to using
`/dev/dri/renderD128` for kernel dispatch — which uses a different code
path that does not have this limitation. The model runs on the iGPU via
GTT (Graphics Translation Table) memory, and everything works.

Verified: 3.2-3.3 tokens/sec for Qwen3.8-27B-Q4_K_M (iGPU-bound), 18-26
prompt tokens/sec, no crashes, no kernel hangs.

## Quick commands

### Service management

```bash
# Via compose
docker compose -f /opt/llama.cpp-rocm-780m/docker-compose.yml ps
docker compose -f /opt/llama.cpp-rocm-780m/docker-compose.yml up -d
docker compose -f /opt/llama.cpp-rocm-780m/docker-compose.yml restart
docker compose -f /opt/llama.cpp-rocm-780m/docker-compose.yml down

# Direct
docker ps | grep llama-rocm
docker logs -f llama-rocm
docker restart llama-rocm
docker exec -it llama-rocm bash
docker rm -f llama-rocm    # data persists in /opt/models
```

### Test the API

```bash
# List models
curl -s http://127.0.0.1:8080/v1/models

# Chat completion (OpenAI-compatible)
curl -s -X POST http://127.0.0.1:8080/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{
      "model": "any",
      "messages": [{"role": "user", "content": "Say hi in 5 words."}],
      "max_tokens": 50
    }'
```

### Monitor GPU

```bash
# One-shot (on host)
rocm-smi
cat /sys/class/drm/card0/device/mem_info_vram_used
cat /sys/class/drm/card0/device/mem_info_gtt_used

# Inside the container (rocm-smi works there too)
docker exec llama-rocm rocm-smi

# Continuous
watch -n 1 'rocm-smi; echo ---; cat /sys/class/drm/card0/device/mem_info_{vram,gtt}_used'
```

### Update llama.cpp source

```bash
cd /opt/llama.cpp-rocm-780m
# Edit the pinned ref in build/Dockerfile, then:
docker compose build
docker compose up -d
```

### Update ROCm version

Edit `build/Dockerfile` (search for `rocm/apt/`), change to a newer
release (e.g. `7.3.0`):

```bash
cd /opt/llama.cpp-rocm-780m
sed -i 's|rocm/apt/7.2.4|rocm/apt/7.3.0|' build/Dockerfile
docker compose build --no-cache
docker compose up -d
```

## Known issues

1. **GRUB fix REQUIRED** — `amdgpu.cwsr_enable=0` in `/proc/cmdline`.
   Without it, KFD-queue-eviction triggers a gfx1103 MES firmware bug
   and inference hangs. Verify with:
   ```bash
   cat /proc/cmdline | grep cwsr_enable=0
   ```

2. **HSA_ENABLE_SDMA=0 is REQUIRED for gfx1103 APU** — SDMA
   (system DMA) hits an MMIO quirk on integrated GPUs and crashes
   the kernel driver. The compose file sets this automatically.

3. **HSA_USE_SVM=0 is REQUIRED for 8700G** — SVM pinned memory
   allocation hangs the KFD on Phoenix. Already in compose.

4. **Container does NOT mount /dev/kfd** — see "Why no /dev/kfd" above.
   If you mount it, the rocBLAS will fail to find a gfx1103 TensileLibrary
   and hipblasSgemm will return CUBLAS_STATUS_INTERNAL_ERROR.

5. **The gfx1103 symlink in the Dockerfile is a defensive measure** —
   it creates `TensileLibrary_lazy_gfx1103.dat -> TensileLibrary_lazy_gfx1100.dat`
   in case some code path looks for it. It's not needed for the
   /dev/dri-only flow but it doesn't hurt.

6. **No 7.14 wheels / 7.14 apt** — 7.14.0+ has an InitDma segfault regression
   on gfx1103. The Dockerfile pins 7.2.4 (the AMD-stable release line).

7. **The `rocm-smi --showallinfo` field `amd_iommu=off` is FORBIDDEN**
   — stability-critical, do NOT add to GRUB.

8. **No kernel changes** — fixes must work with 7.0.0-30-generic. Do
   not upgrade the kernel without first checking if newer amdgpu fixes
   the gfx1103 hang properly.

9. **First build is slow (~40 min)** — apt downloads 1.6 GB of ROCm
   packages, then compiles 690 HIP object files (~2.5 min). Subsequent
   rebuilds with no source change are near-instant.

## Backup of original GRUB config

If you have a `grub-backup/` directory in your checkout, that's the
backup of the GRUB cmdline BEFORE applying `cwsr_enable=0`. Keep it
safe.

## When things go wrong

### Server doesn't start (exit code 139)

Almost always one of:
- GRUB fix missing (`cwsr_enable=0`)
- /dev/dri not accessible (check GID 992 in `id git` on the host)
- Wrong ROCm version in the Dockerfile

### Server starts but `hipblasSgemm ... CUBLAS_STATUS_INTERNAL_ERROR`

You mounted `/dev/kfd` in docker-compose. Remove it — see "Why no /dev/kfd" above.

### Server starts but `hipMalloc` segfaults

You're either on 7.14 (roll back), or the image was built without
the apt pin (so it pulled 5.7.1 from Ubuntu instead of 7.2.4 from
AMD). Verify with:
```bash
docker exec llama-rocm ls /opt/rocm/.info
# Should list 7.2.4
```

### "device kernel image is invalid" in logs

Wrong code object / runtime version mismatch. Rebuild the image
without using cached layers:
```bash
docker compose build --no-cache
```

### Server hangs after a few tokens

Gfx1103 KFD MES hang. Verify the GRUB fix is still in place after
any host reboot:
```bash
cat /proc/cmdline | tr ' ' '\n' | grep amdgpu
```

If `cwsr_enable=0` is missing, re-apply it and reboot.

### "/opt/llama.cpp/build/bin/llama-server: error while loading shared libraries: libgomp.so.1"

Should not happen with this image (libgomp1 is in the runtime layer).
If you see it, the image was built from an older Dockerfile — rebuild
or `docker pull`.

### "/opt/llama.cpp/build/bin/llama-server: error while loading shared libraries: libomp.so"

Same — handled by the `libomp5-19` + symlink in the runtime layer.
Rebuild or `docker pull` if it appears.

### "warning: consult docs/build.md for compilation instructions" + "unknown value for --flash-attn: '--jinja'"

Your llama-server version is newer than your compose file expected.
Add a value to `--flash-attn` (e.g. `--flash-attn auto`).

## Build performance notes

- First build: ~40 min (apt download ~35 min + cmake/ninja compile ~2.5 min + ~2 min misc)
- Incremental build (only source changed): ~30 seconds (only the changed files recompile)
- The `build/` bind-mount keeps the CMake cache across `docker build`
  runs — if you wipe it, the next build does a full cmake reconfigure
  (adds ~10 seconds)

## Performance measurements (Qwen3.8-27B-Q4_K_M)

Measured on llmhost2 (8700G, 16GB VRAM allocated to iGPU):

| Metric | Value |
|---|---|
| Model load | ~7 sec |
| Prompt eval | 18-26 tokens/sec |
| Token generation | 3.2-3.3 tokens/sec |
| VRAM usage | 14-15 GB (model) |
| KV cache (q8_0) | ~1 GB at 32k context |
