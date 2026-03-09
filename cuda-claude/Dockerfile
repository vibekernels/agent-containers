FROM --platform=linux/amd64 nvidia/cuda:13.2.0-devel-ubuntu24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV SHELL=/bin/bash

# Install essentials + SSH + Node.js
RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-server sudo git curl wget vim tmux build-essential ca-certificates \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Claude Code
RUN npm install -g @anthropic-ai/claude-code

# Create ubuntu user with sudo access
RUN useradd -m -s /bin/bash ubuntu \
    && echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ubuntu \
    && chmod 0440 /etc/sudoers.d/ubuntu

# SSH setup
RUN mkdir -p /var/run/sshd /home/ubuntu/.ssh && chmod 700 /home/ubuntu/.ssh \
    && chown ubuntu:ubuntu /home/ubuntu/.ssh \
    && rm -f /etc/ssh/ssh_host_*

WORKDIR /home/ubuntu

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
printenv | grep -E "^[A-Z_][A-Z0-9_]*=" | grep -v "^PUBLIC_KEY=" | \\\n\
  awk -F = '"'"'{ val=$0; sub(/^[^=]*=/, "", val); print "export " $1 "=\\\"" val "\\\"" }'"'"' > /etc/rp_environment\n\
grep -q "source /etc/rp_environment" /home/ubuntu/.bashrc 2>/dev/null || \\\n\
  echo "source /etc/rp_environment" >> /home/ubuntu/.bashrc\n\
/usr/sbin/sshd\n\
\n\
# Start Claude Code in a tmux session as ubuntu user\n\
su - ubuntu -c "source /etc/rp_environment && tmux new-session -d -s claude '"'"'claude'"'"'"\n\
echo "Claude Code started in tmux session. Attach with: tmux attach -t claude"\n\
\n\
# Keep container alive\n\
sleep infinity\n\
' > /start.sh && chmod +x /start.sh

EXPOSE 22

CMD ["/start.sh"]
