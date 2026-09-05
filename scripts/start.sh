#!/bin/bash
# Start the llama-server container
set -e
cd "$(dirname "$0")/.."
docker compose up -d
echo "Started. Tail logs: $0 logs"
