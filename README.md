# Data Narrator

## City Science Lab

<p align="center">
<img src="https://user-images.githubusercontent.com/36763878/219619895-12db4431-32d9-458b-a73f-548052404258.png" alt="Data Narrator logo" />
</p>

The Data Narrator Platform is a story-driven geospatial application for creating, editing and playing narrative map
experiences. It combines 2D and 3D map views with text, images, GeoJSON, WMS layers, 3D layers and interactive map
states so complex urban data can be communicated step by step.

This repository specifically contains the **Docker-based setup and deployment scaffolding** for the platform. Its role is
to orchestrate the local development stack and wire the separate repositories together so the complete Data Narrator
environment can run consistently.

## Repository roles

| Repository | Role |
|---|---|
| [`cut-dana-platform-addon`](https://github.com/citysciencelab/cut-dana-platform-addon) | Frontend add-on for the Data Narrator UI and story workflow inside Masterportal |
| [`cut-dana-platform-mp`](https://github.com/citysciencelab/cut-dana-platform-mp) | Masterportal-based map client that hosts and integrates the add-on |
| [`cut-dana-platform-backend`](https://github.com/citysciencelab/cut-dana-platform-backend) | Backend service for story persistence, files, API access and application data |
| [`cut-dana-platform-docker`](https://github.com/citysciencelab/cut-dana-platform-docker) | Docker-based local and deployment setup for running the full platform stack |

## Role of this repository

`cut-dana-platform-docker` is the infrastructure and orchestration repository of the platform. It is responsible for
bringing up the connected services, mounting the other repositories into the stack and defining the local environment for
frontend, backend, authentication, storage and database components.

**Warning**: This is just a simple demo setup that is not suited for production use!

---

## Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) installed and running
- Git

### Windows Users — Additional Prerequisites

On Windows, all commands must be run inside **WSL2 with Ubuntu** (not PowerShell, not Git Bash, not the Docker Desktop WSL).

1. Install WSL2 with Ubuntu:
    ```powershell
    wsl --install -d Ubuntu
    ```
2. Restart your machine after installation.
3. In Docker Desktop: **Settings → Resources → WSL Integration** → enable for **Ubuntu** → Apply & Restart.
4. Install required tools inside Ubuntu:
    ```bash
    sudo apt-get update && sudo apt-get install -y pwgen jq openssl iproute2
    ```
5. All subsequent commands in this README must be run from within the Ubuntu WSL shell:
    ```powershell
    wsl -d Ubuntu
    cd "/mnt/c/path/to/cut-dana-platform-docker-main"
    ```

> **Important:** Paths in `.env` must use WSL-style paths (`/mnt/c/Users/...`), not Windows-style paths (`C:\Users\...`).

---

## Repository Structure

This setup expects three separate repositories checked out locally:

```
/path/to/projects/
├── cut-dana-platform-docker/   ← this repo
├── cut-dana-platform-mp/       ← Masterportal frontend
├── cut-dana-platform-addon/    ← Masterportal addon
└── cut-dana-platform-backend/  ← Backend
```

> **Note:** The backend must be a **separate directory** from the Masterportal repo. Docker cannot mount a subdirectory of an already-mounted directory.

Clone the repositories:
```bash
git clone https://github.com/citysciencelab/cut-dana-platform-mp.git
git clone https://github.com/citysciencelab/cut-dana-platform-addon.git
git clone https://github.com/citysciencelab/cut-dana-platform-backend.git
```

---

## Prerequisites for Development

### 1. Install Node dependencies

> **Windows users:** Do **not** run `npm install` on Windows or in a Windows directory from WSL. The installed binaries will be platform-specific and will not work inside the Linux Docker container. Instead, install dependencies inside the container after starting it (see below).

On Linux/Mac, run these before starting Docker:
```bash
# Backend
cd cut-dana-platform-backend
bun install

# Masterportal
cd cut-dana-platform-mp
npm install

# Addon
cd cut-dana-platform-addon
npm run noLegacyInstall
```

### 2. Run `initDev.sh` to initialize the environment

```bash
./initDev.sh \
  --data-narrator-backend-dir=../cut-dana-platform-backend \
  --data-narrator-mp-dir=../cut-dana-platform-mp \
  --data-narrator-mp-addon-dir=../cut-dana-platform-addon
```

This script will:
- Create a `.env` file with all necessary configuration and generated secrets
- Set up Garage (S3-compatible storage) including bucket and access keys
- Initialize Keycloak
- Run database migrations

> If you want to re-initialize the setup, clean up first:
> ```bash
> docker compose down --remove-orphans
> docker volume rm cut-dana-platform_postgres_data cut-dana-platform_postgres_keycloak_data
> rm -rf postgres/data postgres-keycloak/data .env garage/garage.toml
> ```

### 3. Add hosts entries

Add the following lines to your hosts file:

**Linux/Mac** — `/etc/hosts`:
```
127.0.0.1  auth.cut-dana-platform.local
127.0.0.1  app.cut-dana-platform.local
127.0.0.1  minio.cut-dana-platform.local
```

**Windows** — `C:\Windows\System32\drivers\etc\hosts` (open Notepad as Administrator):
```
127.0.0.1  auth.cut-dana-platform.local
127.0.0.1  app.cut-dana-platform.local
127.0.0.1  minio.cut-dana-platform.local
```

### 4. Start the setup

```bash
docker compose -f docker-compose.yml -f docker-compose.override.dev.yml up -d
```

> During the first run, an SSL certificate for your local development environment is created and saved in `nginx/certs/`.

### 5. Install Masterportal dependencies inside the container (Windows only)

On Windows, `npm install` must be run inside the Linux container to get the correct platform binaries:

```bash
# Remove any Windows-installed node_modules first
rm -rf /path/to/cut-dana-platform-mp/node_modules

# Install inside the container (includes required native build dependencies)
docker compose -f docker-compose.yml -f docker-compose.override.dev.yml run --rm --entrypoint="" masterportal \
  sh -c "apk add --no-cache python3 make g++ pkgconfig cairo-dev pango-dev libjpeg-turbo-dev giflib-dev && npm install"

# Restart masterportal
docker compose -f docker-compose.yml -f docker-compose.override.dev.yml restart masterportal
```

### 6. Install Backend dependencies and generate Prisma client (Windows only)

On Windows, `bun install` and `prisma generate` must also be run inside the container:

```bash
# Remove any Windows-installed node_modules first
rm -rf /path/to/cut-dana-platform-backend/node_modules

# Install inside the container
docker exec cut-dana-platform-backend sh -c "bun install --ignore-scripts"

# Generate Prisma client (note: must be run WITHOUT -it flag, otherwise it hangs)
docker exec cut-dana-platform-backend sh -c "node_modules/.bin/prisma generate"

# Run database migrations
docker exec cut-dana-platform-backend sh -c "bun run reset-db --skip-generate --force"

# Restart backend
docker compose -f docker-compose.yml -f docker-compose.override.dev.yml restart backend
```

> **Important:** `prisma generate` will hang indefinitely if run with the `-it` flag (interactive TTY). Always use `docker exec` without `-it` for this command.

> **Note:** The `schema.prisma` file must include `debian-openssl-3.0.x` in `binaryTargets`:
> ```prisma
> generator client {
>   provider      = "prisma-client-js"
>   binaryTargets = ["native", "debian-openssl-1.1.x", "debian-openssl-3.0.x"]
> }
> ```

---

## Accessing the Services

| Service | URL |
|---|---|
| Masterportal (Frontend) | https://app.cut-dana-platform.local |
| Keycloak (Auth) | https://auth.cut-dana-platform.local/auth/ |
| MinIO/Garage (S3) | https://minio.cut-dana-platform.local |

---

## Add and Trust the Root Certificate

The `mkcert` container automatically creates a certificate and a root certificate in `./nginx/certs/`.

To avoid SSL errors in your browser, trust the root certificate:

**Linux/Mac (Debian/Ubuntu):**
```bash
sudo cp ./nginx/certs/rootCA.pem /usr/local/share/ca-certificates/rootCA.crt
sudo update-ca-certificates
```

**Windows:** Double-click `nginx/certs/rootCA.pem` → Install Certificate → Local Machine → "Trusted Root Certification Authorities".

To remove the certificate later:
```bash
sudo rm /usr/local/share/ca-certificates/rootCA.crt
sudo update-ca-certificates --fresh
```

---

## Known Issues & Fixes

### PostgreSQL 18 volume mount path

`postgres:18` changed the expected mount path. The `docker-compose.yml` must mount to `/var/lib/postgresql` (not `/var/lib/postgresql/data`), otherwise the container will fail to start. Additionally, on Windows, bind mounts from WSL cause permission errors — use named Docker volumes instead:

```yaml
# db and keycloak-db services:
volumes:
  - postgres_data:/var/lib/postgresql        # db
  - postgres_keycloak_data:/var/lib/postgresql  # keycloak-db

# Add to top-level volumes section:
volumes:
  postgres_data:
  postgres_keycloak_data:
```

### `prisma generate` hangs with `-it` flag

When running `prisma generate` inside a Docker container on Windows/WSL, it will hang indefinitely if the `-it` (interactive TTY) flag is used. Always run it without `-it`:

```bash
# Wrong — hangs forever:
docker exec -it cut-dana-platform-backend sh -c "bunx prisma generate"

# Correct — works:
docker exec cut-dana-platform-backend sh -c "node_modules/.bin/prisma generate"
```

### Prisma `binaryTargets` missing `debian-openssl-3.0.x`

If you see `Prisma Client could not locate the Query Engine for runtime "debian-openssl-3.0.x"`, update `prisma/schema.prisma` in the backend repo:

```prisma
generator client {
  provider      = "prisma-client-js"
  binaryTargets = ["native", "debian-openssl-1.1.x", "debian-openssl-3.0.x"]
}
```

Then re-run `prisma generate` as described in step 6 above.

### Database tables missing after first start

If the backend returns `The table 'public.Story' does not exist`, the database migrations have not been run. Execute:

```bash
docker exec cut-dana-platform-backend sh -c "bun run reset-db --skip-generate --force"
```

If you see `@esbuild/win32-x64 present but linux-x64 needed`, your `node_modules` were installed on Windows. Delete `node_modules` and reinstall inside the container as described in step 5 above.

### `COMPOSE_FILE` separator on Windows

The `.env.example` uses `:` as separator for `COMPOSE_FILE` which only works on Linux. On Windows (even in WSL when Docker Desktop interprets it), use the explicit `-f` flags instead:
```bash
docker compose -f docker-compose.yml -f docker-compose.override.dev.yml up -d
```

---

## Test User Credentials

The following test user is pre-configured in the Keycloak realm import:

| Field | Value |
|---|---|
| Username | `dev` |
| Password | `dev` |
| Email | `dev@example.org` |

---

## Initial Database Setup

After the first start, the `KeycloakSetup` table must be populated. If `initDev.sh` did not complete fully, run this manually:

```bash
docker exec cut-dana-platform-db psql -U ${DATABASE_USER} -d ${DATABASE_DB} -c "
INSERT INTO \"KeycloakSetup\" (\"authUri\", \"tokenUri\", \"clientId\", \"scope\", \"redirectUri\") VALUES (
  'https://auth.cut-dana-platform.local/auth/realms/masterportal/protocol/openid-connect/auth',
  'https://auth.cut-dana-platform.local/auth/realms/masterportal/protocol/openid-connect/token',
  'masterportal-client',
  'profile email openid',
  'https://app.cut-dana-platform.local/portal/stories'
);"
```

---

## Keycloak

To export the current configuration of the `masterportal` realm:

```bash
docker compose exec keycloak /opt/keycloak/bin/kc.sh export --realm masterportal --file /tmp/keycloak_export.json
docker compose cp keycloak:/tmp/keycloak_export.json ./keycloak/init_data/keycloak_export.json
```
