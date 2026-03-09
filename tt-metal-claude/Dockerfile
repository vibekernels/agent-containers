ARG BASE_IMAGE=ghcr.io/tenstorrent/tt-metal/tt-metalium-ubuntu-22.04-release-amd64:latest-rc

FROM ${BASE_IMAGE}

ARG DEBIAN_FRONTEND=noninteractive
ENV SHELL=/bin/bash

# Install essentials + SSH
RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-server sudo git curl wget vim tmux build-essential ca-certificates \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# SSH setup
RUN mkdir -p /var/run/sshd /root/.ssh \
    && touch /root/.ssh/authorized_keys \
    && chmod 700 /root/.ssh \
    && chmod 600 /root/.ssh/authorized_keys \
    && rm -f /etc/ssh/ssh_host_* \
    && echo "HostKeyAlgorithms +ssh-rsa" >> /etc/ssh/sshd_config \
    && echo "PubkeyAcceptedKeyTypes +ssh-rsa" >> /etc/ssh/sshd_config

# Ensure ubuntu user exists with sudo access
RUN id ubuntu >/dev/null 2>&1 || useradd -m -s /bin/bash ubuntu \
    && usermod -s /bin/bash ubuntu \
    && echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ubuntu \
    && chmod 0440 /etc/sudoers.d/ubuntu \
    && mkdir -p /home/ubuntu/.ssh && chmod 700 /home/ubuntu/.ssh \
    && chown -R ubuntu:ubuntu /home/ubuntu/.ssh

# Install Claude Code and pre-configure onboarding
RUN su - ubuntu -c "curl -fsSL https://claude.ai/install.sh | bash" \
    && echo '{"hasCompletedOnboarding":true,"theme":"dark"}' > /home/ubuntu/.claude.json \
    && chown ubuntu:ubuntu /home/ubuntu/.claude.json

# Docker-in-Docker
RUN mkdir -pm755 /etc/apt/keyrings \
    && curl -o /etc/apt/keyrings/docker.asc -fsSL "https://download.docker.com/linux/ubuntu/gpg" \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && mkdir -pm755 /etc/apt/sources.list.d \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(grep UBUNTU_CODENAME= /etc/os-release | cut -d= -f2 | tr -d '\"') stable" > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install --no-install-recommends -y \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin \
    pigz xz-utils \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY --from=docker:dind /usr/local/bin/docker-init /usr/local/bin/docker-init

ADD https://raw.githubusercontent.com/docker-library/docker/master/modprobe.sh /usr/local/bin/modprobe
ADD https://raw.githubusercontent.com/docker-library/docker/master/dockerd-entrypoint.sh /usr/local/bin/
ADD https://raw.githubusercontent.com/docker-library/docker/master/docker-entrypoint.sh /usr/local/bin/
ADD https://raw.githubusercontent.com/moby/moby/master/hack/dind /usr/local/bin/dind

ADD https://raw.githubusercontent.com/koyeb/koyeb-docker-compose/refs/heads/master/koyeb-entrypoint.sh /usr/local/bin/koyeb-entrypoint.sh

RUN chmod +x /usr/local/bin/dockerd-entrypoint.sh /usr/local/bin/docker-entrypoint.sh /usr/local/bin/dind /usr/local/bin/koyeb-entrypoint.sh

VOLUME /var/lib/docker

WORKDIR /home/ubuntu

# Script that tmux will run (avoids nested quoting issues)
RUN printf '#!/bin/bash\nsource /etc/rp_environment\nclaude -p "$CLAUDE_PROMPT" --dangerously-skip-permissions\nexec bash\n' \
    > /home/ubuntu/run-claude.sh && chmod +x /home/ubuntu/run-claude.sh && chown ubuntu:ubuntu /home/ubuntu/run-claude.sh

# Startup script: configure SSH, start Claude Code in tmux
RUN printf '#!/bin/bash\n\
ssh-keygen -A\n\
if [ -n "$PUBLIC_KEY" ]; then\n\
  echo "$PUBLIC_KEY" > /root/.ssh/authorized_keys\n\
  chmod 644 /root/.ssh/authorized_keys\n\
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

ENTRYPOINT ["/usr/local/bin/koyeb-entrypoint.sh"]

CMD ["/start.sh"]
