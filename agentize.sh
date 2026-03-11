#!/usr/bin/env bash
set -euo pipefail

if [ $# -eq 0 ]; then
  echo "Usage: agentize.sh <ssh-command>"
  echo "Example: agentize.sh \"ssh -i ~/.ssh/id_ed25519 -p 12599 root@01.proxy.koyeb.app\""
  exit 1
fi

SSH_CMD="$*"

echo "==> Connecting via: $SSH_CMD"

$SSH_CMD bash -s << 'REMOTE_SCRIPT'
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
export LANG=C

echo "==> Setting up locale..."
apt-get update -qq
apt-get install -y -qq apt-utils locales > /dev/null
sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen en_US.UTF-8 > /dev/null
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

echo "==> Installing sudo, vim, tmux if needed..."
apt-get install -y -qq sudo vim tmux > /dev/null

echo "==> Creating ubuntu user if it doesn't exist..."
if ! id -u ubuntu &>/dev/null; then
  useradd -m -s /bin/bash ubuntu
  echo "    Created ubuntu user."
else
  echo "    ubuntu user already exists."
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

echo "==> Deploy public key:"
cat ~ubuntu/.ssh/id_ed25519.pub

echo "==> Installing Claude Code for ubuntu..."
su - ubuntu -c 'curl -fsSL https://claude.ai/install.sh | bash'

echo "==> Adding ~/.local/bin to PATH in .bashrc..."
su - ubuntu -c 'grep -q "/.local/bin" ~/.bashrc || echo "export PATH=\"\$HOME/.local/bin:\$PATH\"" >> ~/.bashrc'

echo "==> Adding dangerclaude alias to .bashrc..."
su - ubuntu -c 'grep -q "dangerclaude" ~/.bashrc || echo "alias dangerclaude='"'"'claude --dangerously-skip-permissions'"'"'" >> ~/.bashrc'

echo "==> Pre-configuring Claude Code onboarding..."
echo '{"hasCompletedOnboarding":true}' > ~ubuntu/.claude.json
chown ubuntu:ubuntu ~ubuntu/.claude.json

echo "==> Done! Machine is agentized."
REMOTE_SCRIPT

# If we have a Claude Code OAuth token locally, inject it into ubuntu's .bashrc
if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  echo "==> Setting CLAUDE_CODE_OAUTH_TOKEN on remote..."
  $SSH_CMD bash -s << TOKENSCRIPT
grep -q "CLAUDE_CODE_OAUTH_TOKEN" ~ubuntu/.bashrc 2>/dev/null && \
  sed -i '/CLAUDE_CODE_OAUTH_TOKEN/d' ~ubuntu/.bashrc
echo 'export CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN"' >> ~ubuntu/.bashrc
chown ubuntu:ubuntu ~ubuntu/.bashrc
TOKENSCRIPT
  echo "    Token set."
fi

# Print the SSH command with username replaced to ubuntu
UBUNTU_CMD=$(echo "$SSH_CMD" | sed 's/[a-zA-Z0-9_.-]*@/ubuntu@/')
echo ""
echo "==> Connect as ubuntu:"
echo "    $UBUNTU_CMD"
