#!/bin/bash
# Stop the llama-server container (keeps image and data)
set -e
cd "$(dirname "$0")/.."
docker compose down
echo "Stopped. Start with: $0 start"
