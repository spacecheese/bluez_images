ARG BASE_IMAGE=ubuntu:22.04
FROM ${BASE_IMAGE} AS build

ARG BLUEZ_VERSION=5.64
ENV DEBIAN_FRONTEND=noninteractive

# Install build dependencies
RUN apt-get update && apt-get install -y \
    wget build-essential libdbus-1-dev udev libudev-dev \
    libreadline-dev libtool libglib2.0-dev \
    libical-dev libusb-dev libbluetooth-dev systemd \
    pkg-config autoconf python3-docutils \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /usr/src

# Download and build BlueZ
RUN wget http://www.kernel.org/pub/linux/bluetooth/bluez-${BLUEZ_VERSION}.tar.xz && \
    tar xf bluez-${BLUEZ_VERSION}.tar.xz && \
    cd bluez-${BLUEZ_VERSION} && \
    ./configure --enable-testing --enable-experimental && \
    make -j"$(nproc)" && \
    mkdir -p /bluez-install/var/lib/bluetooth && \
    mkdir -p /bluez-install/bin && \
    make install DESTDIR="/bluez-install" && \
    cp emulator/btvirt tools/btmgmt /bluez-install/bin/ && \
    # bluez 5.50 (and possibly other versions) deny all dbus access by default unlike later versions.
    (sed -i 's|<deny send_destination="org\.bluez"/>|<allow send_destination="org.bluez"/>|' /bluez-install/etc/dbus-1/system.d/bluetooth.conf || true)
