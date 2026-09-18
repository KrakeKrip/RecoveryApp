#!/bin/zsh
set -euo pipefail
unsetopt BG_NICE

pid_file="$1"
sleep 30 &
print $! > "$pid_file"
wait
