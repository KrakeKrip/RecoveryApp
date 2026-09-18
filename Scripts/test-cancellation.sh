#!/bin/zsh
set -euo pipefail
unsetopt BG_NICE

project_dir="${0:A:h:h}"
test_dir="$project_dir/work/tests/cancellation-$RANDOM-$$"
launcher="$test_dir/tool-launcher"
mock_tool="$project_dir/Tests/Fixtures/process-tree-tool.sh"
pid_file="$test_dir/child.pid"

mkdir -p "$test_dir"
clang -Os "$project_dir/Packaging/tool-launcher.c" -o "$launcher"

chmod +x "$mock_tool"

"$launcher" "$mock_tool" "$pid_file" &
leader_pid=$!

for _ in {1..40}; do
    [[ -s "$pid_file" ]] && break
    sleep 0.05
done
[[ -s "$pid_file" ]]
child_pid="$(cat "$pid_file")"

kill -TERM -- "-$leader_pid"
wait "$leader_pid" 2>/dev/null || true
sleep 0.1

if kill -0 "$leader_pid" 2>/dev/null || kill -0 "$child_pid" 2>/dev/null; then
    echo "FAIL: после отмены остался процесс" >&2
    exit 1
fi

echo "PASS: process group cancellation"
