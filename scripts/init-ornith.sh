#!/bin/bash
# init-ornith.sh — start the Ornith 1.5 35B A3B Uncensored Q8_0 service
#
# Mirrors the params of /etc/systemd/system/llama-ornith.service but runs
# the same `llama.cpp-rocm-780m:7.13` Docker image (with native gfx1103
# ROCm backend, no HSA_OVERRIDE_GFX_VERSION).
#
# Run this manually when you want the model up. Does NOT enable systemd —
# the systemd unit (if any) is the host-side equivalent; this is the
# containerized equivalent.
#
# Usage:
#   ./scripts/init-ornith.sh            # start
#   ./scripts/init-ornith.sh stop       # stop
#   ./scripts/init-ornith.sh restart    # stop + start
#   ./scripts/init-ornith.sh status     # show state + health
#   ./scripts/init-ornith.sh logs       # tail -f logs
#   ./scripts/init-ornith.sh shell      # bash inside container
#   ./scripts/init-ornith.sh test       # smoke-test API
#
# Container name: llama-ornith
# Image:          llama.cpp-rocm-780m:7.13
# Host port:      8080  (same as Qwen — they never run at the same time.
#                          Override with LLAMA_ORNITH_HOST_PORT if needed.)
# Container port: 8080
# GPU:            /dev/dri only (NOT /dev/kfd — see OPERATIONS.md)

set -e

CONTAINER_NAME="llama-ornith"
IMAGE="llama.cpp-rocm-780m:7.13"
HOST_PORT="${LLAMA_ORNITH_HOST_PORT:-8080}"
CONTAINER_PORT=8080

MODELS_DIR_HOST="/opt/models"
MODELS_DIR_CONT="/models"
MODEL_FILE="Ornith-1.5-35B-A3B-Uncensored-Q8_0.gguf"
MMPROJ_FILE="mmproj-Ornith-1.5-35B-A3B-Uncensored-f16.gguf"
MCP_CONFIG_HOST="/opt/search/mcp-servers.json"
MCP_CONFIG_CONT="/opt/search/mcp-servers.json"

# Mirror of /etc/systemd/system/llama-ornith.service ExecStart, but
# without Type=simple/User=root/WorkingDirectory/Restart etc — those
# are Docker-isms. Model paths use the container-internal path
# (`/models`) since the host /opt/models is bind-mounted to /models.
LLAMA_ARGS=(
    --model "${MODELS_DIR_CONT}/${MODEL_FILE}"
    --alias "Ornith-1.5-35B-A3B-Uncensored"
    --mmproj "${MODELS_DIR_CONT}/${MMPROJ_FILE}"
    --n-gpu-layers 99
    --ctx-size 524288
    -n -1
    --rope-scaling yarn
    --yarn-orig-ctx 262144
    --rope-freq-scale 2.0
    --override-kv "qwen35moe.context_length=int:524288"
    --cache-type-k q8_0
    --cache-type-v q8_0
    --cache-ram 0
    --parallel 1
    --no-warmup
    --flash-attn on
    --agent
    --mcp-servers-config "${MCP_CONFIG_CONT}"
    --jinja
    -b 256
    --keep -1
    --host 0.0.0.0
    --port "${CONTAINER_PORT}"
    --image-min-tokens 1024
    --cors-origins "*"
)

# Sanity checks (use HOST paths here)
for f in "${MODELS_DIR_HOST}/${MODEL_FILE}" "${MODELS_DIR_HOST}/${MMPROJ_FILE}" "${MCP_CONFIG_HOST}"; do
    if [ ! -e "$f" ]; then
        echo "ERROR: required file not found: $f" >&2
        exit 1
    fi
done

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker not in PATH" >&2
    exit 1
fi

# Helper: ensure user is in the docker group (or root) so sg isn't needed
if ! docker info >/dev/null 2>&1; then
    if command -v sg >/dev/null 2>&1 && getent group docker >/dev/null 2>&1; then
        # Re-exec under `sg docker` if available
        exec sg docker -c "$0 $*"
    fi
    echo "ERROR: cannot talk to docker daemon (need root or docker group)" >&2
    exit 1
fi

cmd="${1:-start}"

