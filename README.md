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

## CrowdSec compatibility

This image is intended to stay compatible with existing CrowdSec-based NPM setups:

- still based on upstream `jc21/nginx-proxy-manager`
- only adds open-appsec module/runtime integration on top
- keeps NPM `/data/nginx/...` include structure intact
- does not remove/override existing CrowdSec custom snippets or mounted NPM data

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

## Integration test

Workflow: `.github/workflows/integration-test.yml`

Local run:

```bash
./scripts/test-single-container-startup.sh
```

By default, test artifacts are written under `./test-artifacts/` and cleaned up on success.
Set `KEEP_TEST_ARTIFACTS=1` to retain them for debugging.

The integration test builds the image, starts one container, and verifies:

- open-appsec watchdog process is running
- nginx process is running
- NPM backend process is running
- NPM UI endpoint on port `81` responds (`200`/`301`/`302`)

## Example deployments

Two compose files are provided under `examples/`:

### Cloud-managed (`examples/docker-compose.cloud-managed.yml`)

Connects to the open-appsec SaaS portal for policy management.

Set at least:

- `APPSEC_AGENT_TOKEN`
- `APPSEC_USER_EMAIL`

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
