#!/usr/bin/env bash
# Copies the non-empty keys from secrets.env into the repo/.env that Docker Compose reads.
#
# This exists because scripts/docker/setup.sh rewrites repo/.env from the shell environment
# on every run: it manages its own list of OPENCLAW_* keys and leaves lines it doesn't
# recognize untouched. The provider and channel secrets are precisely lines it doesn't
# recognize, so we inject them ourselves.
#
# Empty keys are skipped so a good value never gets clobbered with an empty string.
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_FILE="$BASE_DIR/secrets.env"
ENV_FILE="$BASE_DIR/repo/.env"

if [[ ! -f "$SECRETS_FILE" ]]; then
  echo "ERROR: $SECRETS_FILE is missing. Copy secrets.env.example and fill it in." >&2
  exit 1
fi

mkdir -p "$(dirname "$ENV_FILE")"
touch "$ENV_FILE"
chmod 600 "$ENV_FILE"

upsert() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  # Rewrites the line if the key already exists, appends it otherwise.
  local seen=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "${line%%=*}" == "$key" ]]; then
      printf '%s=%s\n' "$key" "$value" >>"$tmp"
      seen=1
    else
      printf '%s\n' "$line" >>"$tmp"
    fi
  done <"$ENV_FILE"
  if [[ "$seen" -eq 0 ]]; then
    printf '%s=%s\n' "$key" "$value" >>"$tmp"
  fi
  mv "$tmp" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

count=0
while IFS= read -r line || [[ -n "$line" ]]; do
  # Skip comments and blank lines.
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ "$line" =~ ^[[:space:]]*$ ]] && continue
  [[ "$line" != *=* ]] && continue

  key="${line%%=*}"
  value="${line#*=}"
  key="$(printf '%s' "$key" | tr -d '[:space:]')"
  [[ -z "$value" ]] && continue

  upsert "$key" "$value"
  count=$((count + 1))
  echo "  synced: $key"
done <"$SECRETS_FILE"

echo "==> $count key(s) synced into repo/.env"
