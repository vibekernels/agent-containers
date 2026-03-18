#!/usr/bin/env bash
set -euo pipefail

RUNPOD_CONFIG="$HOME/.runpod/config.toml"
SSH_KEY="$HOME/.ssh/id_ed25519"
SSH_USER="ubuntu"

# Read API key from runpodctl config
if [ ! -f "$RUNPOD_CONFIG" ]; then
  echo "Error: RunPod config not found at $RUNPOD_CONFIG" >&2
  echo "Run 'runpodctl config --apiKey <key>' first." >&2
  exit 1
fi
API_KEY=$(grep -oP 'api_key\s*=\s*"\K[^"]+' "$RUNPOD_CONFIG" 2>/dev/null || \
          sed -n 's/.*api_key *= *"\([^"]*\)".*/\1/p' "$RUNPOD_CONFIG")

if [ -z "$API_KEY" ]; then
  echo "Error: Could not read API key from $RUNPOD_CONFIG" >&2
  exit 1
fi

# Query RunPod API for pods with SSH port info
QUERY='{ "query": "{ myself { pods { id name desiredStatus runtime { ports { ip isIpPublic privatePort publicPort type } } } } }" }'
RESPONSE=$(curl -s -H "Content-Type: application/json" \
  -H "Authorization: Bearer $API_KEY" \
  -d "$QUERY" \
  https://api.runpod.io/graphql)

# Extract running pods with SSH info (privatePort 22, public IP, tcp)
PODS=$(echo "$RESPONSE" | jq -r '
  .data.myself.pods[]
  | select(.desiredStatus == "RUNNING")
  | . as $pod
  | .runtime.ports[]
  | select(.privatePort == 22 and .isIpPublic == true and .type == "tcp")
  | "\($pod.name)\t\($pod.id)\t\(.ip)\t\(.publicPort)"
')

if [ -z "$PODS" ]; then
  echo "No running pods with SSH access found." >&2
  exit 1
fi

if [ $# -ge 1 ]; then
  # Pod name given as argument — find matching pod
  POD_NAME="$1"
  MATCH=$(echo "$PODS" | grep -i "^${POD_NAME}	" || true)
  if [ -z "$MATCH" ]; then
    # Try partial match
    MATCH=$(echo "$PODS" | grep -i "${POD_NAME}" || true)
  fi
  if [ -z "$MATCH" ]; then
    echo "Error: No running pod matching '$POD_NAME'" >&2
    echo "Available pods:" >&2
    echo "$PODS" | awk -F'\t' '{ printf "  %s (%s)\n", $1, $2 }' >&2
    exit 1
  fi
  # If multiple matches, take the first
  MATCH=$(echo "$MATCH" | head -1)
else
  # No argument — show interactive selection
  echo "Select a pod:" >&2
  LINES=()
  while IFS= read -r line; do
    LINES+=("$line")
  done <<< "$PODS"

  for i in "${!LINES[@]}"; do
    NAME=$(echo "${LINES[$i]}" | cut -f1)
    ID=$(echo "${LINES[$i]}" | cut -f2)
    IP=$(echo "${LINES[$i]}" | cut -f3)
    PORT=$(echo "${LINES[$i]}" | cut -f4)
    printf "  %d) %s  (%s — %s:%s)\n" $((i+1)) "$NAME" "$ID" "$IP" "$PORT" >&2
  done

  printf "Enter number [1-%d]: " "${#LINES[@]}" >&2
  read -r CHOICE
  if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt "${#LINES[@]}" ]; then
    echo "Invalid selection." >&2
    exit 1
  fi
  MATCH="${LINES[$((CHOICE-1))]}"
fi

IP=$(echo "$MATCH" | cut -f3)
PORT=$(echo "$MATCH" | cut -f4)
NAME=$(echo "$MATCH" | cut -f1)

echo "Connecting to $NAME ($IP:$PORT)..." >&2
exec ssh "$SSH_USER@$IP" -p "$PORT" -i "$SSH_KEY"
