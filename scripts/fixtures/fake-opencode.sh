#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" != "run" ]; then
  echo "fake opencode supports only: opencode run" >&2
  exit 64
fi

printf '%s\n' "$@" > "$PWD/opencode-args.txt"

prompt_file=""
request_file=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--file" ]; then
    shift
    case "${1:-}" in
      *prompt.txt) prompt_file="$1" ;;
      *job-request.json) request_file="$1" ;;
    esac
  fi
  shift || true
done

run_count=1
if [ -f "$PWD/run-count.txt" ]; then
  run_count="$(cat "$PWD/run-count.txt" 2>/dev/null || printf '0')"
  run_count=$((run_count + 1))
fi
printf '%s\n' "$run_count" > "$PWD/run-count.txt"

if [ -n "$prompt_file" ] && grep -q "WAIT_FOR_RELEASE_MARKER" "$prompt_file"; then
  printf 'started\n' > "$PWD/started.marker"
  for _ in $(seq 1 240); do
    [ -f "$PWD/release.marker" ] && break
    sleep 0.25
  done
  if [ ! -f "$PWD/release.marker" ]; then
    echo "fake opencode timed out waiting for release.marker" >&2
    exit 75
  fi
fi

{
  echo "# OpenCode worker result"
  echo
  echo "## Request"
  if [ -n "$request_file" ]; then
    node -e 'const fs=require("fs"); const p=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); console.log(p.title || "untitled")' "$request_file"
  fi
  echo
  echo "## Prompt"
  if [ -n "$prompt_file" ]; then
    head -c 1200 "$prompt_file"
    echo
  fi
  echo
  echo "## Receipt"
  echo "Produced by fake OpenCode fixture for Standby verification."
} > "$PWD/artifact.md"

printf '{"type":"message","text":"fake opencode completed"}\n'
