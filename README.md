# mythic-framework-docker

[![Docker Hub](https://img.shields.io/docker/pulls/phille06/mythic-framework-docker?logo=docker)](https://hub.docker.com/r/phille06/mythic-framework-docker)
[![Build & Push](https://github.com/Phille06/mythic-framework-docker/actions/workflows/docker-publish.yml/badge.svg)](https://github.com/Phille06/mythic-framework-docker/actions/workflows/docker-publish.yml)

Fully automated, headless FiveM server stack with the [Mythic Framework](https://github.com/Mythic-Framework/txAdminRecipe), txAdmin, MariaDB and MongoDB — packaged as a single Docker Hub image.

---

## Credits

The FiveM Docker image is based on the excellent work of **ich777** (admin@minenet.at):
- Original: https://github.com/ich777/docker-fivem-server
- Original base image: https://github.com/ich777/docker-debian-baseimage

Forked and extended by **Phille06**:
- https://github.com/Phille06/mythic-framework-docker
- https://hub.docker.com/r/phille06/mythic-framework-docker

---

## Quick Start (Docker Hub image — no build needed)

### 1. Get the files

Download or copy `docker-compose.yml` and `.env.example` from this repo — that's all you need on your server. No Dockerfile required.

### 2. Configure

```bash
cp .env.example .env
nano .env
```

Minimum required values:

| Variable | Description |
|---|---|
| `SERVER_LICENSE_KEY` | Cfx.re key from [keymaster.fivem.net](https://keymaster.fivem.net) |
| `MYSQL_ROOT_PASSWORD` | Strong password |
| `MYSQL_PASSWORD` | Strong password |
| `MONGO_INITDB_ROOT_PASSWORD` | Strong password |
| `TXADMIN_MASTER_PASSWORD` | Password to log in to txAdmin |

### 3. Start

```bash
docker compose up -d
```

Docker pulls `phille06/mythic-framework-docker:latest` from Hub automatically.

**First boot takes 5–15 minutes** — the container deploys 80+ Mythic resources from GitHub.

### 4. Access

| Service | URL |
|---|---|
| txAdmin web panel | `http://your-server-ip:40120` |
| FiveM game port | `your-server-ip:30120` |

Log in to txAdmin with `TXADMIN_MASTER_USERNAME` / `TXADMIN_MASTER_PASSWORD` from your `.env`.

---

## What happens on first boot

1. MariaDB and MongoDB start and pass healthchecks (~30–40 s)
2. `mythic-entrypoint.sh` fetches the Mythic txAdmin recipe YAML
3. All 80+ resources are downloaded via GitHub archives into `./data/serverfiles/resources/`
4. `server.cfg` is written with injected DB connection strings
5. txAdmin profile is pre-configured — browser wizard is never shown
6. ich777's `start.sh` runs, downloads the latest FXServer artifact, starts FXServer

On every subsequent boot, only step 6 runs (steps 1–5 are skipped via lock file).

---

## Directory Layout

All data lives next to your `docker-compose.yml`:

```
your-project/
├── docker-compose.yml     ← only file you need (pulls from Hub)
├── .env                   ← your secrets (never commit this)
├── .env.example
└── data/
    ├── mariadb/           ← MariaDB databases
    ├── mongodb/           ← MongoDB databases
    ├── serverfiles/       ← FXServer artifact, resources/, server.cfg
    └── txData/            ← txAdmin profiles, bans, logs, whitelist
```

---

## Updating the server

**FXServer artifact** — auto-updated on every container restart (unless `MANUAL_UPDATES=true`):
```bash
docker compose restart fivem
```

**This Docker image** — pull the latest build from Hub:
```bash
docker compose pull fivem
docker compose up -d fivem
```

---

## Re-running the Mythic recipe

```bash
rm ./data/serverfiles/.mythic_deploy_complete
docker compose restart fivem
```

> Back up `./data/serverfiles/resources/` first — re-deploy overwrites resources.

---

## Common commands

```bash
docker compose logs -f fivem          # live FiveM logs
docker compose logs -f                # all services
docker compose restart fivem          # restart + FXServer update check
docker compose pull && docker compose up -d   # update image from Hub
docker compose down                   # stop (data safe in ./data/)
```

---

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `SERVER_LICENSE_KEY` | — | **Required.** Cfx.re license key |
| `SERVER_NAME` | `My Mythic Server` | Server browser display name |
| `FIVEM_PORT` | `30120` | Game port (TCP + UDP) |
| `TXADMIN_PORT` | `40120` | txAdmin web panel port |
| `TXADMIN_MASTER_USERNAME` | `admin` | txAdmin login username |
| `TXADMIN_MASTER_PASSWORD` | — | **Required.** txAdmin login password |
| `MYSQL_*` | — | MariaDB credentials |
| `MONGO_*` | — | MongoDB credentials |
| `RECIPE_URL` | Mythic stable | txAdmin recipe YAML URL |
| `MANUAL_UPDATES` | *(blank)* | Set `true` to skip auto FXServer update |
| `PUID` / `PGID` | `99` / `100` | Container user/group IDs |

---

## Publishing a new release

Push a git tag to trigger a versioned Docker Hub build:

```bash
git tag v1.0.0
git push origin v1.0.0
```

GitHub Actions builds and pushes `phille06/mythic-framework-docker:v1.0.0` and `:latest`.

---

## Security

- Never commit `.env` — it is in `.gitignore`
- All data persists in `./data/` even after `docker compose down`
- Place txAdmin port (40120) behind a TLS reverse proxy for internet-facing servers
