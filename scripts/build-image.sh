#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(realpath "$(dirname "${BASH_SOURCE[0]}")")"
source "$SCRIPT_DIR/common.sh"

SSH_KEY="$SCRIPT_DIR/../id_ed25519"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

BLUEZ_VERSION="${1:-5.70}"
OS_VERSION_STR="${2:-ubuntu-24.04}"
eval "$($SCRIPT_DIR/resolve-os.sh ${OS_VERSION_STR})"

WORKDIR="$(pwd)/${OS_VERSION_STR}-bluez-${BLUEZ_VERSION}"
STAGING_DIR="${WORKDIR}/staging"
CLOUDINIT_DIR="$SCRIPT_DIR/../cloud-init"

OUTPUT_IMAGE="${OS_VERSION_STR}-bluez-${BLUEZ_VERSION}.qcow2"
SEED_IMAGE="${WORKDIR}/seed.img"

mkdir -p "$WORKDIR"
cd "$WORKDIR"

# -----------------------------
# Download base cloud image
# -----------------------------
if [[ ! -f "base.img" ]]; then
  wget -O "base.img" ${OS_CLOUDIMG}

  # Older kvm kernels don't support the vhci module so we need to manually swap.
  if [[ "$OS_VERSION_STR" == "ubuntu-18.04" ]]; then
    echo "[!] Resizing base image"
    qemu-img resize base.img +1G
  fi
fi

cp "base.img" "$OUTPUT_IMAGE"

# ----------------------------
# Prepare cloud-init image
# ----------------------------
envsubst < ${CLOUDINIT_DIR}/user-data.yml.template > ${WORKDIR}/user-data.yml
# Create seed.img
cloud-localds "$SEED_IMAGE" "${WORKDIR}/user-data.yml" "${CLOUDINIT_DIR}/meta-data.yml"

# ---------------------------------
# Boot VM to trigger cloud-init
# ---------------------------------
echo "[*] Booting QEMU to apply cloud-init"
qemu-system-x86_64 \
  -m 2048 \
  -smp 2 \
  -nographic \
  -drive file="$OUTPUT_IMAGE",format=qcow2 \
  -drive file="$SEED_IMAGE",format=raw \
  -netdev user,id=net0,hostfwd=tcp::2244-:22 \
  -device virtio-net-pci,netdev=net0 \
  -no-reboot \
  -monitor none \
  -display none \
  -serial file:"$WORKDIR/serial.log" &

QEMU_PID=$!
kill_qemu() {
  if kill -0 $QEMU_PID 2>/dev/null; then
    echo "[!] Killing QEMU"
    kill $QEMU_PID 2>/dev/null || true
  fi
}
trap kill_qemu EXIT

# -------------
# Build BlueZ
# -------------
echo "[*] Building BlueZ version ${BLUEZ_VERSION} on ${OS_VERSION_STR}"
rm -rf "$STAGING_DIR"
$SCRIPT_DIR/build-bluez.sh $BLUEZ_VERSION $OS_DOCKERIMG $STAGING_DIR

cd "$WORKDIR"

wait_for_ssh

echo "[*] Waiting for cloud-init to finish"
$SSH -p 2244 tester@localhost 'cloud-init status --wait'

if [[ "$OS_VERSION_STR" == "ubuntu-18.04" ]]; then
  echo "[*] Swapping to generic kernel"
  $SSH -p 2244 tester@localhost '
    sudo apt-get install -y linux-firmware
    sudo apt-get install -y linux-image-generic

    sudo sed -i "s/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/" /etc/default/grub
    sudo update-grub

    NEW_KERNEL=$(basename $(ls -1 /boot/vmlinuz-*-generic | tail -n1) | sed "s/^vmlinuz-//")
    MENU_ENTRY=$(grep "$NEW_KERNEL" /boot/grub/grub.cfg | head -n1 | cut -d"'"'"'" -f2)
    echo "[*] Rebooting with $MENU_ENTRY"
    sudo grub-set-default "Advanced options for Ubuntu>$MENU_ENTRY"
  '
  $SSH -p 2244 tester@localhost 'sudo reboot now' || true

  wait $QEMU_PID
  qemu-system-x86_64 \
    -m 2048 \
    -smp 2 \
    -nographic \
    -drive file="$OUTPUT_IMAGE",format=qcow2 \
    -netdev user,id=net0,hostfwd=tcp::2244-:22 \
    -device virtio-net-pci,netdev=net0 \
    -no-reboot \
    -monitor none \
    -display none \
    -serial file:"$WORKDIR/serial-new-kernel.log" &
  QEMU_PID=$!

  wait_for_ssh

  echo "[*] Removing old kernel"
  $SSH -p 2244 tester@localhost '
    sudo apt-get purge -y linux-*-kvm
    sudo apt-get autoremove --purge
  '
fi

echo "[*] Installing vhci module"
$SSH -p 2244 tester@localhost '
  sudo apt-get install -y linux-modules-extra-$(uname -r)
  echo "hci_vhci" | sudo tee /etc/modules-load.d/hci_vhci.conf
'

echo "[*] Installing Bluez"
rsync -a --ignore-existing --progress --rsync-path="sudo rsync" \
  -e "$SSH -p 2244" \
  "$STAGING_DIR/" tester@localhost:/
$SSH -p 2244 tester@localhost 'sudo systemctl enable bluetooth'
$SSH -p 2244 tester@localhost 'sudo shutdown -h now' || true

echo "[*] Waiting for VM to shutdown"
wait $QEMU_PID

echo "[*] Compressing image..."
qemu-img convert -O qcow2 -c "$OUTPUT_IMAGE" "${OUTPUT_IMAGE%.qcow2}-compressed.qcow2"
rm -f "$OUTPUT_IMAGE"
mv "${OUTPUT_IMAGE%.qcow2}-compressed.qcow2" "$OUTPUT_IMAGE"

echo "[✓] Done!"
echo " - Final image: $OUTPUT_IMAGE"
