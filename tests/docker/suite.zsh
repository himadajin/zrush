#!/usr/bin/env zsh
# The in-container half of tests/docker/run.sh: the full Linux test suite,
# in the same order as CI's macOS job. Not meant to run on a host.
emulate -L zsh
set -e

print -r -- "== $(zsh --version) =="
cargo build --release
cargo test
zsh -f tests/zsh/keybinds.zsh
zsh -f tests/zsh/vectors.zsh
zsh -f tests/zsh/transport.zsh
