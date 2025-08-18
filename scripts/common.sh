wait_for_ssh(){
    SSH_UP=0
    for i in {1..30}; do
    echo "[*] Waiting for SSH..."
    if $SSH -p 2244 tester@localhost 'true'; then
        echo "[✓] SSH Connected"
        SSH_UP=1
        break
    fi
    sleep 2
    done

    if [[ $SSH_UP -ne 1 ]]; then
    echo "[✗] SSH Connection Timed Out"
    exit 1
    fi
}