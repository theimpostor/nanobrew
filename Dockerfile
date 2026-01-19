FROM ubuntu:latest

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

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

ENV NANOBREW_IN_DOCKER=1

WORKDIR /root/nanobrew

COPY . .

ENTRYPOINT [ "/bin/bash" ]
