#!/bin/zsh
set -euo pipefail
unsetopt BG_NICE

pid_file="${RECOVERYAPP_CANCEL_PID_FILE:?}"
echo "Mock untrunc started"
sleep 30 &
print $! > "$pid_file"
wait
