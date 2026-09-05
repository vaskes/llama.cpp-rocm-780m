#!/bin/bash
# Restart the llama-server container
set -e
cd "$(dirname "$0")/.."
docker compose restart
echo "Restarted. Tail logs: $0 logs"
