#!/bin/bash
set -euo pipefail

BLUEZ_VERSION="${1:-5.70}"
WORKDIR="$(pwd)/bluez-${BLUEZ_VERSION}"
STAGING_DIR="${WORKDIR}/staging"
CLOUDINIT_DIR="${WORKDIR}/cloudinit"
CLOUDINIT_BUNDLE="${WORKDIR}/bluez-cloudinit-${BLUEZ_VERSION}.tar.gz"
BASE_IMAGE="ubuntu-base.img"
OUTPUT_IMAGE="ubuntu-bluez-${BLUEZ_VERSION}.qcow2"
SEED_IMAGE="${WORKDIR}/seed.img"

echo "[*] Building BlueZ version: ${BLUEZ_VERSION}"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

# ---------------------------------------------
# Step 1: Download and build BlueZ
# ---------------------------------------------
wget -nc "https://www.kernel.org/pub/linux/bluetooth/bluez-${BLUEZ_VERSION}.tar.xz"
tar xf "bluez-${BLUEZ_VERSION}.tar.xz"
cd "bluez-${BLUEZ_VERSION}"

sudo apt-get update
sudo apt-get install -y build-essential libdbus-1-dev libudev-dev libical-dev \
  libreadline-dev libglib2.0-dev libbluetooth-dev libusb-dev \
  dbus wget curl ca-certificates python3 cloud-image-utils qemu-utils \
  python3-docutils

./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var --enable-experimental
make -j"$(nproc)"

rm -rf "$STAGING_DIR"
make DESTDIR="$STAGING_DIR" install

cd "$WORKDIR"
tar czf "bluez-staging.tar.gz" -C staging .

# ---------------------------------------------
# Step 2: Prepare cloud-init config
# ---------------------------------------------
mkdir -p "$CLOUDINIT_DIR"

# meta-data
cat > "${CLOUDINIT_DIR}/meta-data" <<EOF
instance-id: bluez-${BLUEZ_VERSION}
local-hostname: bluez-vm
EOF

# user-data
cat > "${CLOUDINIT_DIR}/user-data" <<EOF
#cloud-config
hostname: bluez-vm
users:
  - name: tester
    groups: sudo
    shell: /bin/bash
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    lock_passwd: false
    passwd: \$6\$rounds=4096\$Wv..tztDLz3\$CHf2e6slN8/0JpZbyToIZhStfWswR7fzrIlz6Sb1gWIJoSzZeDF/.lfOrqImqvhde/7xT47YgA2rhCKUVX7lF.  # password: test

packages:
  - dbus
  - python3
  - sudo

runcmd:
  - mkdir -p /tmp/bluez-staging
  - cp /var/lib/cloud/instance/bluez-staging.tar.gz /tmp/
  - tar xzf /tmp/bluez-staging.tar.gz -C /tmp/bluez-staging
  - cp -a /tmp/bluez-staging/usr/* /usr/
  - cp -a /tmp/bluez-staging/etc/* /etc/
  - systemctl enable bluetooth
  - shutdown -h now
EOF

cp "bluez-staging.tar.gz" "${CLOUDINIT_DIR}/bluez-staging.tar.gz"

# Bundle optional archive
tar czf "$CLOUDINIT_BUNDLE" -C "$CLOUDINIT_DIR" .

# Create seed.img
cloud-localds "$SEED_IMAGE" "${CLOUDINIT_DIR}/user-data" "${CLOUDINIT_DIR}/meta-data"

# ---------------------------------------------
# Step 3: Download base cloud image
# ---------------------------------------------
if [[ ! -f "$BASE_IMAGE" ]]; then
  wget -O "$BASE_IMAGE" https://cloud-images.ubuntu.com/minimal/releases/jammy/release/ubuntu-22.04-minimal-cloudimg-amd64.img
fi

cp "$BASE_IMAGE" "$OUTPUT_IMAGE"

# ---------------------------------------------
# Step 4: Boot VM to trigger cloud-init
# ---------------------------------------------
echo "[*] Booting QEMU to apply cloud-init (you may see a console)..."

qemu-system-x86_64 \
  -m 2048 \
  -smp 2 \
  -nographic \
  -drive file="$OUTPUT_IMAGE",format=qcow2 \
  -drive file="$SEED_IMAGE",format=raw \
  -net nic -net user \
  -no-reboot \
  -serial mon:stdio \
  -display none

# ---------------------------------------------
# Step 5: Optional compression
# ---------------------------------------------
echo "[*] Compressing image..."
qemu-img convert -O qcow2 -c "$OUTPUT_IMAGE" "${OUTPUT_IMAGE%.qcow2}-compressed.qcow2"

echo "[✓] Done!"
echo " - Final image: ${OUTPUT_IMAGE%.qcow2}-compressed.qcow2"