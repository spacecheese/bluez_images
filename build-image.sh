#!/bin/bash
set -euo pipefail

BLUEZ_VERSION="${1:-5.70}"
OS_VERSION_STR="${2:-ubuntu-24.04}"
eval "$(./resolve-os.sh ${OS_VERSION_STR})"

WORKDIR="$(pwd)/${OS_VERSION_STR}-bluez-${BLUEZ_VERSION}"
STAGING_DIR="${WORKDIR}/staging"
CLOUDINIT_DIR="${WORKDIR}/cloudinit"

OUTPUT_IMAGE="${OS_VERSION_STR}-bluez-${BLUEZ_VERSION}.qcow2"
SEED_IMAGE="${WORKDIR}/seed.img"
STAGING_IMAGE="${WORKDIR}/bluez-tarball.img"

echo "[*] Building BlueZ version ${BLUEZ_VERSION} on ${OS_VERSION_STR}"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

# ----------------------------
# Download and build BlueZ
# ----------------------------
wget -nc "https://www.kernel.org/pub/linux/bluetooth/bluez-${BLUEZ_VERSION}.tar.xz"
tar xf "bluez-${BLUEZ_VERSION}.tar.xz"
cd "bluez-${BLUEZ_VERSION}"

apt-get update
apt-get install -y build-essential libdbus-1-dev libudev-dev libical-dev \
  libreadline-dev libglib2.0-dev libbluetooth-dev libusb-dev \
  dbus wget curl ca-certificates python3 cloud-image-utils qemu-utils \
  python3-docutils udev

./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var --enable-testing --enable-experimental
make -j"$(nproc)"

rm -rf "$STAGING_DIR"
make DESTDIR="$STAGING_DIR" install
cp emulator/btvirt tools/btmgmt $STAGING_DIR/usr/bin/

cd "$WORKDIR"
tar czf "bluez-staging.tar.gz" -C staging .

# Create and format disk
dd if=/dev/zero of="$STAGING_IMAGE" bs=1M count=64
mkfs.vfat -n BLUEZ "$STAGING_IMAGE"

# Mount and copy tarball
mkdir -p "$WORKDIR/mnt"
ls $STAGING_IMAGE
mount -o loop "$STAGING_IMAGE" "$WORKDIR/mnt"
cp "$WORKDIR/bluez-staging.tar.gz" "$WORKDIR/mnt/"
sync
umount "$WORKDIR/mnt"

# -----------------------------
# Prepare cloud-init config
# -----------------------------
mkdir -p "$CLOUDINIT_DIR"

cat > "$CLOUDINIT_DIR/meta-data" <<EOF
instance-id: bluez-${BLUEZ_VERSION}
local-hostname: bluez-vm
EOF

cat > "$CLOUDINIT_DIR/user-data" <<'EOF'
#cloud-config
hostname: bluez-vm
ssh_pwauth: true
users:
  - name: tester
    groups: sudo
    shell: /bin/bash
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    lock_passwd: false
    plain_text_passwd: test

package_update: true
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

      sudo apt-get install -y linux-modules-extra-$(uname -r)
      echo hci_vhci >> /etc/modules-load.d/hci_vhci.conf

      cp -a /tmp/bluez-staging/usr/* /usr/
      systemctl enable bluetooth

      sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="console=ttyS0"/' /etc/default/grub
      echo 'GRUB_TERMINAL=serial' >> /etc/default/grub
      update-grub

      echo "success" > /mnt/extra/status.ok

runcmd:
  - /usr/local/bin/bluez-init.sh

power_state:
  mode: poweroff
  timeout: 30
  condition: true
EOF

cp "bluez-staging.tar.gz" "${CLOUDINIT_DIR}/bluez-staging.tar.gz"

# Create seed.img
cloud-localds "$SEED_IMAGE" "${CLOUDINIT_DIR}/user-data" "${CLOUDINIT_DIR}/meta-data"

# -----------------------------
# Download base cloud image
# -----------------------------
if [[ ! -f "base.img" ]]; then
  wget -O "base.img" ${OS_CLOUDIMG}
fi

cp "base.img" "$OUTPUT_IMAGE"

# ---------------------------------
# Boot VM to trigger cloud-init
# ---------------------------------
echo "[*] Booting QEMU to apply cloud-init (you may see a console)..."

qemu-system-x86_64 \
  -m 2048 \
  -smp 2 \
  -nographic \
  -drive file="$OUTPUT_IMAGE",format=qcow2 \
  -drive file="$SEED_IMAGE",format=raw \
  -drive file="$STAGING_IMAGE",format=raw,media=disk \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -device virtio-net-pci,netdev=net0 \
  -no-reboot \
  -serial mon:stdio \
  -display none

# Wait for VM to shut down and check result
mount -o loop "$STAGING_IMAGE" "${WORKDIR}/mnt"

if [[ -f "${WORKDIR}/mnt/status.ok" ]]; then
  umount "${WORKDIR}/mnt"
  echo "[✓] Cloud-init completed successfully."
else
  echo "[✗] Cloud-init failed or did not report status."
  umount "${WORKDIR}/mnt"
  exit 1
fi

echo "[*] Compressing image..."
qemu-img convert -O qcow2 -c "$OUTPUT_IMAGE" "${OUTPUT_IMAGE%.qcow2}-compressed.qcow2"

echo "[✓] Done!"
echo " - Final image: ${WORKDIR}/${OUTPUT_IMAGE%.qcow2}-compressed.qcow2"
