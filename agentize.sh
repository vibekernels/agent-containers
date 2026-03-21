#!/usr/bin/env bash
set -euo pipefail

if [ $# -eq 0 ]; then
  echo "Usage: agentize.sh [--repo <git-ssh-url>] <ssh-command>"
  echo "Example: agentize.sh --repo git@github.com:vibekernels/blenderproc-1x4090.git \"ssh -i ~/.ssh/id_ed25519 -p 12599 root@01.proxy.koyeb.app\""
  exit 1
fi

GITHUB_REPO=""
if [ "$1" = "--repo" ]; then
  shift
  GITHUB_REPO="$1"
  shift
fi

SSH_CMD="$*"

# Auto-accept new host keys (still warns if a known key changes)
SSH_CMD="${SSH_CMD} -o StrictHostKeyChecking=accept-new"

GIT_USER_NAME=$(git config --global user.name 2>/dev/null || true)
GIT_USER_EMAIL=$(git config --global user.email 2>/dev/null || true)

echo "==> Connecting via: $SSH_CMD"

$SSH_CMD bash -s << 'REMOTE_SCRIPT'
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
export LANG=C

echo "==> Setting up locale..."
apt-get update -qq
apt-get install -y -qq apt-utils > /dev/null 2>&1
apt-get install -y -qq locales > /dev/null
sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen en_US.UTF-8 > /dev/null
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

echo "==> Installing sudo, vim, tmux, gh if needed..."
apt-get install -y -qq apt-transport-https software-properties-common > /dev/null
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null
chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list
apt-get update -qq
apt-get install -y -qq sudo vim tmux gh > /dev/null

echo "==> Creating ubuntu user if it doesn't exist..."
if ! id -u ubuntu &>/dev/null; then
  useradd -m -s /bin/bash ubuntu
  echo "    Created ubuntu user."
else
  echo "    ubuntu user already exists."
fi
chown -R ubuntu:ubuntu ~ubuntu

if [ -d /workspace ]; then
  echo "==> Linking ~/.claude to /workspace/.claude for persistence..."
  mkdir -p /workspace/.claude
  chown ubuntu:ubuntu /workspace/.claude 2>/dev/null || true
  ln -sfn /workspace/.claude ~ubuntu/.claude
  chown -h ubuntu:ubuntu ~ubuntu/.claude

  echo "==> Linking ~/.cache to /workspace/.cache for persistence..."
  mkdir -p /workspace/.cache
  chown ubuntu:ubuntu /workspace/.cache 2>/dev/null || true
  if [ -d ~ubuntu/.cache ] && [ ! -L ~ubuntu/.cache ]; then
    cp -a ~ubuntu/.cache/. /workspace/.cache/ 2>/dev/null || true
    rm -rf ~ubuntu/.cache
  fi
  ln -sfn /workspace/.cache ~ubuntu/.cache
  chown -h ubuntu:ubuntu ~ubuntu/.cache
fi

echo "==> Granting ubuntu passwordless sudo..."
echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ubuntu
chmod 0440 /etc/sudoers.d/ubuntu

echo "==> Copying authorized_keys to ubuntu..."
mkdir -p ~ubuntu/.ssh
cp ~root/.ssh/authorized_keys ~ubuntu/.ssh/authorized_keys
chown -R ubuntu:ubuntu ~ubuntu/.ssh
chmod 700 ~ubuntu/.ssh
chmod 600 ~ubuntu/.ssh/authorized_keys

echo "==> Generating SSH keypair for ubuntu (deploy key)..."
if [ ! -f ~ubuntu/.ssh/id_ed25519 ]; then
  su - ubuntu -c 'ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -q'
  echo "    Keypair generated."
else
  echo "    Keypair already exists, skipping."
fi

echo "==> Adding github.com to known SSH hosts for ubuntu..."
ssh-keyscan -H github.com >> ~ubuntu/.ssh/known_hosts 2>/dev/null
chown ubuntu:ubuntu ~ubuntu/.ssh/known_hosts
chmod 600 ~ubuntu/.ssh/known_hosts

echo "==> Deploy public key:"
cat ~ubuntu/.ssh/id_ed25519.pub

echo "==> Installing uv for ubuntu..."
su - ubuntu -c 'curl -LsSf https://astral.sh/uv/install.sh | bash'

echo "==> Installing Claude Code for ubuntu..."
su - ubuntu -c 'curl -fsSL https://claude.ai/install.sh | bash' > /dev/null

echo "==> Adding ~/.local/bin to PATH in .bashrc..."
su - ubuntu -c 'grep -q "/.local/bin" ~/.bashrc || echo "export PATH=\"\$HOME/.local/bin:\$PATH\"" >> ~/.bashrc'

echo "==> Adding dangerclaude alias to .bashrc..."
su - ubuntu -c 'grep -q "dangerclaude" ~/.bashrc || echo "alias dangerclaude='"'"'claude --dangerously-skip-permissions --model opus --effort medium'"'"'" >> ~/.bashrc'

echo "==> Adding auto-tmux to .bashrc..."
su - ubuntu -c 'grep -q "auto-tmux" ~/.bashrc || cat >> ~/.bashrc << '"'"'TMUXBLOCK'"'"'

# auto-tmux: attach to existing session or create one on SSH login
if [ -z "$TMUX" ] && [ -n "$SSH_CONNECTION" ]; then
  cd /workspace 2>/dev/null
  tmux attach-session 2>/dev/null || tmux new-session
fi
TMUXBLOCK'

echo "==> Pre-configuring Claude Code onboarding..."
echo '{"hasCompletedOnboarding":true}' > ~ubuntu/.claude.json
chown ubuntu:ubuntu ~ubuntu/.claude.json

echo "==> Checking for Tenstorrent devices..."
if [ -d /dev/tenstorrent ] && [ "$(ls -A /dev/tenstorrent 2>/dev/null)" ]; then
  echo "    Found Tenstorrent devices, granting ubuntu user access..."
  chmod a+rw /dev/tenstorrent/*
fi

echo "==> Done! Machine is agentized."
REMOTE_SCRIPT

# If a GitHub repo was specified, add deploy key and clone
if [ -n "$GITHUB_REPO" ]; then
  # Extract owner/repo from SSH URL (e.g. git@github.com:vibekernels/blenderproc-1x4090.git -> vibekernels/blenderproc-1x4090)
  OWNER_REPO=$(echo "$GITHUB_REPO" | sed 's/.*://' | sed 's/\.git$//')

  echo "==> Fetching deploy public key from remote..."
  DEPLOY_KEY=$($SSH_CMD cat ~ubuntu/.ssh/id_ed25519.pub)

  echo "==> Adding deploy key to $OWNER_REPO via gh..."
  if echo "$DEPLOY_KEY" | gh repo deploy-key add - --repo "$OWNER_REPO" --title "agentize-$(date +%Y%m%d-%H%M%S)" --allow-write 2>/dev/null; then
    echo "    Deploy key added."
  else
    echo "    Deploy key already exists, continuing."
  fi

  REPO_DIR=$(basename "$GITHUB_REPO" .git)
  echo "==> Cloning $GITHUB_REPO to /workspace on remote..."
  $SSH_CMD bash -s << CLONESCRIPT
if [ -d /workspace/$REPO_DIR/.git ]; then
  echo "    Repo already exists, fetching latest..."
  su - ubuntu -c 'cd /workspace/$REPO_DIR && git fetch --all'
else
  su - ubuntu -c 'cd /workspace && git clone $GITHUB_REPO'
fi
CLONESCRIPT
  echo "    Done."
fi

# Configure environment and git identity in a single SSH session
echo "==> Configuring environment on remote..."
$SSH_CMD bash -s << ENVSCRIPT
# Helper: set or replace an env var in .bashrc
set_env() {
  local key="\$1" value="\$2"
  sed -i "/\$key/d" ~ubuntu/.bashrc 2>/dev/null || true
  echo "export \$key=\"\$value\"" >> ~ubuntu/.bashrc
  echo "    \$key set."
}

set_env CLAUDE_CODE_MAX_OUTPUT_TOKENS "128000"
[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && set_env CLAUDE_CODE_OAUTH_TOKEN "$CLAUDE_CODE_OAUTH_TOKEN"
[ -n "${HF_TOKEN:-}" ] && set_env HF_TOKEN "$HF_TOKEN"

chown ubuntu:ubuntu ~ubuntu/.bashrc

[ -n "${GIT_USER_NAME:-}" ] && su - ubuntu -c "git config --global user.name \"${GIT_USER_NAME}\"" && echo "    Git user.name set."
[ -n "${GIT_USER_EMAIL:-}" ] && su - ubuntu -c "git config --global user.email \"${GIT_USER_EMAIL}\"" && echo "    Git user.email set."
ENVSCRIPT

# Print the SSH command with username replaced to ubuntu
UBUNTU_CMD=$(echo "$SSH_CMD" | sed 's/[a-zA-Z0-9_.-]*@/ubuntu@/')
echo ""
echo "==> Connecting as ubuntu: $UBUNTU_CMD"
exec $UBUNTU_CMD
