# Runbook del gateway OpenClaw en Docker.
#
# Orden de un montaje desde cero:
#   1. cp secrets.env.example secrets.env  y rellenar la API key + el token de Telegram
#   2. make setup             construye .env, arregla permisos, arranca el gateway
#   3. make onboard           registra el proveedor LLM (headless, sin prompts)
#   4. make telegram-pairing  conecta el bot en modo pairing
#   5. escribirle al bot; su respuesta trae tu user id numérico
#   6. make lockdown ID=<tu-user-id>   cierra el bot a tu cuenta y solo a tu cuenta
#   7. make verify

SHELL := /bin/bash
.DEFAULT_GOAL := help

BASE := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
REPO := $(BASE)/repo

# Nombre de proyecto fijo. Sin esto Compose lo derivaría del directorio del primer
# -f (o sea "repo") y los volúmenes con nombre cambiarían al mover ficheros.
COMPOSE_PROJECT_NAME := openclaw-agent

# Rutas de estado, fuera del contenedor para que sobrevivan al reemplazo de imagen.
OPENCLAW_CONFIG_DIR := $(BASE)/state
OPENCLAW_WORKSPACE_DIR := $(BASE)/workspace
OPENCLAW_AUTH_PROFILE_SECRET_DIR := $(BASE)/auth-secrets

include config.env
export

# Expansión perezosa (=, no :=): docker-compose.extra.yml lo genera setup.sh,
# así que puede no existir todavía cuando make parsea este fichero.
EXTRA = $(wildcard $(REPO)/docker-compose.extra.yml)
COMPOSE = docker compose -f $(REPO)/docker-compose.yml \
	$(if $(EXTRA),-f $(EXTRA),) \
	-f $(BASE)/docker-compose.hardening.yml

# Ejecuta un subcomando del CLI en un contenedor de un tiro, sin depender de que
# el gateway esté vivo. -T evita pedir pseudo-TTY (no lo hay en automatización).
ONESHOT = $(COMPOSE) run -T --rm --no-deps --entrypoint node openclaw-gateway dist/index.js

.PHONY: help
help:
	@echo "Montaje:    setup  onboard  telegram-pairing  lockdown ID=<userid>  verify"
	@echo "Operación:  up  down  restart  ps  logs  health  dashboard  doctor"
	@echo "Depuración: cli CMD='...'  shell  config-get P=<ruta>  whoami-help"
	@echo "Upgrade:    update"

# ---------------------------------------------------------------- montaje

.PHONY: dirs
dirs:
	@mkdir -p $(OPENCLAW_CONFIG_DIR) $(OPENCLAW_WORKSPACE_DIR) $(OPENCLAW_AUTH_PROFILE_SECRET_DIR)
	@chmod 700 $(OPENCLAW_CONFIG_DIR) $(OPENCLAW_AUTH_PROFILE_SECRET_DIR)

.PHONY: sync-secrets
sync-secrets:
	@bash $(BASE)/bin/sync-secrets.sh

# setup.sh reescribe repo/.env desde el entorno en cada ejecución, genera
# docker-compose.extra.yml para el volumen de /home/node, corrige el uid de los
# bind mounts con un contenedor root de un tiro, y levanta el gateway.
# El onboarding interactivo va desactivado vía OPENCLAW_SKIP_ONBOARDING en config.env.
.PHONY: setup
setup: dirs sync-secrets
	@bash $(REPO)/scripts/docker/setup.sh
	@$(MAKE) --no-print-directory fix-home-perms
	@$(MAKE) --no-print-directory up

# El chown de setup.sh cubre /home/node/.openclaw y /home/node/.config/openclaw,
# pero no /home/node/.cache. En la imagen -browser ese directorio lo crea root
# durante el build (al instalar Chromium de Playwright), y el volumen con nombre
# copia esa propiedad tal cual. Resultado: el gateway corre como uid 1000, no
# puede crear su directorio temporal /home/node/.cache/openclaw-1000, y entra en
# bucle de reinicio con "SQLite read-only worker Unable to create fallback temp dir".
#
# El contenido de .cache (~1 GB de Chromium) ya es de node:node, así que el chown
# va sin -R a propósito: arregla el directorio sin recorrer el árbol entero.
.PHONY: fix-home-perms
fix-home-perms:
	@docker run --rm -v $(COMPOSE_PROJECT_NAME)_$(OPENCLAW_HOME_VOLUME):/home/node \
		--user 0:0 --entrypoint sh $(OPENCLAW_IMAGE) \
		-c 'chown node:node /home/node/.cache' 
	@echo "==> Permisos de /home/node/.cache corregidos"

# Onboarding sin prompts. --secret-input-mode ref deja la clave como referencia a
# la variable de entorno en lugar de escribirla dentro de openclaw.json.
.PHONY: onboard
onboard:
	$(ONESHOT) onboard --non-interactive --accept-risk --skip-health \
		--mode local \
		--auth-choice $(OPENCLAW_AUTH_CHOICE) \
		--secret-input-mode ref \
		--gateway-auth token \
		--gateway-token-ref-env OPENCLAW_GATEWAY_TOKEN \
		--skip-channels \
		--no-install-daemon
	@$(MAKE) --no-print-directory up

