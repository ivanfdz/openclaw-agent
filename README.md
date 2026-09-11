# openclaw-agent

Un asistente de IA con acceso a shell, ficheros y navegador, al que le hablas por Telegram desde
el móvil. Corre en un contenedor Docker aislado en tu propia máquina.

Este repo **no** es el agente: es la capa de despliegue y endurecimiento alrededor de
[OpenClaw](https://github.com/openclaw/openclaw). Lo que aporta:

- **Un runbook en un `Makefile`.** Montaje desde cero en seis comandos, sin prompts interactivos.
- **Estado fuera del contenedor.** Config, SQLite y workspace viven en este directorio; el
  contenedor es desechable y se reemplaza en cada actualización de imagen sin perder nada.
- **Endurecimiento de red.** El compose de upstream publica el Control UI en `0.0.0.0`; aquí se
  reescribe para que escuche solo en loopback.
- **Cierre del bot a un único dueño.** `make lockdown` fija la allowlist de Telegram a tu user id
  y te hace operador explícito de los comandos privilegiados.
- **Un verificador.** `make verify` falla si la configuración se ha quedado en un estado abierto.
- **Gestión de secretos.** `secrets.env` fuera de git, sincronizado al `.env` que lee Compose por
  un script que sobrevive a las reescrituras de `setup.sh`.

Todo lo que aprendimos peleándonos con el montaje está documentado en
[Detalles que muerden](#detalles-que-muerden): cuotas de modelo, el heartbeat que se come el tier
gratuito, colisiones de sesión entre CLI y Telegram.

## Por qué en Docker

El agente ejecuta shell, lee y escribe ficheros y navega. En Docker el radio de daño queda
acotado al contenedor: si algo se va de madre, no se lleva por delante tu `$HOME`.
La imagen de upstream ya corre como usuario `node` (uid 1000), no root, con `no-new-privileges`
y sin `NET_RAW`/`NET_ADMIN`.

## Requisitos

- Docker con Compose v2 ≥ 2.24 (el tag `!override` del hardening necesita esa versión)
- `make`, `bash`, `curl`, `git`
- Un bot de Telegram creado con [@BotFather](https://t.me/BotFather) (`/newbot`)
- Una API key de un proveedor LLM: Anthropic, OpenAI o Google AI Studio
- ~4 GB de disco para la imagen `latest-browser` (trae Chromium)

## Layout

```
openclaw-agent/
├── repo/                          clon de openclaw/openclaw (aquí vive el docker-compose.yml)
├── state/                         -> /home/node/.openclaw   config + SQLite + .env del gateway
├── workspace/                     -> workspace del agente
├── auth-secrets/                  -> clave de recuperación de credenciales OAuth heredadas
├── config.env                     tunables no sensibles
├── secrets.env                    API keys y token del bot (gitignored)
├── docker-compose.hardening.yml   publica los puertos solo en loopback
├── Makefile                       runbook
└── bin/                           sync-secrets.sh, verify.sh
```

`repo/`, `state/`, `workspace/` y `auth-secrets/` están gitignored: el primero porque es un clon
de upstream, los otros tres porque son estado local. Al clonar este repo tendrás que traerte
`repo/` y dejar que el montaje cree el resto.

`state/` es material sensible. Los tokens OAuth se guardan en claro en la SQLite,
así que trata ese directorio y sus copias de seguridad como credenciales.

## Montaje

```bash
git clone https://github.com/openclaw/openclaw.git repo
cp secrets.env.example secrets.env     # rellena la API key y el token de @BotFather
make setup                             # .env, permisos, arranque
make onboard                           # registra el proveedor LLM, sin prompts
make telegram-pairing                  # conecta el bot en modo pairing
# escríbele al bot: su respuesta trae tu user id numérico
make lockdown ID=<tu-user-id>          # cierra el bot a tu cuenta
make verify
```

`make setup` no construye la imagen: usa la prebuilt oficial `latest-browser`, que ya trae
Chromium. Compilar desde fuente pediría 6 GB de RAM al builder y no aporta nada aquí.

Opcional, para que el agente pueda buscar en la web: `make websearch`. Instala el plugin
`parallel-free`, que no pide API key y devuelve extractos densos pensados para contexto de LLM.
La otra opción sin key es `duckduckgo`, pero upstream la marca como experimental porque scrapea
HTML sin JS y se rompe con los challenges anti-bot. Para filtros por país/idioma y más
fiabilidad, el camino es Brave: `BRAVE_API_KEY` en `secrets.env` y `provider=brave`.

## El modelo de seguridad, en corto

Un bot de Telegram es alcanzable por cualquiera que sepa su nombre de usuario. El bot tiene
shell en el contenedor. Por lo tanto la única configuración aceptable para un bot de un solo
dueño es `dmPolicy: allowlist` con tu user id numérico explícito en `allowFrom`.

- `pairing` (el default de upstream) es un estado de tránsito para descubrir tu user id.
- `open` con `allowFrom: ["*"]` es un bot público. No lo uses aquí.
- `make lockdown` fija además `commands.ownerAllowFrom` a `telegram:<tu-id>`, que es lo que
  da operador explícito a los comandos privilegiados y a las aprobaciones de ejecución.
- `make verify` falla si detecta `open`, un comodín en `allowFrom`, o un puerto publicado
  fuera de loopback.

Aparte de eso: el contenido que el agente lee de la web o del correo es no confiable. Si una
página trae texto con pinta de instrucciones, para el agente es un intento de inyección de
prompt. Cuanto más acotadas estén las credenciales que le des, menos importa.

## Día a día

| Qué | Comando |
| --- | --- |
| Arrancar / parar | `make up` / `make down` |
| Recrear aplicando cambios de entorno | `make restart` |
| Logs | `make logs` |
| Sondas de salud | `make health` |
| URL del Control UI | `make dashboard` |
| Preflight de despliegue | `make doctor` |
| Un comando del CLI | `make cli CMD='channels list'` |
| Leer config | `make config-get P=channels.telegram` |
| Actualizar imagen | `make update` |

El Control UI queda en `http://127.0.0.1:18789/`. El token está en `repo/.env` como
`OPENCLAW_GATEWAY_TOKEN`. `config get` lo redacta, así que léelo del fichero.

`docker compose restart` no aplica cambios de entorno; por eso `make restart` hace
`up -d --force-recreate`.

## Detalles que muerden

**`setup.sh` reescribe `repo/.env` desde el entorno del shell** en cada ejecución. No edites
`repo/.env` a mano esperando que sobreviva: los tunables van en `config.env` y los secretos en
`secrets.env`. El script conserva las líneas cuyas claves no gestiona, y de eso se aprovecha
`bin/sync-secrets.sh` para inyectar las claves de proveedor y de canal.

**`docker-compose.override.yml` no se auto-carga.** `setup.sh` invoca Compose con `-f`
explícitos, lo que desactiva el descubrimiento automático del override. De ahí que el
endurecimiento viva en `docker-compose.hardening.yml` y que el Makefile pase siempre la lista
completa de ficheros. Si añades ficheros de Compose, mantén el mismo orden en todos los
comandos o los mounts cambian bajo tus pies.

**Los servicios locales del host no están en `127.0.0.1`.** Dentro del contenedor esa
dirección es el propio contenedor. Para Ollama o LM Studio corriendo en el Mac, usa
`http://host.docker.internal:11434` y `:1234`; el compose ya mapea el alias.

**Actualizaciones.** Las etiquetas móviles (`latest*`) se reconstruyen cada semana con parches
de SO. El arranque aplica las migraciones de upgrade por sí solo. Si tras un cambio de imagen
el contenedor se queda reiniciando, ejecuta `make doctor` contra el mismo estado montado.

**Elegir modelo en Gemini tiene cuatro trampas.** `models list` mezcla el catálogo local del
plugin con lo que el proveedor anuncia en vivo, y no todo lo listado es invocable. Verificado
atacando la API directamente:

| Síntoma | Causa | Qué hacer |
| --- | --- | --- |
| 429 `RESOURCE_EXHAUSTED` | `gemini-3.1-pro-preview`, el que elige el onboarding, no entra en el tier gratuito | usar un `flash` |
| `Unknown model` al invocar | el modelo sale en `models list` pero no está en el catálogo del plugin (p.ej. `gemini-3.8-flash`); `models set` lo acepta con un aviso que va en serio | elegir uno del catálogo |
| 404 `no longer available to new users` | `gemini-2.5-flash` y `2.5-flash-lite` están retirados para cuentas nuevas | Google recomienda `gemini-3.6-flash` |
| 503 `UNAVAILABLE`, high demand | `gemini-3.6-flash` y `3.7-flash` se saturan de forma intermitente | transitorio, pero no lo pongas como primario |

Configuración actual: primario `google/gemini-3.5-flash`, que es el que responde de forma
estable, con `3.6-flash` y `3.7-flash` como fallbacks.

**Limitación conocida de esa cadena de fallbacks:** los tres modelos son de Gemini. Sirve para
un 503 de un modelo concreto, pero no para un 429 de cuota, que es del proyecto entero y tumba
los tres a la vez. El arreglo de verdad es un fallback de otro proveedor: su key en
`secrets.env` y `make cli CMD='models fallbacks add <proveedor>/<modelo>'`.

**Diagnosticar fallos de modelo.** Para separar si el problema es el modelo, la cuota o
OpenClaw, ataca la API a pelo. Usa el endpoint `v1`, no `v1beta`: en las pruebas `v1beta`
devolvía 404 con cuerpo vacío mientras `v1` daba el JSON de error real. Y lanza las peticiones
de una en una, porque en ráfaga también responde con cuerpos vacíos.

```bash
curl -sS -X POST \
  "https://generativelanguage.googleapis.com/v1/models/<modelo>:generateContent" \
  -H "x-goog-api-key: $GEMINI_API_KEY" -H 'Content-Type: application/json' \
  -d '{"contents":[{"parts":[{"text":"hola"}]}]}'
```

**El heartbeat se come la cuota gratuita.** OpenClaw crea tres automatizaciones de serie, y una
de ellas, `Heartbeat (main)`, lanza un turno de agente **cada 30 minutos** por defecto. Son 48
turnos al día que nadie ha pedido, contra el tier gratuito de tu proveedor. Es el principal
candidato a que te aparezca un 429 sin haber hecho nada.

Aquí está desactivado con `agents.defaults.heartbeat.every = 0m`. Eso apaga solo la cadencia
recurrente; los despertares puntuales por evento siguen disponibles. Para reactivarlo:

```bash
make cli CMD='config set agents.defaults.heartbeat.every 30m'
```

Las otras dos automatizaciones son mucho más benignas: `Memory Dreaming Promotion` (diaria a
las 03:00, en sesión aislada) y `Skill collection review` (semanal). Míralas con
`make cli CMD='cron list'`.

**Las sesiones se comparten entre CLI y Telegram.** `agent:main:main` acumula como
participantes tanto `cli` como `telegram:<tu-id>`. Si pruebas por CLI mientras el bot atiende
un mensaje tuyo, chocan y sale `SESSION_WORK_START_CHANGED`. Peor: si matas un proceso del CLI
a medias, la sesión se queda en `status: running` y bloquea también los mensajes de Telegram.

- Para diagnosticar sin molestar al bot, usa una sesión aparte:
  `make cli CMD='agent --session-key agent:main:diag --message "..."'`
- Para ver el estado: `make cli CMD='sessions list --json'`
- Para soltar una reclamación rancia, `make restart` la limpia. No hace falta borrar la sesión.

Los mensajes entrantes de canal sí reintentan ante ese error por su cuenta
(`src/channels/message/ingress-retry-policy.ts`), así que un choque puntual no te pierde el
mensaje.

**Probar la salida sin tocar el móvil.** `message send` inyecta un mensaje por el canal sin
pasar por el agente, útil para separar "el bot no llega a mi teléfono" de "el modelo falla":

```bash
make cli CMD='message send --channel telegram --target <tu-id> --message "prueba"'
```

## Sobre automatizar compras (cine, etc.)

La parte de "hablarle por Telegram y que investigue" es sólida. La de "que compre" no, y no por
el agente: las webs de venta van detrás de anti-bot, los mapas de asientos son canvas sin DOM
semántico, y el pago con SCA pide un OTP que el agente no puede ni debe resolver.

El diseño que aguanta es que el agente investigue y te deje el checkout preparado, y que el
último clic sea tuyo. Cualquier acción que mueva dinero, con confirmación humana explícita.

## Licencia

Este repo son scripts de despliegue. OpenClaw es un proyecto aparte con su propia licencia;
consúltala en [openclaw/openclaw](https://github.com/openclaw/openclaw).
