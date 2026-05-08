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
- `registered_server`
  - Set to `NGINX`
- `nginxproxymanager`
  - Set to `true` for NPM integration behavior

`registered_server` and `nginxproxymanager` are intentionally both kept for compatibility with open-appsec's generic agent registration path and the NPM-specific integration path.

### Common optional variables

- `autoPolicyLoad` (default in example: `true`)
- `https_proxy`

## Local policy mode (still supported)

Local policy mode is also supported in the same single-container setup.

- Leave `AGENT_TOKEN` unset (no cloud profile connection)
- Keep `autoPolicyLoad=true`
- Place `local_policy.yaml` under the mounted `/ext/appsec` path (host-side: `./appsec/localconfig/local_policy.yaml`)
- Keep `registered_server=NGINX` and `nginxproxymanager=true`

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

CrowdSec adds community-sourced IP reputation blocking on top of the open-appsec WAF. The two
tools are complementary: open-appsec provides ML-based request inspection; CrowdSec provides
crowd-sourced threat intelligence and IP-level banning.

### Architecture (no Lua module required)

The `jc21/nginx-proxy-manager` base image does not include a Lua/OpenResty nginx build, so the
official `crowdsec-nginx-bouncer` (Lua-based) cannot be used. This repo instead generates nginx
`auth_request` config automatically from container environment variables:

1. **CrowdSec agent** — parses NPM nginx access logs and maintains CrowdSec decisions.
2. **`fbonalair/traefik-crowdsec-bouncer`** — exposes `GET /api/v1/forwardAuth`, returning `200`
   (allow) or `403` (ban) based on the client IP.
3. **Auto-generated nginx includes** — the startup script writes `http_top.conf`,
   `server_proxy.conf`, and `server_redirect.conf` under `/data/nginx/custom/` on first start, so
   all proxy hosts are protected automatically with no file copies and no NPM UI edits.

### Quick start

```bash
# Start the self-contained CrowdSec stack
docker compose -f examples/docker-compose.crowdsec.yml up -d
```

That compose file is fully declarative:

- CrowdSec auto-registers the bouncer from `BOUNCER_KEY_NPM_OPEN_APPSEC`
- CrowdSec writes its nginx log acquisition + AppSec listener config inline at container startup
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
`7422`.

To switch nginx from the IP-decision bouncer flow to CrowdSec AppSec header inspection, set:

```yaml
environment:
  - CROWDSEC_AUTH_MODE=appsec
```

The generated `server_proxy.conf` / `server_redirect.conf` then send auth subrequests to
`crowdsec:7422` instead of `crowdsec-bouncer:8080`.

Because nginx `auth_request` does not forward the request body, this mode provides header/URL
inspection only. Full request-body inspection would require a Lua-capable nginx build.

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
- Build strategy: `amd64` on `ubuntu-latest` (native), `arm64` on `ubuntu-24.04-arm` (native,
  no QEMU). Each platform is built independently and pushed by digest; a `merge` job assembles
  the multi-arch manifest list.

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

Three compose files are provided under `examples/`:

### Cloud-managed (`examples/docker-compose.cloud-managed.yml`)

Connects to the open-appsec SaaS portal for policy management and also includes the complete
CrowdSec sidecar configuration (agent + bouncer) so the example is deployable as-is.

Set at least:

- `APPSEC_AGENT_TOKEN`
- `APPSEC_USER_EMAIL`
- `CROWDSEC_BOUNCER_API_KEY` (set this to a long random string if you keep CrowdSec enabled)

Optional and recommended:

- `PUID`
- `PGID`

### Locally managed (`examples/docker-compose.local-policy.yml`)

Runs fully offline using a local `local_policy.yaml` — no cloud token needed.

Before starting:

```bash
mkdir -p ./appsec/localconfig
curl -fsSL https://raw.githubusercontent.com/openappsec/open-appsec-npm/main/deployment/local_policy.yaml \
     -o ./appsec/localconfig/local_policy.yaml
```

### CrowdSec + open-appsec (`examples/docker-compose.crowdsec.yml`)

Standalone compose-only CrowdSec example showing the same self-bootstrapping CrowdSec integration
pattern without any file copies or NPM UI edits. See the [CrowdSec integration](#crowdsec-integration)
section above for the full setup guide.

### Mount layout (both modes)

Both compose files use the same host-side directory layout to keep NPM state and open-appsec state cleanly separated:

| Host path | Container path | Purpose |
|---|---|---|
| `./data` | `/data` | NPM state (database, proxy configs) |
| `./letsencrypt` | `/etc/letsencrypt` | Let's Encrypt certificates |
| `./appsec/localconfig` | `/ext/appsec` | Local policy / config exchange |
| `./appsec/conf` | `/etc/cp/conf` | open-appsec agent configuration |
| `./appsec/data` | `/etc/cp/data` | open-appsec agent data / ML model |
| `./appsec/logs` | `/var/log/nano_agent` | open-appsec agent logs |
