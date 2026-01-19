FROM ubuntu:latest

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

ARG DEBIAN_FRONTEND=noninteractive

# Using bind mounts for apt cache, don't wipe after install
RUN rm /etc/apt/apt.conf.d/docker-clean

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
      apt update && apt-get --no-install-recommends install -y \
        ca-certificates \
        curl \
        jq \
        tree \
        vim

RUN mkdir -p /root/.local/bin

COPY nanobrew.sh /root/.local/bin/nanobrew.sh

RUN /root/.local/bin/nanobrew.sh env >> ~/.bashrc

WORKDIR /root

ENTRYPOINT [ "/bin/bash" ]

RUN /root/.local/bin/nanobrew.sh install ripgrep shellcheck

# RUN shellcheck /root/.local/bin/nanobrew.sh
