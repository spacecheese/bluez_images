#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(realpath "$(dirname "${BASH_SOURCE[0]}")")"

BLUEZ_VERSION="${1:-5.70}"
BUILD_IMAGE="${2:-ubuntu:24.04}"
DEST_DIR="${3:-.}"

docker build \
  -f $SCRIPT_DIR/../bluez-build/Dockerfile \
  --build-arg BASE_IMAGE=$BUILD_IMAGE \
  --build-arg BLUEZ_VERSION=$BLUEZ_VERSION \
  -t bluez-artifacts:$BLUEZ_VERSION .

docker create --name bluez-export-$BLUEZ_VERSION bluez-artifacts:$BLUEZ_VERSION
docker cp bluez-export-$BLUEZ_VERSION:/bluez-install $DEST_DIR
docker rm bluez-export-$BLUEZ_VERSION