#!/usr/bin/env bash
# Post-bootstrap checks. Fails loudly if something important isn't as it should be.
# The security block is what matters most here: an open Telegram bot is equivalent
# to handing shell access in this container to anyone who finds the bot.
set -uo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$BASE_DIR"

export COMPOSE_PROJECT_NAME=openclaw-agent
PORT="$(grep -E '^OPENCLAW_GATEWAY_PORT=' config.env | cut -d= -f2 | tr -d '[:space:]')"
PORT="${PORT:-18789}"

COMPOSE=(docker compose -f "$BASE_DIR/repo/docker-compose.yml")
[[ -f "$BASE_DIR/repo/docker-compose.extra.yml" ]] &&
  COMPOSE+=(-f "$BASE_DIR/repo/docker-compose.extra.yml")
COMPOSE+=(-f "$BASE_DIR/docker-compose.hardening.yml")

fails=0
ok() { printf '  \033[32mOK\033[0m    %s\n' "$1"; }
bad() {
  printf '  \033[31mFAIL\033[0m  %s\n' "$1"
  fails=$((fails + 1))
}
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$1"; }

echo "== Container =="
state="$(docker inspect -f '{{.State.Status}}' openclaw-agent-openclaw-gateway-1 2>/dev/null)"
if [[ "$state" == "running" ]]; then
  ok "gateway running"
  hs="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' \
    openclaw-agent-openclaw-gateway-1 2>/dev/null)"
  case "$hs" in
    healthy) ok "healthcheck: healthy" ;;
    starting) warn "healthcheck: starting (give it a few seconds)" ;;
    *) bad "healthcheck: $hs" ;;
  esac
else
  bad "gateway is not running (state: ${state:-nonexistent})"
fi

echo "== HTTP probes =="
for probe in healthz startupz readyz; do
  if curl -fsS --max-time 10 "http://127.0.0.1:$PORT/$probe" >/dev/null 2>&1; then
    ok "/$probe responds"
  else
    bad "/$probe does not respond"
  fi
done

echo "== Network exposure =="
# Every published binding must go to loopback. If 0.0.0.0 shows up, the Control UI
# is reachable from the LAN and that means full control of the agent.
bindings="$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{range $conf}}{{$p}}={{.HostIp}}:{{.HostPort}} {{end}}{{end}}' \
  openclaw-agent-openclaw-gateway-1 2>/dev/null)"
if [[ -z "$bindings" ]]; then
  bad "could not read the port bindings"
else
  exposed=0
  for b in $bindings; do
    hostip="${b#*=}"
    hostip="${hostip%:*}"
    if [[ "$hostip" != "127.0.0.1" && "$hostip" != "::1" ]]; then
      bad "port published outside loopback: $b"
      exposed=1
    fi
  done
  [[ "$exposed" -eq 0 ]] && ok "all published ports on loopback only: $bindings"
fi

echo "== LLM provider =="
models="$("${COMPOSE[@]}" run -T --rm openclaw-cli models list 2>&1)"
if [[ -n "$models" ]] && ! grep -qi "no models\|error\|not configured" <<<"$models"; then
  ok "the provider returns models"
else
  bad "no usable model provider (run: make onboard)"
  sed 's/^/        /' <<<"$(head -5 <<<"$models")"
fi

echo "== Telegram security =="
tg="$("${COMPOSE[@]}" run -T --rm openclaw-cli config get channels.telegram 2>&1)"
dmpolicy="$(grep -oE '"dmPolicy"[[:space:]]*:[[:space:]]*"[a-z]+"' <<<"$tg" | grep -oE '"[a-z]+"$' | tr -d '"')"

case "$dmpolicy" in
  allowlist)
    ok "dmPolicy = allowlist"
    if grep -qE '"allowFrom"' <<<"$tg"; then
      if grep -qE '"allowFrom"[^]]*"\*"' <<<"$tg"; then
        bad "allowFrom contains the \"*\" wildcard: the bot is public"
      else
        ok "allowFrom with explicit ids"
      fi
    else
      bad "allowFrom is empty with dmPolicy allowlist: the bot blocks every DM"
    fi
    ;;
  pairing)
    warn "dmPolicy = pairing. Transient state for discovering your user id."
    warn "Close it with: make lockdown ID=<your-user-id>"
    ;;
  open)
    bad "dmPolicy = open. Any Telegram account that finds the bot can give it orders."
    ;;
  *)
    bad "could not read channels.telegram.dmPolicy (channel not configured?)"
    ;;
esac

owner="$("${COMPOSE[@]}" run -T --rm openclaw-cli config get commands.ownerAllowFrom 2>&1)"
if grep -qE 'telegram:[0-9]+' <<<"$owner"; then
  ok "commands.ownerAllowFrom points at a specific Telegram account"
else
  warn "commands.ownerAllowFrom has no Telegram account: owner commands and approvals have no explicit operator"
fi

echo
if [[ "$fails" -eq 0 ]]; then
  echo -e "\033[32mAll good.\033[0m Control UI: http://127.0.0.1:$PORT/"
  echo "The Control UI token is in repo/.env as OPENCLAW_GATEWAY_TOKEN."
else
  echo -e "\033[31m$fails check(s) failed.\033[0m"
  exit 1
fi