# Stop helper
do_stop() {
    if docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
        echo "Stopping ${CONTAINER_NAME}..."
        docker rm -f "${CONTAINER_NAME}" >/dev/null
        echo "  removed."
    else
        echo "${CONTAINER_NAME} not running."
    fi
}

# Start helper
do_start() {
    # Refuse to start if another container holds the host port
    if docker ps --format '{{.Names}} {{.Ports}}' | grep -E "\b${HOST_PORT}:" | grep -vq "${CONTAINER_NAME}"; then
        echo "ERROR: host port ${HOST_PORT} already in use by another container" >&2
        docker ps --format 'table {{.Names}}\t{{.Ports}}' | grep "${HOST_PORT}:" || true
        exit 1
    fi

    # If a stopped container with our name exists, drop it so --rm semantics
    # are clean
    if docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
        docker rm "${CONTAINER_NAME}" >/dev/null
    fi

    echo "Starting ${CONTAINER_NAME} (${IMAGE}) on host :${HOST_PORT} -> container :${CONTAINER_PORT}"
    docker run -d \
        --name "${CONTAINER_NAME}" \
        --restart=no \
        --device /dev/dri \
        --group-add 992 \
        --group-add 44 \
        --security-opt seccomp=unconfined \
        --cap-add SYS_PTRACE \
        --shm-size 8g \
        -v /opt/models:/models:ro \
        -v /opt/search:/opt/search:ro \
        -v /opt/node20:/opt/node20:ro \
        -e "HSA_ENABLE_SDMA=0" \
        -e "HSA_USE_SVM=0" \
        -e "GGML_HIP_GRAPHS=0" \
        -p "${HOST_PORT}:${CONTAINER_PORT}" \
        "${IMAGE}" \
        "${LLAMA_ARGS[@]}"

    echo "  container started, id=$(docker ps --filter "name=${CONTAINER_NAME}" --format '{{.ID}}')"
    echo
    echo "API:    http://127.0.0.1:${HOST_PORT}"
    echo "Logs:   $0 logs"
    echo "Test:   $0 test"
}

case "$cmd" in
    start)
        do_start
        ;;
    stop)
        do_stop
        ;;
    restart)
        do_stop
        do_start
        ;;
    status)
        if docker ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
            echo "${CONTAINER_NAME}: UP"
            docker ps --filter "name=${CONTAINER_NAME}" --format 'table {{.ID}}\t{{.Status}}\t{{.Ports}}'
            echo
            echo "Health:"
            docker inspect --format '{{.State.Health.Status}}' "${CONTAINER_NAME}" 2>/dev/null || echo "  no healthcheck"
            echo
            echo "GPU (inside container):"
            docker exec "${CONTAINER_NAME}" rocm-smi 2>&1 | grep -E '^\s*0\s|^\s*=' | head -5
        else
            echo "${CONTAINER_NAME}: DOWN"
        fi
        ;;
    logs)
        docker logs -f "${CONTAINER_NAME}" 2>&1 | tail -n +1
        ;;
    shell)
        if ! docker ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
            echo "${CONTAINER_NAME} not running." >&2
            exit 1
        fi
        docker exec -it "${CONTAINER_NAME}" /bin/bash
        ;;
    test)
        if ! docker ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
            echo "${CONTAINER_NAME} not running." >&2
            exit 1
        fi
        echo "→ http://127.0.0.1:${HOST_PORT}/v1/models:"
        curl -s "http://127.0.0.1:${HOST_PORT}/v1/models" | head -c 400
        echo
        echo
        echo "→ chat completion (Say hi in 5 words.):"
        curl -s -X POST "http://127.0.0.1:${HOST_PORT}/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d '{
              "model": "any",
              "messages": [{"role": "user", "content": "Say hi in 5 words."}],
              "max_tokens": 80
            }' | python3 -m json.tool 2>/dev/null || \
        curl -s -X POST "http://127.0.0.1:${HOST_PORT}/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d '{
              "model": "any",
              "messages": [{"role": "user", "content": "Say hi in 5 words."}],
              "max_tokens": 80
            }'
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|logs|shell|test}" >&2
        exit 2
        ;;
esac
