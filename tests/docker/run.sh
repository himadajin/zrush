#!/bin/bash
# Run the Linux test suite in a container pinned to a specific zsh version.
#
# Usage:
#   tests/docker/run.sh <zsh-version>      # e.g. 5.8.1, 5.9
#
# Builds tests/docker/Dockerfile (cached by the Docker daemon) and runs
# tests/docker/suite.zsh inside it: cargo build/test plus the headless zsh
# suites (driver.zsh, keybinds.zsh, vectors.zsh, transport.zsh). CI's Linux matrix calls
# exactly this script, so a CI failure reproduces locally with one command.
#
# bash, not zsh: this is the one script that must run on hosts whose zsh is
# the very thing under suspicion (or absent, as on GitHub's Linux runners).
#
# Mount layout:
#   - repo bind-mounted rw at /zrush, with named volumes shadowing target/
#     (per-arch) and the cargo registry, so container builds never touch the
#     host's target/ and re-runs skip recompilation.
#   - /tmp is a tmpfs with exec: driver.zsh copies its fake-worker launcher
#     under $TMPDIR and must be able to execute it (the Docker default is
#     noexec).
#
# ZRUSH_DOCKER_BUILD_ARGS adds extra arguments to docker build (e.g. a
# --cache-from for CI, should image caching ever be needed).
set -euo pipefail

version=${1:?usage: tests/docker/run.sh <zsh-version>}
repo=$(cd "$(dirname "$0")/../.." && pwd)
image="zrush-test:zsh-$version"
arch=$(docker version --format '{{.Server.Arch}}')

# shellcheck disable=SC2086  # ZRUSH_DOCKER_BUILD_ARGS is intentionally word-split
docker build \
    ${ZRUSH_DOCKER_BUILD_ARGS:-} \
    --build-arg "ZSH_VERSION=$version" \
    -t "$image" \
    "$repo/tests/docker"

docker run --rm \
    -v "$repo:/zrush" \
    -v "zrush-target-linux-$arch:/zrush/target" \
    -v "zrush-cargo-registry:/usr/local/cargo/registry" \
    --tmpfs /tmp:exec,mode=1777 \
    -w /zrush \
    "$image" \
    zsh -f tests/docker/suite.zsh
