#!/bin/bash
# Open a bash shell inside the running llama-server container
set -e
cd "$(dirname "$0")/.."
docker exec -it llama-rocm "${SHELL:-bash}"
