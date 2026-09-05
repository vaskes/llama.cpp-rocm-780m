#!/bin/bash
# Smoke-test the llama-server OpenAI-compatible API
# Usage: ./scripts/test-api.sh [prompt]
set -e
PROMPT="${1:-Say hi in 5 words.}"
HOST="${LLAMA_HOST:-http://127.0.0.1:8082}"

echo "→ $HOST/v1/models:"
curl -s "$HOST/v1/models" | head -c 500
echo
echo
echo "→ $HOST/v1/chat/completions:"
curl -s -X POST "$HOST/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"any\",
      \"messages\": [{\"role\": \"user\", \"content\": \"$PROMPT\"}],
      \"max_tokens\": 80
    }" | python3 -m json.tool 2>/dev/null || \
curl -s -X POST "$HOST/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"any\",
      \"messages\": [{\"role\": \"user\", \"content\": \"$PROMPT\"}],
      \"max_tokens\": 80
    }"
