#!/usr/bin/env bash
# Comprobaciones post-montaje. Falla en rojo si algo importante no está como debe.
# Lo que más importa aquí es el bloque de seguridad: un bot de Telegram abierto
# equivale a dar shell en este contenedor a cualquiera que encuentre el bot.
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
  printf '  \033[31mFALLO\033[0m %s\n' "$1"
  fails=$((fails + 1))
}
warn() { printf '  \033[33mAVISO\033[0m %s\n' "$1"; }

echo "== Contenedor =="
state="$(docker inspect -f '{{.State.Status}}' openclaw-agent-openclaw-gateway-1 2>/dev/null)"
if [[ "$state" == "running" ]]; then
  ok "gateway corriendo"
  hs="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}sin-healthcheck{{end}}' \
    openclaw-agent-openclaw-gateway-1 2>/dev/null)"
  case "$hs" in
    healthy) ok "healthcheck: healthy" ;;
    starting) warn "healthcheck: starting (dale unos segundos)" ;;
    *) bad "healthcheck: $hs" ;;
  esac
else
  bad "gateway no está corriendo (estado: ${state:-inexistente})"
fi

echo "== Sondas HTTP =="
for probe in healthz startupz readyz; do
  if curl -fsS --max-time 10 "http://127.0.0.1:$PORT/$probe" >/dev/null 2>&1; then
    ok "/$probe responde"
  else
    bad "/$probe no responde"
  fi
done

echo "== Exposición de red =="
# Cada binding publicado debe ir a loopback. Si aparece 0.0.0.0, el Control UI
# está accesible desde la LAN y eso es control total del agente.
bindings="$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{range $conf}}{{$p}}={{.HostIp}}:{{.HostPort}} {{end}}{{end}}' \
  openclaw-agent-openclaw-gateway-1 2>/dev/null)"
if [[ -z "$bindings" ]]; then
  bad "no se pudieron leer los port bindings"
else
  exposed=0
  for b in $bindings; do
    hostip="${b#*=}"
    hostip="${hostip%:*}"
    if [[ "$hostip" != "127.0.0.1" && "$hostip" != "::1" ]]; then
      bad "puerto publicado fuera de loopback: $b"
      exposed=1
    fi
  done
  [[ "$exposed" -eq 0 ]] && ok "todos los puertos publicados solo en loopback: $bindings"
fi

echo "== Proveedor LLM =="
models="$("${COMPOSE[@]}" run -T --rm openclaw-cli models list 2>&1)"
if [[ -n "$models" ]] && ! grep -qi "no models\|error\|not configured" <<<"$models"; then
  ok "el proveedor devuelve modelos"
else
  bad "no hay proveedor de modelos usable (ejecuta: make onboard)"
  sed 's/^/        /' <<<"$(head -5 <<<"$models")"
fi

echo "== Seguridad de Telegram =="
tg="$("${COMPOSE[@]}" run -T --rm openclaw-cli config get channels.telegram 2>&1)"
dmpolicy="$(grep -oE '"dmPolicy"[[:space:]]*:[[:space:]]*"[a-z]+"' <<<"$tg" | grep -oE '"[a-z]+"$' | tr -d '"')"

case "$dmpolicy" in
  allowlist)
    ok "dmPolicy = allowlist"
    if grep -qE '"allowFrom"' <<<"$tg"; then
      if grep -qE '"allowFrom"[^]]*"\*"' <<<"$tg"; then
        bad "allowFrom contiene el comodín \"*\": el bot es público"
      else
        ok "allowFrom con ids explícitos"
      fi
    else
      bad "allowFrom vacío con dmPolicy allowlist: el bot bloquea todos los DMs"
    fi
    ;;
  pairing)
    warn "dmPolicy = pairing. Estado transitorio para descubrir tu user id."
    warn "Ciérralo con: make lockdown ID=<tu-user-id>"
    ;;
  open)
    bad "dmPolicy = open. Cualquier cuenta de Telegram que encuentre el bot puede darle órdenes."
    ;;
  *)
    bad "no se pudo leer channels.telegram.dmPolicy (¿canal sin configurar?)"
    ;;
esac

owner="$("${COMPOSE[@]}" run -T --rm openclaw-cli config get commands.ownerAllowFrom 2>&1)"
if grep -qE 'telegram:[0-9]+' <<<"$owner"; then
  ok "commands.ownerAllowFrom apunta a una cuenta de Telegram concreta"
else
  warn "commands.ownerAllowFrom sin cuenta de Telegram: comandos de owner y aprobaciones sin operador explícito"
fi

echo
if [[ "$fails" -eq 0 ]]; then
  echo -e "\033[32mTodo en orden.\033[0m Control UI: http://127.0.0.1:$PORT/"
  echo "El token del Control UI está en repo/.env como OPENCLAW_GATEWAY_TOKEN."
else
  echo -e "\033[31m$fails comprobación(es) fallidas.\033[0m"
  exit 1
fi
