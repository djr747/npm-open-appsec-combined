# npm-open-appsec-combined

Builds a single-container NGINX Proxy Manager image with:

- the open-appsec NGINX attachment module
- the open-appsec agent runtime in the same container

This removes the cross-container IPC/shared-memory requirement for NPM + open-appsec deployments.

## What this repo provides

- Multi-stage `Dockerfile` based on `jc21/nginx-proxy-manager:${NPM_TAG}`
- Attachment build from `openappsec/attachment` git ref (default: `main`)
- open-appsec agent installer packages baked into the same image
- s6 service wiring so open-appsec agent starts before nginx
- Upstream NPM `PUID`/`PGID` process model preserved
- Persistent mount points:
  - `/ext/appsec`
  - `/etc/cp/conf`
  - `/etc/cp/data`
  - `/var/log/nano_agent`

## Security patching strategy

### What is patched on each build

- **Debian packages** — every build runs `apt-get -y upgrade` inside the final image to apply
  all Debian 12 (bookworm) security patches available at build time.
- **Go stdlib (cert-prune)** — the `cert-prune` utility is compiled with `golang:1.26`, which
  tracks the latest Go 1.26 patch releases. This keeps the binary above the fix thresholds
  for Go stdlib CVEs such as CVE-2026-27143 (requires ≥ 1.25.9 / 1.26.2).
- **Nightly rebuilds** — a scheduled workflow rebuilds the image every night so that security
  patches released by Debian or the Go team are automatically incorporated without manual
  intervention.

### When a build is blocked from publishing

The Grype CVE scanner runs against every built image. Publishing is **blocked only** when
Grype finds a vulnerability that satisfies **both** conditions:

1. **Fixable** — a remediated package version is already available in the vulnerability database.
2. **Critical** — rated Critical by NVD / GHSA.

High, medium, and low findings, and any un-fixable Critical finding, are surfaced in GitHub
Code Scanning but do **not** prevent the image from being published.

## Cloud-managed open-appsec configuration

For cloud-managed policy (primary use case), set these environment variables on the **same** `npm-open-appsec` container:

### Required

- `AGENT_TOKEN`
  - Profile/API token from the open-appsec Web UI/SaaS portal
- `user_email`
  - Deployment operator email

`registered_server=NGINX` and `nginxproxymanager=true` are baked into this combined image as
defaults, so you do not need to set them in compose unless you explicitly want to override them.

### Common optional variables

- `autoPolicyLoad` (default in example: `true`)
- `https_proxy`

## Local policy mode (still supported)

Local policy mode is also supported in the same single-container setup.

- Leave `AGENT_TOKEN` unset (no cloud profile connection)
- Keep `autoPolicyLoad=true`
- Place `local_policy.yaml` under the mounted `/ext/appsec` path (host-side example:
  `/opt/openappsec/localconfig/local_policy.yaml`)

Download a starter policy file:

```bash
mkdir -p /opt/npm/data \
         /opt/npm/letsencrypt \
         /opt/openappsec/localconfig \
         /opt/openappsec/conf \
         /opt/openappsec/data \
         /opt/openappsec/logs
curl -fsSL https://raw.githubusercontent.com/openappsec/open-appsec-npm/main/deployment/local_policy.yaml \
     -o /opt/openappsec/localconfig/local_policy.yaml
```

See `examples/docker-compose.local-policy.yml` for a ready-to-use deployment.

## No IPC requirement between containers

Because the agent and attachment run in the same container, this setup does not require:

- `ipc: host`
- `ipc: shareable`
- `ipc: service:*`
- cross-container `/dev/shm` volume sharing

## PUID / PGID support

The image keeps upstream NPM startup behavior:

- initialization runs as root
- NPM services run as configured `PUID` / `PGID`

The open-appsec paths added by this image are included in the ownership preparation so bind-mounted directories follow the same uid/gid model as other NPM data paths.

## Advanced ML model (optional)

