#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNPOD_CONFIG="$HOME/.runpod/config.toml"
SSH_KEY="$HOME/.ssh/id_ed25519"

# Defaults
GPU_TYPE="4090"
VOLUME_SIZE=20
CONTAINER_DISK=20
POD_VOLUME=0

usage() {
  cat <<EOF
Usage: launchpod.sh [<repo>] [--gpu 4090|5090|h100] [--volume <gb>]

Launch a RunPod instance and run agentize.sh on it.

Arguments:
  <repo>          GitHub SSH URL (e.g. git@github.com:org/repo.git)
                  If omitted, shows an interactive picker of vibekernels repos.
  --gpu TYPE      GPU type: 4090 (default), 5090, h100
  --volume GB     Network volume size in gigabytes (default: 20)

Examples:
  launchpod.sh
  launchpod.sh git@github.com:org/repo.git
  launchpod.sh git@github.com:org/repo.git --gpu h100
  launchpod.sh --gpu 5090 --volume 100
EOF
  exit 1
}

# Parse arguments
REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --gpu)
      shift
      GPU_TYPE="${1:?--gpu requires a value}"
      shift
      ;;
    --volume)
      shift
      VOLUME_SIZE="${1:?--volume requires a value}"
      shift
      ;;
    --help|-h)
      usage
      ;;
    *)
      if [ -z "$REPO" ]; then
        REPO="$1"
      else
        echo "Error: unexpected argument '$1'" >&2
        usage
      fi
      shift
      ;;
  esac
done

# If no repo specified, show interactive picker from vibekernels org
if [ -z "$REPO" ]; then
  echo "==> Fetching vibekernels repos..."
  REPOS=$(gh repo list vibekernels --limit 100 --json nameWithOwner,description,updatedAt \
    --jq 'sort_by(.updatedAt) | reverse | .[] | "\(.nameWithOwner)\t\(.description // "")"')

  if [ -z "$REPOS" ]; then
    echo "Error: No repos found in vibekernels org (is gh authenticated?)" >&2
    exit 1
  fi

  LINES=()
  while IFS= read -r line; do
    LINES+=("$line")
  done <<< "$REPOS"

  echo "Select a repo:" >&2
  for i in "${!LINES[@]}"; do
    NAME=$(echo "${LINES[$i]}" | cut -f1)
    DESC=$(echo "${LINES[$i]}" | cut -f2)
    if [ -n "$DESC" ]; then
      printf "  %d) %s — %s\n" $((i+1)) "$NAME" "$DESC" >&2
    else
      printf "  %d) %s\n" $((i+1)) "$NAME" >&2
    fi
  done

  printf "Enter number [1-%d]: " "${#LINES[@]}" >&2
  read -r CHOICE
  if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt "${#LINES[@]}" ]; then
    echo "Invalid selection." >&2
    exit 1
  fi

  SELECTED=$(echo "${LINES[$((CHOICE-1))]}" | cut -f1)
  REPO="git@github.com:${SELECTED}.git"
  echo "    Selected: $REPO"
fi

# Map GPU shortnames to RunPod GPU type IDs
case "$GPU_TYPE" in
  4090)  GPU_ID="NVIDIA GeForce RTX 4090" ;;
  5090)  GPU_ID="NVIDIA GeForce RTX 5090" ;;
  h100)  GPU_ID="NVIDIA H100 80GB HBM3" ;;
  *)
    echo "Error: unsupported GPU type '$GPU_TYPE'. Choose from: 4090, 5090, h100" >&2
    exit 1
    ;;
esac

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

# Helper: RunPod GraphQL API call
runpod_api() {
  local query="$1"
  curl -s -H "Content-Type: application/json" \
    -H "Authorization: Bearer $API_KEY" \
    -d "$query" \
    https://api.runpod.io/graphql
}

# Generate pod name from repo
REPO_NAME=$(basename "$REPO" .git)
POD_NAME="${REPO_NAME}-${GPU_TYPE}"

echo "==> Launching RunPod: $POD_NAME"
echo "    GPU: $GPU_ID"
echo "    Repo: $REPO"

# Build environment variables for the pod
ENV_ARRAY='[]'
if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  ENV_ARRAY=$(echo "$ENV_ARRAY" | jq --arg v "$CLAUDE_CODE_OAUTH_TOKEN" '. + [{"key": "CLAUDE_CODE_OAUTH_TOKEN", "value": $v}]')
fi

# Fetch all datacenters
DC_QUERY=$(jq -n '{ query: "{ dataCenters { id name location } }" }')
DC_RESPONSE=$(runpod_api "$DC_QUERY")
DATACENTERS=$(echo "$DC_RESPONSE" | jq -r '.data.dataCenters[].id')

