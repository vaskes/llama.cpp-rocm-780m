# Operations Cheatsheet

Day-to-day management of llama.cpp on llmhost2 (Radeon 780M, gfx1103).

## TL;DR

```bash
# Status
docker ps | grep llama-rocm
curl -s http://127.0.0.1:8082/v1/models | head

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
| Image | `llama.cpp-rocm-780m:7.13` (~1.4 GB) |
| Command | `llama-server` with `--model`, `--ctx-size 32768`, `--n-gpu-layers 99`, `--cache-type-k q8_0`, `--cache-type-v q8_0`, `--flash-attn`, `--jinja` |
| Env | `HSA_ENABLE_SDMA=0`, `HSA_USE_SVM=0` |
| GPU | `/dev/kfd`, `/dev/dri` + GID 992 (render), 44 (video) |
| Network | bridge, port 8082:8080 |
| Restart | `unless-stopped` |
| Models | bind-mounted from `/opt/models` (read-only) |

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
curl -s http://127.0.0.1:8082/v1/models

# Chat completion (OpenAI-compatible)
curl -s -X POST http://127.0.0.1:8082/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{
      "model": "any",
      "messages": [{"role": "user", "content": "Say hi in 5 words."}],
      "max_tokens": 50
    }'

# Text completion
curl -s -X POST http://127.0.0.1:8082/v1/completions \
    -H "Content-Type: application/json" \
    -d '{"model": "any", "prompt": "Once upon a time", "max_tokens": 50}'
```

### Monitor GPU

```bash
# One-shot
rocm-smi
cat /sys/class/drm/card0/device/mem_info_vram_used
cat /sys/class/drm/card0/device/mem_info_gtt_used

# Continuous
watch -n 1 'rocm-smi; echo ---; cat /sys/class/drm/card0/device/mem_info_{vram,gtt}_used'
```

### Update llama.cpp source

```bash
cd /opt/llama.cpp-rocm-780m
# Source is baked into the image; to pick up new commits, rebuild:
docker compose build
docker compose up -d

# If only the build/ CMake cache is needed (faster):
# Just re-run the build stage — Dockerfile will use the cached layers
```

### Update ROCm wheels

Edit `build/Dockerfile`, change `ROCK_VER`, rebuild:

```bash
cd /opt/llama.cpp-rocm-780m
sed -i 's/ROCK_VER=7.13.0a20260513/ROCK_VER=<new-version>/' build/Dockerfile
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

2. **7.14 wheels don't work** — The latest TheRock wheels (7.14.x) have
   a regression on gfx1103. Stay on 7.13.0a20260513 for now.

3. **TheRock wheel download is large** — first build downloads ~3.2 GB
   of wheels. The runtime image is only ~1.4 GB (only core + libraries,
   not devel).

4. **Container runs as root** — for simplicity. The render/video GIDs are
   added so /dev/kfd and /dev/dri are accessible.

5. **The `rocm-smi --showallinfo` field `amd_iommu=off` is FORBIDDEN**
   — stability-critical, do NOT add to GRUB.

6. **No kernel changes** — fixes must work with 7.0.0-30-generic. Do
   not upgrade the kernel without first checking if newer amdgpu fixes
   the gfx1103 hang properly.

## Backup of original GRUB config

If you have a `grub-backup/` directory in your checkout, that's the
backup of the GRUB cmdline BEFORE applying `cwsr_enable=0`. Keep it
safe.

## When things go wrong

### Server doesn't start (exit code 139)

Almost always one of:
- GRUB fix missing (`cwsr_enable=0`)
- /dev/kfd not accessible (check GID 992)
- Wrong ROCm wheels version (use 7.13)

### Server starts but `hipMalloc` segfaults

You're on 7.14 wheels. Roll back to 7.13.0a20260513.

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