The startup script automatically handles the advanced ML model if the file is present at the
expected host path.

Download the `open-appsec-advanced-model.tgz` from the
[open-appsec releases](https://github.com/openappsec/openappsec/releases) and place it at the
host-side path:

```yaml
volumes:
  # ... other mounts ...
  - /opt/openappsec/open-appsec-advanced-model.tgz:/advanced-model/open-appsec-advanced-model.tgz
```

The script extracts the archive into `/etc/cp/conf/waap` on each container start if the file is
present. The cloud-managed example mounts it by default; the local-policy example leaves it
commented out unless you want to use it there too.

## Local ML tuning setup (advanced, optional)

The NPMplus compose includes extra containers for an unsupervised ML suggestion loop
(`smartsync`, `shared-storage`, `tuning-svc`, `openappsec-db`). These are **not needed** for
this setup:

- **With `AGENT_TOKEN` set**: the open-appsec SaaS cloud backend handles all learning and
  tuning — no extra containers needed.
- **Without `AGENT_TOKEN` (local-policy mode)**: a static `local_policy.yaml` with
  `autoPolicyLoad=true` gives full WAF enforcement — no extra containers needed.

The smartsync/tuning setup is only relevant if you want unsupervised ML-based policy suggestions
running entirely on-premises without a cloud backend. See the NPMplus documentation for that
optional advanced configuration.

## CrowdSec integration

CrowdSec adds a second, independent rule-based inspection layer on top of open-appsec. In this
repo the streamlined integration uses CrowdSec AppSec directly over its built-in HTTP endpoint, so
the deployment stays to a single additional CrowdSec sidecar.

### Architecture (no Lua module required)

The `jc21/nginx-proxy-manager` base image does not include a Lua/OpenResty nginx build, so the
official `crowdsec-nginx-bouncer` (Lua-based) is not a good fit. The CrowdSec Local API also does
not return simple allow/deny status codes that nginx `auth_request` can consume directly.

This repo therefore uses CrowdSec AppSec's built-in HTTP inspection endpoint on port `7422` and
generates nginx `auth_request` config automatically from container environment variables:

1. **CrowdSec agent** — runs AppSec and exposes its inspection endpoint on `7422`.
2. **Auto-generated nginx includes** — the startup script writes `http_top.conf`,
   `server_proxy.conf`, and `server_redirect.conf` under `/data/nginx/custom/` on first start, so
   all proxy hosts are protected automatically with no file copies and no NPM UI edits.

### Quick start

```bash
# Pull the pre-built image
docker pull ghcr.io/djr747/npm-open-appsec-combined:latest

# Create the deployment root and the component directories the compose file expects
CONTROL_DIR=/home/containeruser/npm-open-appsec
mkdir -p "${CONTROL_DIR}"
mkdir -p /opt/npm/data \
         /opt/npm/letsencrypt \
         /opt/openappsec/localconfig \
         /opt/openappsec/conf \
         /opt/openappsec/data \
         /opt/openappsec/logs \
         /opt/crowdsec/data \
         /opt/crowdsec/acquis.d
cd "${CONTROL_DIR}"

curl -fsSL https://raw.githubusercontent.com/djr747/npm-open-appsec-combined/main/examples/docker-compose.cloud-managed.yml \
     -o docker-compose.yml

curl -fsSL https://raw.githubusercontent.com/djr747/npm-open-appsec-combined/main/crowdsec/acquis.d/npm-open-appsec.yaml \
     -o /opt/crowdsec/acquis.d/npm-open-appsec.yaml

# Create a reusable compose env file.
# Generate CROWDSEC_ENROLL_KEY at https://app.crowdsec.net (Security Engines -> Add Security Engine)
cat > .env <<'EOF'
IMAGE_REPOSITORY=ghcr.io/djr747/npm-open-appsec-combined
NPM_IMAGE_TAG=latest
CROWDSEC_ENROLL_KEY=your-crowdsec-enrollment-key
CROWDSEC_ENROLL_INSTANCE_NAME=npm-open-appsec
APPSEC_AGENT_TOKEN=your-open-appsec-token
APPSEC_USER_EMAIL=you@example.com
EOF

# Start the deployment (CrowdSec registration happens automatically when CROWDSEC_ENROLL_KEY is set)
docker compose --env-file .env up -d

# Confirm CrowdSec registration status
docker compose exec crowdsec cscli console status
```

That compose file is fully declarative:

- CrowdSec AppSec acquisition config is provided via a bind-mounted file
  (`/opt/crowdsec/acquis.d/npm-open-appsec.yaml`)
- if you want NPM access-log ingestion later, add an additional acquisition file
  under `/opt/crowdsec/acquis.d`
- `npm-open-appsec` auto-generates the nginx custom includes on first start
- all proxy hosts are protected automatically through NPM's global `server_proxy.conf` and
  `server_redirect.conf` custom include hooks

### Generated nginx config

When `CROWDSEC_ENABLED=true`, the startup script generates these files if they do not already
exist:

- `/data/nginx/custom/http_top.conf`
- `/data/nginx/custom/server_proxy.conf`
- `/data/nginx/custom/server_redirect.conf`

Existing files are never overwritten, so you can switch to fully manual control at any time by
editing the generated files in place.

### Excluding specific hosts from CrowdSec checks

Use the `CROWDSEC_SKIP_HOSTS` env var for the declarative path:

```yaml
environment:
  - CROWDSEC_ENABLED=true
  - CROWDSEC_SKIP_HOSTS=internal.example.com,webhook.example.com
```

On first container start the startup script writes those hosts into the generated
`/data/nginx/custom/http_top.conf` map and the generated auth subrequest returns immediately for
matching hosts.

For the manual path, edit the generated map block directly:

```nginx
map $host $crowdsec_skip {
    default 0;
    "internal.example.com"    1;
    "webhook.example.com"     1;
}
```

### CrowdSec AppSec (optional WAF rules)

The compose examples already enable the required CrowdSec AppSec collections and listener on port
`7422`, and the generated nginx config sends auth subrequests there directly.

Because nginx `auth_request` does not forward the request body, this mode provides header/URL
inspection only. Full request-body inspection would require a Lua-capable nginx build.

### Tradeoff of the no-bouncer design

Removing the extra bouncer sidecar keeps the deployment much simpler, but it also means this
integration is focused on CrowdSec AppSec request inspection rather than inline enforcement of
CrowdSec Local API IP-ban decisions. nginx can call the AppSec endpoint directly because it returns
allow/deny HTTP statuses; the Local API decision endpoints return JSON data, not auth_request-style
status codes.

### open-appsec log ingestion into CrowdSec

This streamlined setup focuses on NPM access-log parsing plus optional CrowdSec AppSec request
inspection. If you later want CrowdSec to ingest open-appsec intrusion logs as well, a template
acquisition config is provided at
[`crowdsec/acquis.d/openappsec-logs.yaml`](crowdsec/acquis.d/openappsec-logs.yaml).

Activate it by uncommenting the `filenames` block in that file and adding the open-appsec log
mount to the CrowdSec container:

```yaml
volumes:
  - /opt/openappsec/logs:/var/log/nano_agent:ro
```

> **Note:** CrowdSec does not ship a built-in open-appsec log parser. A custom parser that
> understands the nano-agent JSON log format is required before CrowdSec can score events from
> those logs. See the [CrowdSec parser documentation](https://docs.crowdsec.io/docs/next/parsers/create)
> for details.

## Automated image workflow

Workflow: `.github/workflows/build-image.yml`

- Nightly build (`schedule`) to pick up base image security updates
- Manual `workflow_dispatch` with optional:
  - `npm_tag`
  - `attachment_ref`
  - `openappsec_ref`
- Published tags:
  - `<npm-release-tag>`
  - `<npm-release-tag>-oas-<attachment-commit-short-sha>`
  - `nightly`
- Build strategy: `amd64` on `ubuntu-latest` (native), `arm64` on `ubuntu-24.04-arm`
  (native). The Dockerfile builds open-appsec installers from
  `openappsec/openappsec` source in a Debian build stage for each target architecture.

## Integration test

The integration test runs as the `integrate` job inside
`.github/workflows/build-image.yml` (after the build phase, before the multi-arch manifest
merge). It is skipped on nightly and push-to-main events, which follow a PR that already ran
the test.

Local run:

```bash
./tests/test-single-container-startup.sh
```

The test auto-detects the local Docker platform (`linux/arm64` on Apple Silicon,
`linux/amd64` on x86_64). Override with `DOCKER_PLATFORM=...` if needed.

The integration test builds the image, starts one container, and verifies:

- open-appsec watchdog process is running
- nginx process is running
- NPM backend process is running
- NPM UI endpoint on port `81` responds (`200`/`301`/`302`)
- nginx workers run as configured `PUID` (non-root)
- `node` (NPM backend) runs as configured `PUID` (non-root)
- `/dev/shm/check-point` is present (intra-container shared memory, no IPC sharing needed)
- Attachment commit file is present
- open-appsec blocks a deterministic local-policy drop path with HTTP 403 (policy loaded via
  `autoPolicyLoad=true`; proxy host configured via the NPM REST API)

The open-appsec smartsync/shared-storage sidecars are not started by default. They are only
needed when explicitly testing standalone learning/tuning behavior, not for static local-policy
loading. To include them in a local run:

```bash
ENABLE_APPSEC_LEARNING_SIDECARS=1 ./tests/test-single-container-startup.sh
```

## Example deployments

Two compose files are provided under `examples/`:

### Cloud-managed (`examples/docker-compose.cloud-managed.yml`)

Connects to the open-appsec SaaS portal for policy management and also includes the complete
single-sidecar CrowdSec AppSec configuration so the example is deployable as-is.
If you want cloud-managed open-appsec without CrowdSec enforcement, set
`CROWDSEC_ENABLED=false`.

The CrowdSec AppSec acquisition config is provided declaratively via
`crowdsec/acquis.d/npm-open-appsec.yaml`, which is bind-mounted read-only into the
CrowdSec container — no shell scripts or runtime file writes are needed. If you want
NPM access-log ingestion as well, add a separate acquisition file under `crowdsec/acquis.d`.

Set at least:

- `APPSEC_AGENT_TOKEN`
- `APPSEC_USER_EMAIL`

Optional and recommended:

- `PUID`
- `PGID`
- `CROWDSEC_ENROLL_KEY` (optional, to register this CrowdSec instance in CrowdSec Console)
- `CROWDSEC_ENROLL_INSTANCE_NAME` (optional display name in CrowdSec Console)

If you want CrowdSec account registration, generate an enrollment token in CrowdSec Console and set:

```bash
export CROWDSEC_ENROLL_KEY="<your-crowdsec-enrollment-key>"
export CROWDSEC_ENROLL_INSTANCE_NAME="npm-open-appsec-prod"
```

### Locally managed (`examples/docker-compose.local-policy.yml`)

Runs fully offline using a local `local_policy.yaml` — no cloud token needed.

Before starting:

```bash
mkdir -p /opt/npm/data \
         /opt/npm/letsencrypt \
         /opt/openappsec/localconfig \
         /opt/openappsec/conf \
         /opt/openappsec/data \
         /opt/openappsec/logs
curl -fsSL https://raw.githubusercontent.com/openappsec/open-appsec-npm/main/deployment/local_policy.yaml \
     -o /opt/openappsec/localconfig/local_policy.yaml
```

### VM bootstrap scripts

Two end-to-end bootstrap scripts live in `examples/`. They are for fresh VMs where you want the
script to install the rootless container runtime, create `containeruser`, download the needed
files, and start the deployment as a user service.

The `curl` commands below use GitHub's `main` branch. They will return `404` until the bootstrap
scripts are committed and pushed to that branch. If you are testing from another pushed branch,
replace `main` in the URL with that branch name and run the script with the same `RAW_BASE_URL`,
so it downloads the matching compose files.

Use the table below to choose **one** path:

| VM / goal | Script | What it downloads | Policy mode |
| --- | --- | --- | --- |
| Rocky / RHEL 10 | `examples/rocky-rhel10-cloud-managed-advanced.sh` | cloud-managed compose, CrowdSec acquisition file, advanced model archive | cloud-managed + advanced model |
| Ubuntu 26.04 | `examples/ubuntu-2604-local-docker-rootless.sh` | local-policy compose, starter `local_policy.yaml` | local policy + rootless Docker |

Do not run both scripts on the same VM. They manage the same service-owned runtime directories
under `/opt/npm`, `/opt/openappsec`, and `/opt/crowdsec`.

Both scripts default `IMAGE_REPOSITORY` to `ghcr.io/djr747/npm-open-appsec-combined`, which is
the image published by this repo on GitHub Container Registry. Only override it if you are
pointing at a fork or custom registry.
They also reuse an existing `.env` from `/home/containeruser/npm-open-appsec`, so rerunning after
a failure keeps the prior answers instead of making you start over.
By default their service data lives under `/opt/npm`, `/opt/openappsec`, and `/opt/crowdsec`,
not in the user home directory.

#### Rocky / RHEL 10

Use this path when you want a cloud-managed deployment with the advanced model on a Rocky or RHEL 10 VM.

1. Download the script:

   ```bash
   RAW_BASE_URL=https://raw.githubusercontent.com/djr747/npm-open-appsec-combined/main
   curl -fsSL "${RAW_BASE_URL}/examples/rocky-rhel10-cloud-managed-advanced.sh" \
     -o rocky-rhel10-cloud-managed-advanced.sh
   ```

2. Make it executable and run it:

   ```bash
   chmod +x rocky-rhel10-cloud-managed-advanced.sh
   RAW_BASE_URL="${RAW_BASE_URL}" ./rocky-rhel10-cloud-managed-advanced.sh
   ```

3. Answer the interactive prompts:
   - cloud-managed open-appsec agent token
   - deployment operator email
   - whether CrowdSec should be enrolled
   - advanced model archive URL or a local file path

4. The script then:
    - installs rootless Podman prerequisites
    - installs `podman-compose` into `~/.local/bin` with `pip` if it is not already present
    - falls back to the upstream `podman-compose` source archive if the PyPI install fails
    - creates `containeruser` if it does not exist
    - enables lingering so the user service survives logout
    - configures firewalld to forward 80, 81, and 443 to the rootless NPM ports (8080, 8181, 8443)
    - downloads `docker-compose.cloud-managed.yml`
    - downloads `crowdsec/acquis.d/npm-open-appsec.yaml`
    - if you provide a CrowdSec enrollment key, passes it through so CrowdSec auto-registers on first start
    - waits for the CrowdSec container to reach `running`, then keeps checking that it stays up and prints its logs if startup fails
    - stages the advanced model archive into `/opt/openappsec/open-appsec-advanced-model.tgz`
    - writes a `systemd --user` unit and starts the deployment

5. After it finishes:
   - private compose control files live under `/home/containeruser/npm-open-appsec`
   - service runtime data lives under `/opt/npm`, `/opt/openappsec`, and `/opt/crowdsec`

6. To manage it later, use:

   ```bash
   PUID=$(id -u containeruser)
   sudo -u containeruser XDG_RUNTIME_DIR="/run/user/${PUID}" \
     DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${PUID}/bus" \
     systemctl --user status npm-open-appsec.service
   sudo -u containeruser XDG_RUNTIME_DIR="/run/user/${PUID}" \
     DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${PUID}/bus" \
     systemctl --user restart npm-open-appsec.service
   ```

Run `./rocky-rhel10-cloud-managed-advanced.sh --help` if you want the quick-start commands again.

#### Ubuntu 26.04

Use this path when you want a local-policy deployment with rootless Docker on Ubuntu 26.04.

1. Download the script:

   ```bash
   RAW_BASE_URL=https://raw.githubusercontent.com/djr747/npm-open-appsec-combined/main
   curl -fsSL "${RAW_BASE_URL}/examples/ubuntu-2604-local-docker-rootless.sh" \
     -o ubuntu-2604-local-docker-rootless.sh
   ```

2. Make it executable and run it:

   ```bash
   chmod +x ubuntu-2604-local-docker-rootless.sh
   RAW_BASE_URL="${RAW_BASE_URL}" ./ubuntu-2604-local-docker-rootless.sh
   ```

3. Answer the interactive prompt:
   - none required unless you want to override `IMAGE_REPOSITORY` for a fork or custom registry

4. The script then:
   - installs Docker rootless prerequisites
   - creates `containeruser` if it does not exist
   - enables lingering so the user service survives logout
   - downloads `docker-compose.local-policy.yml`
   - downloads a starter `local_policy.yaml`
   - writes a `systemd --user` unit and starts the deployment

5. After it finishes:
   - private compose control files live under `/home/containeruser/npm-open-appsec`
   - service runtime data lives under `/opt/npm` and `/opt/openappsec`

6. To manage it later, use:

   ```bash
   PUID=$(id -u containeruser)
   sudo -u containeruser XDG_RUNTIME_DIR="/run/user/${PUID}" \
     DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${PUID}/bus" \
     systemctl --user status npm-open-appsec.service
   sudo -u containeruser XDG_RUNTIME_DIR="/run/user/${PUID}" \
     DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${PUID}/bus" \
     systemctl --user restart npm-open-appsec.service
   ```

Run `./ubuntu-2604-local-docker-rootless.sh --help` if you want the quick-start commands again.

### Mount layout

The compose files use the same host-side directory layout to keep the runtime components
separated.

Rocky / RHEL 10 cloud-managed example:

| Host path | Container path | Purpose |
| --- | --- | --- |
| `/opt/npm/data` | `/data` | NPM state (database, proxy configs) |
| `/opt/npm/letsencrypt` | `/etc/letsencrypt` | NPM Let's Encrypt certificates |
| `/opt/npm/data/logs` | `/var/log/npm` | NPM access logs consumed by CrowdSec |
| `/opt/openappsec/localconfig` | `/ext/appsec` | open-appsec policy / config exchange |
| `/opt/openappsec/conf` | `/etc/cp/conf` | open-appsec agent configuration |
| `/opt/openappsec/data` | `/etc/cp/data` | open-appsec agent data / ML model |
| `/opt/openappsec/logs` | `/var/log/nano_agent` | open-appsec agent logs |
| `/opt/crowdsec/data` | `/var/lib/crowdsec/data` | CrowdSec persistent data |
| `/opt/crowdsec/acquis.d` | `/etc/crowdsec/acquis.d` | CrowdSec acquisition files |

Ubuntu 26.04 local-policy example:

| Host path | Container path | Purpose |
| --- | --- | --- |
| `/opt/npm/data` | `/data` | NPM state (database, proxy configs) |
| `/opt/npm/letsencrypt` | `/etc/letsencrypt` | NPM Let's Encrypt certificates |
| `/opt/openappsec/localconfig` | `/ext/appsec` | open-appsec policy / config exchange |
| `/opt/openappsec/conf` | `/etc/cp/conf` | open-appsec agent configuration |
| `/opt/openappsec/data` | `/etc/cp/data` | open-appsec agent data / ML model |
| `/opt/openappsec/logs` | `/var/log/nano_agent` | open-appsec agent logs |
