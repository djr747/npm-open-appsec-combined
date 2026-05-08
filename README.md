# npm-open-appsec-combined

Builds a single-container NGINX Proxy Manager image with:

- the open-appsec NGINX attachment module
- the open-appsec agent runtime in the same container

This removes the cross-container shared-memory/IPC requirement for NPM + open-appsec deployments.

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
  - Use `NGINX`
- `nginxproxymanager`
  - Set to `true` for NPM integration behavior

### Common optional variables

- `autoPolicyLoad` (default in example: `true`)
- `https_proxy`

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

## Example deployment

Example file:

- `examples/docker-compose.cloud-managed.yml`

Set at least:

- `APPSEC_AGENT_TOKEN`
- `APPSEC_USER_EMAIL`

Optional and recommended:

- `PUID`
- `PGID`

Mount layout:

- NPM state in `./data`
- Let's Encrypt state in `./letsencrypt`
- open-appsec local config in `./data/openappsec/localconfig`
- open-appsec config in `./data/openappsec/conf`
- open-appsec data in `./data/openappsec/data`
- open-appsec logs in `./data/openappsec/logs`
