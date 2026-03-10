FROM --platform=linux/amd64 ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV SHELL=/bin/bash
ENV PATH="/home/ubuntu/.local/bin:${PATH}"

# Install essentials + SSH
RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-server sudo git curl wget vim tmux build-essential ca-certificates \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Ensure ubuntu user exists with sudo access
RUN id ubuntu >/dev/null 2>&1 || useradd -m -s /bin/bash ubuntu \
    && usermod -s /bin/bash ubuntu \
    && echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ubuntu \
    && chmod 0440 /etc/sudoers.d/ubuntu

# Install Claude Code and pre-configure onboarding
RUN su - ubuntu -c "curl -fsSL https://claude.ai/install.sh | bash" \
    && echo '{"hasCompletedOnboarding":true,"theme":"dark"}' > /home/ubuntu/.claude.json \
    && chown ubuntu:ubuntu /home/ubuntu/.claude.json

# SSH setup
RUN mkdir -p /var/run/sshd /home/ubuntu/.ssh && chmod 700 /home/ubuntu/.ssh \
    && chown ubuntu:ubuntu /home/ubuntu/.ssh \
    && rm -f /etc/ssh/ssh_host_*

WORKDIR /home/ubuntu

# Script that tmux will run (avoids nested quoting issues)
RUN printf '#!/bin/bash\nsource /etc/rp_environment\nclaude -p "$CLAUDE_PROMPT" --dangerously-skip-permissions --model "${CLAUDE_MODEL:-opus}" --effort "${CLAUDE_EFFORT:-high}"\nexec bash\n' \
    > /home/ubuntu/run-claude.sh && chmod +x /home/ubuntu/run-claude.sh && chown ubuntu:ubuntu /home/ubuntu/run-claude.sh

# Startup script: configure SSH, start Claude Code in tmux
RUN printf '#!/bin/bash\n\
ssh-keygen -A\n\
if [ -n "$PUBLIC_KEY" ]; then\n\
  mkdir -p /home/ubuntu/.ssh\n\
  echo "$PUBLIC_KEY" >> /home/ubuntu/.ssh/authorized_keys\n\
  chmod 600 /home/ubuntu/.ssh/authorized_keys\n\
  chown -R ubuntu:ubuntu /home/ubuntu/.ssh\n\
fi\n\
# Snapshot container env vars so SSH sessions inherit them.\n\
printenv | grep -E "^[A-Z_][A-Z0-9_]*=" | grep -v "^PUBLIC_KEY=" | grep -v "^HOME=" | \\\n\
  sed '"'"'s/\\([^=]*\\)=\\(.*\\)/export \\1="\\2"/'"'"' > /etc/rp_environment\n\
grep -q "source /etc/rp_environment" /home/ubuntu/.bashrc 2>/dev/null || \\\n\
  echo "source /etc/rp_environment" >> /home/ubuntu/.bashrc\n\
/usr/sbin/sshd\n\
\n\
# Start Claude Code in a tmux session as ubuntu user\n\
su - ubuntu -c "tmux new-session -d -s claude /home/ubuntu/run-claude.sh"\n\
echo "Claude Code started in tmux session. Attach with: tmux attach -t claude"\n\
\n\
# Keep container alive\n\
sleep infinity\n\
' > /start.sh && chmod +x /start.sh

EXPOSE 22

CMD ["/start.sh"]
