# Fat sandbox image: Ubuntu 24.04 + the CLI subset of devbase-core that makes
# sense inside a container + every language toolchain the user works with.
# Built once, reused for every `sbx run` invocation.

FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG USER_UID=501
ARG USER_GID=20
ARG USERNAME=dev

# --- base + devbase-core CLI subset -----------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget gnupg lsb-release sudo \
      build-essential pkg-config libssl-dev cmake \
      git openssh-client less jq unzip xz-utils file tini \
      ripgrep fzf bat eza fd-find zoxide \
      python3 python3-pip python3-venv python3-dev pipx \
      openjdk-21-jdk-headless \
      ruby ruby-dev \
      fish zsh man-db locales \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# Ubuntu ships bat as `batcat` and fd-find as `fdfind`; expose the upstream names.
RUN ln -sf /usr/bin/batcat /usr/local/bin/bat \
 && ln -sf /usr/bin/fdfind /usr/local/bin/fd

# --- git-delta (not in 24.04 apt) -------------------------------------------
ARG DELTA_VERSION=0.18.2
RUN ARCH=$(dpkg --print-architecture) \
 && curl -fsSL "https://github.com/dandavison/delta/releases/download/${DELTA_VERSION}/git-delta_${DELTA_VERSION}_${ARCH}.deb" -o /tmp/delta.deb \
 && dpkg -i /tmp/delta.deb \
 && rm /tmp/delta.deb

# --- Go ----------------------------------------------------------------------
ARG GO_VERSION=1.23.4
RUN ARCH=$(dpkg --print-architecture) \
 && curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${ARCH}.tar.gz" | tar -C /usr/local -xz \
 && ln -s /usr/local/go/bin/go /usr/local/bin/go \
 && ln -s /usr/local/go/bin/gofmt /usr/local/bin/gofmt
ENV GOPATH=/home/${USERNAME}/go
ENV PATH=/usr/local/go/bin:${GOPATH}/bin:${PATH}

# --- Node (LTS via NodeSource) ----------------------------------------------
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/*

# --- kubectl -----------------------------------------------------------------
RUN ARCH=$(dpkg --print-architecture) \
 && KVER=$(curl -fsSL https://dl.k8s.io/release/stable.txt) \
 && curl -fsSL "https://dl.k8s.io/release/${KVER}/bin/linux/${ARCH}/kubectl" -o /usr/local/bin/kubectl \
 && chmod +x /usr/local/bin/kubectl

# --- uv (fast Python package manager) ---------------------------------------
RUN curl -LsSf https://astral.sh/uv/install.sh | \
      env UV_INSTALL_DIR=/usr/local/bin UV_UNMANAGED_INSTALL=/usr/local/bin sh

# --- user matching the host (UID/GID passed in as build args) ---------------
# Numeric ownership is what carries host file ownership across the boundary;
# the user/group *names* inside the image are arbitrary. Handle the two
# collision cases that come up in practice:
#   - GID already exists as a system group (e.g. GID 20 = 'dialout' on Ubuntu
#     from macOS, or GID 100 = 'users'): reuse it as the new user's primary
#     group instead of refusing to create a duplicate.
#   - UID already taken by a default account in the base image (rare for
#     Docker Hub's ubuntu:24.04, common in cloud images at UID 1000): remove
#     that account first so useradd can take the slot.
RUN if getent passwd ${USER_UID} >/dev/null; then \
      userdel -r "$(getent passwd ${USER_UID} | cut -d: -f1)" 2>/dev/null || true; \
    fi \
 && if ! getent group ${USER_GID} >/dev/null; then \
      groupadd -g ${USER_GID} ${USERNAME}; \
    fi \
 && useradd -u ${USER_UID} -g ${USER_GID} -m -s /usr/bin/fish ${USERNAME} \
 && mkdir -p /home/${USERNAME}/.local/bin /work \
 && chown -R ${USER_UID}:${USER_GID} /home/${USERNAME} /work

USER ${USERNAME}
WORKDIR /home/${USERNAME}

# --- Rust (rustup, as the user) ---------------------------------------------
ENV RUSTUP_HOME=/home/${USERNAME}/.rustup \
    CARGO_HOME=/home/${USERNAME}/.cargo
ENV PATH=${CARGO_HOME}/bin:/home/${USERNAME}/.local/bin:${PATH}
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
      sh -s -- -y --default-toolchain stable --profile default --no-modify-path \
 && rustup component add rust-analyzer

WORKDIR /work
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/bin/fish", "--login"]
