#!/usr/bin/env bash
# Copia las claves con valor de secrets.env al repo/.env que lee Docker Compose.
#
# Existe porque scripts/docker/setup.sh reescribe repo/.env desde el entorno del shell
# en cada ejecución: gestiona su propia lista de claves OPENCLAW_* y conserva
# intactas las líneas que no conoce. Los secretos de proveedor y de canal son
# justamente líneas que no conoce, así que los inyectamos nosotros.
#
# Las claves vacías se omiten para no pisar un valor bueno con una cadena vacía.
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_FILE="$BASE_DIR/secrets.env"
ENV_FILE="$BASE_DIR/repo/.env"

if [[ ! -f "$SECRETS_FILE" ]]; then
  echo "ERROR: falta $SECRETS_FILE. Copia secrets.env.example y rellénalo." >&2
  exit 1
fi

mkdir -p "$(dirname "$ENV_FILE")"
touch "$ENV_FILE"
chmod 600 "$ENV_FILE"

upsert() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  # Reescribe la línea si la clave ya existe, la añade si no.
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
  # Salta comentarios y líneas en blanco.
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ "$line" =~ ^[[:space:]]*$ ]] && continue
  [[ "$line" != *=* ]] && continue

  key="${line%%=*}"
  value="${line#*=}"
  key="$(printf '%s' "$key" | tr -d '[:space:]')"
  [[ -z "$value" ]] && continue

  upsert "$key" "$value"
  count=$((count + 1))
  echo "  sincronizada: $key"
done <"$SECRETS_FILE"

echo "==> $count clave(s) sincronizadas en repo/.env"
