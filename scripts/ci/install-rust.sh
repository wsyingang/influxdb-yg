#!/bin/bash

set -ex

flux_dir=$(go list -m -f '{{.Dir}}' github.com/influxdata/flux)
FLUX_RUST_VERSION=$(cat ${flux_dir}/Dockerfile_build | grep 'FROM rust:' | cut -d ' ' -f2 | cut -d ':' -f2)
RUST_LATEST_VERSION=${FLUX_RUST_VERSION:-1.53}
cd ..
rm -rf flux-repo

# For security, we specify a particular rustup version and a SHA256 hash, computed
# ourselves and hardcoded here. When updating `RUSTUP_LATEST_VERSION`:
#   1. Download the new rustup script from https://github.com/rust-lang/rustup/releases.
#   2. Audit the script and changes to it. You might want to grep for strange URLs...
#   3. Update `OUR_RUSTUP_SHA` with the result of running `sha256sum rustup-init.sh`.
RUSTUP_LATEST_VERSION=1.24.2
OUR_RUSTUP_SHA="40229562d4fa60e102646644e473575bae22ff56c3a706898a47d7241c9c031e"


# Download rustup script
curl --proto '=https' --tlsv1.2 -sSf \
  https://raw.githubusercontent.com/rust-lang/rustup/${RUSTUP_LATEST_VERSION}/rustup-init.sh -O

# Verify checksum of rustup script. Exit with error if check fails.
echo "${OUR_RUSTUP_SHA} rustup-init.sh" | sha256sum --check -- \
    || { echo "Checksum problem!"; exit 1; }

# Run rustup.
sh rustup-init.sh --default-toolchain "$RUST_LATEST_VERSION" -y
export PATH="${HOME}/.cargo/bin:${PATH}"
