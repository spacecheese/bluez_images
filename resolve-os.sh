#!/usr/bin/env bash
set -euo pipefail

OS_VERSION_STR=$1

OS="${OS_VERSION_STR%%-*}"
VERSION="${OS_VERSION_STR#*-}"
CODENAME=""
CLOUDIMG=""

case "$OS" in
  ubuntu)
    case "$VERSION" in
      22.04) CODENAME="jammy" ;;
      24.04) CODENAME="noble" ;;
      *)
        echo "Error: Unsupported Ubuntu version: $VERSION" >&2
        exit 1
        ;;
    esac

    CLOUDIMG="https://cloud-images.ubuntu.com/minimal/releases/${CODENAME}/release/ubuntu-${VERSION}-minimal-cloudimg-amd64.img"
    ;;
  *)
    echo "Error: Unsupported OS: $OS" >&2
    exit 1
    ;;
esac

echo "OS_VERSION=$VERSION"
echo "OS_CODENAME=$CODENAME"
echo "OS_CLOUDIMG=$CLOUDIMG"