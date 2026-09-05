#!/bin/bash
# Tail llama-server logs
set -e
cd "$(dirname "$0")/.."
LINES="${1:-100}"
docker compose logs --tail=$LINES -f llama-server
