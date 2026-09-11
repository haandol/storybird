#!/usr/bin/env bash
# Keep the existing entrypoint; parsing and state reporting use Python's stdlib.
set -euo pipefail
exec python3 "$(dirname "$0")/collect_release_facts.py" "$@"
