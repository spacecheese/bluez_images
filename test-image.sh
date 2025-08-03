#!/usr/bin/env bash
set -euo pipefail

IMAGE="${1}"

echo "[*] Starting QEMU session"
qemu-system-x86_64 \
    -accel tcg \
    -m 2048 \
    -smp 2 \
    -cpu max \
    -drive file=${IMAGE},format=qcow2 \
    -netdev user,id=net0,hostfwd=tcp::2222-:22 \
    -device virtio-net-pci,netdev=net0 \
    -no-reboot \
    -monitor none \
    -display none \
    -serial file:serial.log \
    -daemonize

ssh-keygen -R "[localhost]:2222" || true

SSH_UP=0
for i in {1..30}; do
    echo "[*] Waiting for SSH..."
    if sshpass -p test ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -p 2222 tester@localhost 'true' 2>/dev/null; then
        echo "[✓] SSH Connected"
        SSH_UP=1
        break
    fi
    sleep 5
done

if [[ $SSH_UP -ne 1 ]]; then
    echo "[✗] SSH Connection Timed Out"
    exit 1
fi

sshpass -p test ssh -p 2222 -o StrictHostKeyChecking=no tester@localhost '
    EXIT_STATUS=0

    echo "[*] Starting Bluez"
    sudo nohup btvirt -L -l >/dev/null 2>&1 &
    sudo service bluetooth start || EXIT_STATUS=1

    echo "[*] Checking Bluez DBus"
    busctl --system tree org.bluez || EXIT_STATUS=1

    echo "[*] Stopping QEMU"
    sudo shutdown -h now

    exit $EXIT_STATUS
'
