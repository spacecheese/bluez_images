#!/usr/bin/env bash
set -euo pipefail

IMAGE="${1}"
shift 

INTERACTIVE=0
while getopts ":i" opt; do
  case $opt in
    i) INTERACTIVE=1 ;;
    \?) echo "Invalid option: -$OPTARG" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(realpath "$(dirname "${BASH_SOURCE[0]}")")"
SSH_KEY="$SCRIPT_DIR/../id_ed25519"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

source "$SCRIPT_DIR/common.sh"

echo "[*] Starting QEMU session"
qemu-system-x86_64 \
  -m 2048 \
  -smp 2 \
  -nographic \
  -drive file="$IMAGE",format=qcow2 \
  -netdev user,id=net0,hostfwd=tcp::2244-:22 \
  -device virtio-net-pci,netdev=net0 \
  -no-reboot \
  -monitor none \
  -display none \
  -serial file:"$(pwd)/serial.log" &

QEMU_PID=$!
kill_qemu() {
  if kill -0 $QEMU_PID 2>/dev/null; then
    echo "[!] Killing QEMU"
    kill $QEMU_PID 2>/dev/null || true
  fi
}
trap kill_qemu EXIT
wait_for_ssh

if (( INTERACTIVE )); then
  $SSH -p 2244 tester@localhost
else
  EXIT_STATUS=0
  $SSH -p 2244 tester@localhost '
    echo "[*] Starting Bluez"
    sudo nohup btvirt -L -l >/dev/null 2>&1 &
    sudo service bluetooth start

    echo "[*] Checking Bluez DBus"
    busctl --system tree org.bluez
  ' || EXIT_STATUS=1

  echo "[*] Stopping QEMU"
  $SSH -p 2244 tester@localhost 'sudo shutdown -h now' || true
  
  echo "[*] Waiting for VM to shutdown"
  wait $QEMU_PID

  exit $EXIT_STATUS
fi