# Try each datacenter: create network volume, then pod. Clean up volume on failure.
echo "==> Creating pod with ${VOLUME_SIZE}GB network volume..."
POD_ID=""
NV_ID=""
for DC in $DATACENTERS; do
  # Create network volume in this datacenter
  NV_QUERY=$(jq -n --arg name "${POD_NAME}-vol" --argjson size "$VOLUME_SIZE" --arg dc "$DC" '{
    query: "mutation($input: CreateNetworkVolumeInput!) { createNetworkVolume(input: $input) { id name size dataCenterId } }",
    variables: { input: { name: $name, size: $size, dataCenterId: $dc } }
  }')
  NV_RESPONSE=$(runpod_api "$NV_QUERY")
  NV_ID=$(echo "$NV_RESPONSE" | jq -r '.data.createNetworkVolume.id // empty')
  if [ -z "$NV_ID" ]; then
    continue
  fi

  # Try to create pod with this volume
  MUTATION="mutation { podFindAndDeployOnDemand(input: { name: \"$POD_NAME\", imageName: \"runpod/pytorch:1.0.3-cu1281-torch280-ubuntu2404\", gpuTypeId: \"$GPU_ID\", cloudType: ALL, containerDiskInGb: $CONTAINER_DISK, gpuCount: 1, ports: \"22/tcp\", startSsh: true, supportPublicIp: true, networkVolumeId: \"$NV_ID\", volumeMountPath: \"/workspace\" }) { id name desiredStatus machine { podHostId } } }"
  DEPLOY_QUERY=$(jq -n --arg q "$MUTATION" '{ query: $q }')
  DEPLOY_RESPONSE=$(runpod_api "$DEPLOY_QUERY")
  POD_ID=$(echo "$DEPLOY_RESPONSE" | jq -r '.data.podFindAndDeployOnDemand.id // empty')

  if [ -n "$POD_ID" ]; then
    echo "    Network volume: $NV_ID (datacenter: $DC)"
    echo "    Pod created: $POD_ID"
    break
  fi

  # Pod failed in this datacenter — delete the volume and try next
  DEL_QUERY=$(jq -n --arg q "mutation { deleteNetworkVolume(input: { id: \"$NV_ID\" }) }" '{ query: $q }')
  runpod_api "$DEL_QUERY" > /dev/null
  NV_ID=""
done

if [ -z "$POD_ID" ]; then
  echo "Error: Could not deploy pod in any datacenter" >&2
  exit 1
fi

# Wait for the pod to be running and have SSH info
echo "==> Waiting for pod to be ready..."
SSH_IP=""
SSH_PORT=""
for i in $(seq 1 60); do
  STATUS_QUERY=$(jq -n --arg id "$POD_ID" '{
    query: "query($id: String!) { pod(input: { podId: $id }) { id desiredStatus runtime { ports { ip isIpPublic privatePort publicPort type } } } }",
    variables: { id: $id }
  }')
  STATUS_RESPONSE=$(runpod_api "$STATUS_QUERY")

  SSH_INFO=$(echo "$STATUS_RESPONSE" | jq -r '
    .data.pod.runtime.ports[]?
    | select(.privatePort == 22 and .isIpPublic == true and .type == "tcp")
    | "\(.ip)\t\(.publicPort)"
  ' 2>/dev/null || true)

  if [ -n "$SSH_INFO" ]; then
    SSH_IP=$(echo "$SSH_INFO" | head -1 | cut -f1)
    SSH_PORT=$(echo "$SSH_INFO" | head -1 | cut -f2)
    break
  fi

  printf "." >&2
  sleep 5
done
echo ""

if [ -z "$SSH_IP" ] || [ -z "$SSH_PORT" ]; then
  echo "Error: Pod did not become ready within 5 minutes." >&2
  echo "Check pod $POD_ID in the RunPod dashboard." >&2
  exit 1
fi

echo "    Pod ready: $SSH_IP:$SSH_PORT"

# Build SSH command for agentize.sh
SSH_CMD="ssh -i $SSH_KEY -p $SSH_PORT root@$SSH_IP"

# Brief pause for SSH daemon to fully initialize
sleep 5

echo "==> Running agentize.sh..."
if [ -n "$REPO" ]; then
  exec "$SCRIPT_DIR/agentize.sh" --repo "$REPO" $SSH_CMD
else
  exec "$SCRIPT_DIR/agentize.sh" $SSH_CMD
fi
