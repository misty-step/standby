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
