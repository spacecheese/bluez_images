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
TARBALL_IMAGE="${WORKDIR}/bluez-tarball.img"

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

# Create and format disk
mkdir -p "${WORKDIR}/mnt"
dd if=/dev/zero of="$TARBALL_IMAGE" bs=1M count=64
mkfs.vfat -n BLUEZ "$TARBALL_IMAGE"

# Mount and copy tarball
sudo mount -o loop "$TARBALL_IMAGE" "${WORKDIR}/mnt"
sudo cp "$WORKDIR/bluez-staging.tar.gz" "${WORKDIR}/mnt/"
sync
sudo umount "${WORKDIR}/mnt"

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

write_files:
  - path: /usr/local/bin/bluez-init.sh
    permissions: '0755'
    owner: root:root
    content: |
      #!/bin/bash
      set -eux

      mkdir -p /mnt/extra
      mount -L BLUEZ /mnt/extra || true

      cp /mnt/extra/bluez-staging.tar.gz /tmp/
      mkdir -p /tmp/bluez-staging
      tar xzf /tmp/bluez-staging.tar.gz -C /tmp/bluez-staging

      cp -a /tmp/bluez-staging/usr/* /usr/
      systemctl enable bluetooth

      echo "success" > /mnt/extra/status.ok

runcmd:
  - /usr/local/bin/bluez-init.sh

power_state:
  mode: poweroff
  timeout: 30
  condition: true
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
  -drive file="$TARBALL_IMAGE",format=raw,media=disk \
  -net nic -net user \
  -no-reboot \
  -serial mon:stdio \
  -display none

# Wait for VM to shut down and check result
sudo mount -o loop "$TARBALL_IMAGE" "${WORKDIR}/mnt"

if [[ -f "${WORKDIR}/mnt/status.ok" ]]; then
  sudo umount "${WORKDIR}/mnt"
  echo "[✓] Cloud-init completed successfully."
else
  echo "[✗] Cloud-init failed or did not report status."
  sudo umount "${WORKDIR}/mnt"
  exit 1
fi

# ---------------------------------------------
# Step 5: Optional compression
# ---------------------------------------------
echo "[*] Compressing image..."
qemu-img convert -O qcow2 -c "$OUTPUT_IMAGE" "${OUTPUT_IMAGE%.qcow2}-compressed.qcow2"

echo "[✓] Done!"
echo " - Final image: ${OUTPUT_IMAGE%.qcow2}-compressed.qcow2"
