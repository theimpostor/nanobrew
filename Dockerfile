FROM ubuntu:latest

# Using bind mounts for apt cache, don't wipe after install
RUN rm /etc/apt/apt.conf.d/docker-clean

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
      apt update && apt-get --no-install-recommends install -y \
        ca-certificates \
        curl \
        jq \
        tree

RUN mkdir -p /root/.local/bin

COPY nanobrew.sh /root/.local/bin/nanobrew.sh

# TODO: syntax error
# RUN . /root/.local/bin/nanobrew.sh

RUN /root/.local/bin/nanobrew.sh env >> ~/.bashrc

RUN /root/.local/bin/nanobrew.sh install ripgrep

RUN find /root/.local
