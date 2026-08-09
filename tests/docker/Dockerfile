# Linux test image: Rust toolchain plus zsh built from source at ZSH_VERSION.
# Built and run by tests/docker/run.sh; see AGENTS.md "Build and test".
FROM rust:bookworm

# - libncurses-dev: zsh build dependency.
# - locales + locale-gen: the pty harness (tests/driver/) runs its hosts under
#   LC_ALL=en_US.UTF-8, which Debian does not ship pre-generated.
RUN apt-get update \
    && apt-get install -y --no-install-recommends libncurses-dev locales \
    && sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*

# zsh.org keeps only the latest release under pub/; every other version lives
# under pub/old/, hence the fallback URL.
# --with-tcsetpgrp: the configure check for tcsetpgrp needs a tty, which
# docker build does not have.
ARG ZSH_VERSION
RUN set -eux; \
    cd /tmp; \
    curl -fsSLo zsh.tar.xz "https://www.zsh.org/pub/zsh-${ZSH_VERSION}.tar.xz" \
      || curl -fsSLo zsh.tar.xz "https://www.zsh.org/pub/old/zsh-${ZSH_VERSION}.tar.xz"; \
    tar -xf zsh.tar.xz; \
    cd "zsh-${ZSH_VERSION}"; \
    ./configure --prefix=/usr/local --enable-multibyte --with-tcsetpgrp; \
    make -j"$(nproc)"; \
    make install; \
    cd /; \
    rm -rf /tmp/zsh.tar.xz "/tmp/zsh-${ZSH_VERSION}"

ENV LANG=en_US.UTF-8
