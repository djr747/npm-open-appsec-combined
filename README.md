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
- Place `local_policy.yaml` under the mounted `/ext/appsec` path (host-side: `./appsec/localconfig/local_policy.yaml`)

Download a starter policy file:

```bash
mkdir -p ./appsec/localconfig
curl -fsSL https://raw.githubusercontent.com/openappsec/open-appsec-npm/main/deployment/local_policy.yaml \
     -o ./appsec/localconfig/local_policy.yaml
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
expected container path.

Download the `open-appsec-advanced-model.tgz` from the
[open-appsec releases](https://github.com/openappsec/openappsec/releases) and place it at the
host-side path, then mount it into the container:

```yaml
volumes:
  # ... other mounts ...
  - ./appsec/open-appsec-advanced-model.tgz:/advanced-model/open-appsec-advanced-model.tgz
```

The script extracts the archive into `/etc/cp/conf/waap` on each container start if the file is
present. Both compose examples have this mount commented out — uncomment to activate.

## Local ML tuning stack (advanced, optional)

The NPMplus compose includes extra containers for an unsupervised ML suggestion loop
(`smartsync`, `shared-storage`, `tuning-svc`, `openappsec-db`). These are **not needed** for
this setup:

- **With `AGENT_TOKEN` set**: the open-appsec SaaS cloud backend handles all learning and
  tuning — no extra containers needed.
- **Without `AGENT_TOKEN` (local-policy mode)**: a static `local_policy.yaml` with
  `autoPolicyLoad=true` gives full WAF enforcement — no extra containers needed.

The smartsync/tuning stack is only relevant if you want unsupervised ML-based policy suggestions
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
# Start the cloud-managed open-appsec stack with CrowdSec sidecar
docker compose -f examples/docker-compose.cloud-managed.yml up -d
```

That compose file is fully declarative:

- CrowdSec acquisition config is provided via a bind-mounted file
  (`crowdsec/acquis.d/npm-open-appsec.yaml`)
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
inspection. If you later want CrowdSec to ingest open-appsec intrusion logs as well, add another
acquisition entry under `/etc/crowdsec/acquis.d/` and mount `/var/log/nano_agent` into the
CrowdSec container read-only.

## Automated image workflow

Workflow: `.github/workflows/build-image.yml`

- Nightly build (`schedule`) to pick up base image security updates
- Manual `workflow_dispatch` with optional:
  - `npm_tag`
  - `attachment_ref`
- Published tags:
  - `<npm-release-tag>`
  - `<npm-release-tag>-oas-<attachment-commit-short-sha>`
  - `nightly`
- Build strategy: `amd64` on `ubuntu-latest` (native). The current image copies
  `/nano-service-installers` from `ghcr.io/openappsec/agent`, which is amd64-only.

## Integration test

Workflow: `.github/workflows/integration-test.yml`

Local run:

```bash
./scripts/test-single-container-startup.sh
```

The integration test builds the image, starts one container, and verifies:

- open-appsec watchdog process is running
- nginx process is running
- NPM backend process is running
- NPM UI endpoint on port `81` responds (`200`/`301`/`302`)

## Example deployments

Two compose files are provided under `examples/`:

### Cloud-managed (`examples/docker-compose.cloud-managed.yml`)

Connects to the open-appsec SaaS portal for policy management and also includes the complete
single-sidecar CrowdSec AppSec configuration so the example is deployable as-is.
If you want cloud-managed open-appsec without CrowdSec enforcement, set
`CROWDSEC_ENABLED=false`.

The CrowdSec acquisition config is provided declaratively via
`crowdsec/acquis.d/npm-open-appsec.yaml`, which is bind-mounted read-only into the
CrowdSec container — no shell scripts or runtime file writes are needed.

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
mkdir -p ./appsec/localconfig
curl -fsSL https://raw.githubusercontent.com/openappsec/open-appsec-npm/main/deployment/local_policy.yaml \
     -o ./appsec/localconfig/local_policy.yaml
```

### Mount layout

The compose files use the same host-side directory layout to keep NPM state and open-appsec state cleanly separated:

| Host path | Container path | Purpose |
|---|---|---|
| `./data` | `/data` | NPM state (database, proxy configs) |
| `./letsencrypt` | `/etc/letsencrypt` | Let's Encrypt certificates |
| `./appsec/localconfig` | `/ext/appsec` | Local policy / config exchange |
| `./appsec/conf` | `/etc/cp/conf` | open-appsec agent configuration |
| `./appsec/data` | `/etc/cp/data` | open-appsec agent data / ML model |
| `./appsec/logs` | `/var/log/nano_agent` | open-appsec agent logs |
| `./crowdsec/data` | `/var/lib/crowdsec/data` | CrowdSec persistent data |
| `./crowdsec/acquis.d` | `/etc/crowdsec/acquis.d` | CrowdSec acquisition files (includes `npm-open-appsec.yaml`) |
| `./data/logs` | `/var/log/npm` | NPM access logs consumed by CrowdSec |