# Conecta Telegram en modo pairing. --use-env deja el token en la variable de
# entorno en vez de copiarlo a openclaw.json, así que TELEGRAM_BOT_TOKEN tiene que
# seguir en repo/.env después de esto.
#
# pairing es un estado transitorio: sirve para descubrir tu user id numérico.
# No lo dejes así, pasa por `make lockdown`.
.PHONY: telegram-pairing
telegram-pairing:
	$(ONESHOT) channels add --channel telegram --use-env
	$(ONESHOT) config set --batch-json '[{"path":"channels.telegram.dmPolicy","value":"pairing"}]'
	@$(MAKE) --no-print-directory up
	@echo ""
	@echo "Ahora escríbele algo a tu bot por Telegram."
	@echo "Responderá con un código de pairing y tu user id numérico."
	@echo "Luego:  make lockdown ID=<ese-user-id>"

# Cierra el bot: solo tu user id puede hablarle, y solo tú eres owner de los
# comandos privilegiados y de las aprobaciones de ejecución.
#
# dmPolicy allowlist con allowFrom explícito es lo correcto para un bot de un
# dueño. Con "open" + allowFrom ["*"] cualquiera que adivine el nombre del bot
# tendría shell en este contenedor.
.PHONY: lockdown
lockdown:
	@test -n "$(ID)" || { echo "ERROR: falta ID. Uso: make lockdown ID=123456789"; exit 1; }
	@echo "$(ID)" | grep -Eq '^[0-9]+$$' || { echo "ERROR: ID debe ser tu user id NUMÉRICO de Telegram, no un username ni un chat de grupo."; exit 1; }
	$(ONESHOT) config set --batch-json '[ \
		{"path":"channels.telegram.dmPolicy","value":"allowlist"}, \
		{"path":"channels.telegram.allowFrom","value":["$(ID)"]}, \
		{"path":"channels.telegram.groupPolicy","value":"allowlist"}, \
		{"path":"commands.ownerAllowFrom","value":["telegram:$(ID)"]} \
	]'
	@$(MAKE) --no-print-directory up
	@echo "==> Bot restringido al user id $(ID)"

# Buscador web para la herramienta web_search. Ningún proveedor se auto-selecciona
# sin credencial usable, así que hay que elegirlo a mano.
#
# parallel-free: sin API key, índice pensado para agentes, devuelve extractos densos
# ordenados para contexto de LLM. La alternativa sin key es duckduckgo, pero upstream
# la marca como experimental porque scrapea el HTML sin JS y se rompe con los
# challenges anti-bot. Si quieres filtros por país/idioma y más fiabilidad, el
# camino es Brave: pon BRAVE_API_KEY en secrets.env y provider=brave.
.PHONY: websearch
websearch:
	@$(COMPOSE) run -T --rm openclaw-cli plugins install @openclaw/parallel-plugin || true
	@$(COMPOSE) run -T --rm openclaw-cli config set tools.web.search.provider parallel-free
	@$(MAKE) --no-print-directory up

.PHONY: verify
verify:
	@bash $(BASE)/bin/verify.sh

# ---------------------------------------------------------------- operación

.PHONY: up
up:
	@$(COMPOSE) up -d openclaw-gateway

.PHONY: down
down:
	@$(COMPOSE) down

# restart NO recarga cambios de entorno; up -d recrea el contenedor y sí los aplica.
.PHONY: restart
restart:
	@$(COMPOSE) up -d --force-recreate openclaw-gateway

.PHONY: ps
ps:
	@$(COMPOSE) ps

.PHONY: logs
logs:
	@$(COMPOSE) logs -f --tail 100 openclaw-gateway

.PHONY: health
health:
	@printf 'healthz  '; curl -fsS http://127.0.0.1:$(OPENCLAW_GATEWAY_PORT)/healthz  && echo || echo FALLO
	@printf 'startupz '; curl -fsS http://127.0.0.1:$(OPENCLAW_GATEWAY_PORT)/startupz && echo || echo FALLO
	@printf 'readyz   '; curl -fsS http://127.0.0.1:$(OPENCLAW_GATEWAY_PORT)/readyz   && echo || echo FALLO

.PHONY: dashboard
dashboard:
	@$(COMPOSE) run -T --rm openclaw-cli dashboard --no-open

.PHONY: doctor
doctor:
	@$(COMPOSE) run -T --rm openclaw-cli doctor --json

# ---------------------------------------------------------------- depuración

.PHONY: cli
cli:
	@test -n "$(CMD)" || { echo "Uso: make cli CMD='channels list'"; exit 1; }
	@$(COMPOSE) run -T --rm openclaw-cli $(CMD)

.PHONY: shell
shell:
	@$(COMPOSE) exec openclaw-gateway bash

.PHONY: config-get
config-get:
	@test -n "$(P)" || { echo "Uso: make config-get P=channels.telegram"; exit 1; }
	@$(COMPOSE) run -T --rm openclaw-cli config get $(P)

.PHONY: whoami-help
whoami-help:
	@echo "Tu user id numérico de Telegram, por orden de preferencia:"
	@echo "  1. make telegram-pairing y leerlo en la respuesta del bot"
	@echo "  2. make logs y buscar senderUserId en la entrada 'telegram pairing request'"
	@echo "  3. una vez autorizado, /whoami@<nombre_del_bot> en un grupo permitido"

# ---------------------------------------------------------------- upgrade

# Las etiquetas móviles (latest*) se reconstruyen cada semana con parches de SO.
# El arranque aplica las migraciones de upgrade solo; si el gateway se queda
# reiniciando, ejecuta `make doctor` con el mismo estado montado.
.PHONY: update
update:
	@docker pull $(OPENCLAW_IMAGE)
	@$(COMPOSE) up -d --force-recreate openclaw-gateway
	@$(MAKE) --no-print-directory health
