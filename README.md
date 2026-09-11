# openclaw-agent

An AI assistant with shell, filesystem and browser access that you talk to over Telegram from
your phone. It runs in an isolated Docker container on your own machine.

This repo is **not** the agent: it's the deployment and hardening layer around
[OpenClaw](https://github.com/openclaw/openclaw). What it adds:

- **A runbook in a `Makefile`.** Bootstrap from scratch in six commands, no interactive prompts.
- **State outside the container.** Config, SQLite and workspace live in this directory; the
  container is disposable and gets replaced on every image update without losing anything.
- **Network hardening.** Upstream's compose publishes the Control UI on `0.0.0.0`; here it's
  rewritten to listen on loopback only.
- **The bot locked to a single owner.** `make lockdown` pins the Telegram allowlist to your user
  id and makes you the explicit operator for privileged commands.
- **A verifier.** `make verify` fails if the configuration has drifted into an open state.
- **Secret handling.** `secrets.env` stays out of git, synced into the `.env` Compose reads by a
  script that survives `setup.sh` rewriting that file.

Everything learned the hard way while getting this running is written down in
[Things that bite](#things-that-bite): model quotas, the heartbeat that eats the free tier,
session collisions between the CLI and Telegram.

## Why Docker

The agent runs shell commands, reads and writes files, and browses. In Docker the blast radius
is bounded by the container: if something goes sideways, it doesn't take your `$HOME` with it.
Upstream's image already runs as the `node` user (uid 1000), not root, with `no-new-privileges`
and without `NET_RAW`/`NET_ADMIN`.

## Requirements

- Docker with Compose v2 ≥ 2.24 (the hardening file's `!override` tag needs that version)
- `make`, `bash`, `curl`, `git`
- A Telegram bot created via [@BotFather](https://t.me/BotFather) (`/newbot`)
- An LLM provider API key: Anthropic, OpenAI or Google AI Studio
- ~4 GB of disk for the `latest-browser` image (it ships Chromium)

## Layout

```
openclaw-agent/
├── repo/                          clone of openclaw/openclaw (holds the docker-compose.yml)
├── state/                         -> /home/node/.openclaw   config + SQLite + the gateway's .env
├── workspace/                     -> the agent's workspace
├── auth-secrets/                  -> recovery key for inherited OAuth credentials
├── config.env                     non-sensitive tunables
├── secrets.env                    API keys and bot token (gitignored)
├── docker-compose.hardening.yml   publishes ports on loopback only
├── Makefile                       runbook
└── bin/                           sync-secrets.sh, verify.sh
```

`repo/`, `state/`, `workspace/` and `auth-secrets/` are gitignored: the first because it's a
clone of upstream, the other three because they're local state. After cloning this repo you'll
need to fetch `repo/` yourself and let the bootstrap create the rest.

`state/` is sensitive material. OAuth tokens are stored in cleartext in the SQLite database, so
treat that directory and any backups of it as credentials.

## Bootstrap

```bash
git clone https://github.com/openclaw/openclaw.git repo
cp secrets.env.example secrets.env     # fill in the API key and the @BotFather token
make setup                             # .env, permissions, start
make onboard                           # register the LLM provider, no prompts
make telegram-pairing                  # connect the bot in pairing mode
# message the bot: its reply contains your numeric user id
make lockdown ID=<your-user-id>        # lock the bot down to your account
make verify
```

`make setup` doesn't build the image: it uses the official prebuilt `latest-browser`, which
already ships Chromium. Building from source would ask 6 GB of RAM from the builder and buys
nothing here.

Optional, so the agent can search the web: `make websearch`. It installs the `parallel-free`
plugin, which needs no API key and returns dense extracts meant for LLM context. The other
key-free option is `duckduckgo`, but upstream flags it as experimental because it scrapes HTML
without JS and breaks against anti-bot challenges. For country/language filters and better
reliability, use Brave: put `BRAVE_API_KEY` in `secrets.env` and set `provider=brave`.

## The security model, briefly

A Telegram bot is reachable by anyone who knows its username. The bot has shell access inside
the container. So the only acceptable configuration for a single-owner bot is
`dmPolicy: allowlist` with your numeric user id explicitly listed in `allowFrom`.

- `pairing` (upstream's default) is a transit state for discovering your user id.
- `open` with `allowFrom: ["*"]` is a public bot. Don't use it here.
- `make lockdown` also pins `commands.ownerAllowFrom` to `telegram:<your-id>`, which is what
  grants an explicit operator for privileged commands and execution approvals.
- `make verify` fails if it finds `open`, a wildcard in `allowFrom`, or a port published outside
  loopback.

Beyond that: content the agent reads from the web or from email is untrusted. If a page contains
text that looks like instructions, treat it as a prompt injection attempt. The more narrowly
scoped the credentials you hand it, the less it matters.

## Day to day

| What | Command |
| --- | --- |
| Start / stop | `make up` / `make down` |
| Recreate, applying environment changes | `make restart` |
| Logs | `make logs` |
| Health probes | `make health` |
| Control UI URL | `make dashboard` |
| Deployment preflight | `make doctor` |
| A single CLI command | `make cli CMD='channels list'` |
| Read config | `make config-get P=channels.telegram` |
| Update the image | `make update` |

The Control UI lands on `http://127.0.0.1:18789/`. Its token is in `repo/.env` as
`OPENCLAW_GATEWAY_TOKEN`. `config get` redacts it, so read it from the file.

`docker compose restart` does not apply environment changes; that's why `make restart` runs
`up -d --force-recreate`.

## Things that bite

**`setup.sh` rewrites `repo/.env` from the shell environment** on every run. Don't hand-edit
`repo/.env` and expect it to survive: tunables go in `config.env`, secrets in `secrets.env`. The
script preserves lines whose keys it doesn't manage, and `bin/sync-secrets.sh` exploits exactly
that to inject the provider and channel keys.

**`docker-compose.override.yml` is not auto-loaded.** `setup.sh` invokes Compose with explicit
`-f` flags, which disables automatic override discovery. Hence the hardening living in
`docker-compose.hardening.yml` and the Makefile always passing the full file list. If you add
Compose files, keep the same order in every command or the mounts shift under you.

**Host-local services are not on `127.0.0.1`.** Inside the container that address is the
container itself. For Ollama or LM Studio running on the Mac, use
`http://host.docker.internal:11434` and `:1234`; the compose file already maps the alias.

**Updates.** Rolling tags (`latest*`) are rebuilt weekly with OS patches. Startup applies
upgrade migrations on its own. If the container ends up in a restart loop after an image change,
run `make doctor` against the same mounted state.

**Picking a model on Gemini has four traps.** `models list` mixes the plugin's local catalog
with what the provider advertises live, and not everything listed is actually callable. Verified
by hitting the API directly:

| Symptom | Cause | What to do |
| --- | --- | --- |
| 429 `RESOURCE_EXHAUSTED` | `gemini-3.1-pro-preview`, the one onboarding picks, isn't in the free tier | use a `flash` |
| `Unknown model` on call | the model appears in `models list` but isn't in the plugin catalog (e.g. `gemini-3.8-flash`); `models set` accepts it with a warning you should take seriously | pick one from the catalog |
| 404 `no longer available to new users` | `gemini-2.5-flash` and `2.5-flash-lite` are retired for new accounts | Google recommends `gemini-3.6-flash` |
| 503 `UNAVAILABLE`, high demand | `gemini-3.6-flash` and `3.7-flash` saturate intermittently | transient, but don't make it your primary |

Current setup: primary `google/gemini-3.5-flash`, the one that responds reliably, with
`3.6-flash` and `3.7-flash` as fallbacks.

**Known limitation of that fallback chain:** all three models are Gemini. It covers a 503 on one
specific model, but not a 429 quota error, which is project-wide and takes all three down at
once. The real fix is a fallback from another provider: its key in `secrets.env` plus
`make cli CMD='models fallbacks add <provider>/<model>'`.

**Diagnosing model failures.** To separate whether the problem is the model, the quota or
OpenClaw, hit the API raw. Use the `v1` endpoint, not `v1beta`: in testing `v1beta` returned 404
with an empty body while `v1` gave the real error JSON. And send requests one at a time, because
in bursts it also returns empty bodies.

```bash
curl -sS -X POST \
  "https://generativelanguage.googleapis.com/v1/models/<model>:generateContent" \
  -H "x-goog-api-key: $GEMINI_API_KEY" -H 'Content-Type: application/json' \
  -d '{"contents":[{"parts":[{"text":"hello"}]}]}'
```

**The heartbeat eats your free quota.** OpenClaw creates three automations out of the box, and
one of them, `Heartbeat (main)`, fires an agent turn **every 30 minutes** by default. That's 48
turns a day nobody asked for, against your provider's free tier. It's the prime suspect when a
429 shows up without you doing anything.

Here it's disabled with `agents.defaults.heartbeat.every = 0m`. That only turns off the
recurring cadence; event-driven wakeups still work. To re-enable:

```bash
make cli CMD='config set agents.defaults.heartbeat.every 30m'
```

The other two automations are far more benign: `Memory Dreaming Promotion` (daily at 03:00, in
an isolated session) and `Skill collection review` (weekly). Inspect them with
`make cli CMD='cron list'`.

**Sessions are shared between the CLI and Telegram.** `agent:main:main` accumulates both `cli`
and `telegram:<your-id>` as participants. If you test via the CLI while the bot is handling a
message from you, they collide and you get `SESSION_WORK_START_CHANGED`. Worse: if you kill a
CLI process midway, the session stays `status: running` and blocks Telegram messages too.

- To diagnose without disturbing the bot, use a separate session:
  `make cli CMD='agent --session-key agent:main:diag --message "..."'`
- To inspect state: `make cli CMD='sessions list --json'`
- To release a stale claim, `make restart` clears it. No need to delete the session.

Inbound channel messages do retry on that error by themselves
(`src/channels/message/ingress-retry-policy.ts`), so an occasional collision won't lose the
message.

**Testing the outbound path without touching your phone.** `message send` injects a message
through the channel without going through the agent, useful for separating "the bot isn't
reaching my phone" from "the model is failing":

```bash
make cli CMD='message send --channel telegram --target <your-id> --message "test"'
```

## On automating purchases (cinema tickets, etc.)

The "message it on Telegram and have it research" part is solid. The "have it buy" part isn't,
and not because of the agent: ticketing sites sit behind anti-bot defenses, seat maps are canvas
with no semantic DOM, and SCA payment asks for an OTP the agent cannot and should not resolve.

The design that holds up is the agent researching and leaving the checkout ready, with the final
click yours. Anything that moves money gets explicit human confirmation.

## License

This repo is deployment tooling. OpenClaw is a separate project with its own license; see
[openclaw/openclaw](https://github.com/openclaw/openclaw).
