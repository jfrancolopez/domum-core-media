#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || fail "docker is unavailable"
docker compose version >/dev/null 2>&1 || fail "Docker Compose plugin is unavailable"

cd "$REPO_ROOT"
args=(-f compose/base.yml)
while IFS= read -r file; do
  args+=(-f "$file")
done < <(find compose -name '*.yml' -not -path 'compose/base.yml' \
  -not -path '*/traefik/*' | sort)

echo "EXEMPT: compose/proxy/traefik/ contains Traefik runtime config, not Compose services"
rendered="$(env -i PATH="$PATH" HOME="${HOME:-/nonexistent}" \
  docker compose --project-directory "$REPO_ROOT" --env-file config/ci.env \
  "${args[@]}" config --format json)" \
  || fail "Docker Compose could not render the service fragments"

printf '%s\n' "$rendered" | python3 -c '
import json
import sys

services = json.load(sys.stdin).get("services", {})
if not services:
    print("FAIL: rendered Compose configuration contains no services", file=sys.stderr)
    raise SystemExit(1)

missing = [
    (name, service.get("security_opt", []))
    for name, service in sorted(services.items())
    if "no-new-privileges:true" not in service.get("security_opt", [])
]
if missing:
    for name, options in missing:
        print(f"FAIL: service {name} lacks security_opt no-new-privileges:true (got {options})", file=sys.stderr)
    raise SystemExit(1)

print(f"PASS: all {len(services)} rendered Compose services set no-new-privileges:true")
'
