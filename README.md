# npm-open-appsec-combined

Builds a combined NGINX Proxy Manager image with the latest open-appsec attachment module.

## What this repo provides

- Multi-stage `Dockerfile` based on `jc21/nginx-proxy-manager:<release-tag>`
- Attachment build from `openappsec/attachment` git ref (default: `main`)
- Separate builder stage so gcc/cmake/build dependencies are not left in the final runtime image
- Minimal NGINX patching to load `libngx_module.so`
- Keeps the upstream NPM `PUID`/`PGID` process model and extends ownership handling to the added `/ext/appsec` mount
- Shared persistence mount point in the NPM image:
  - `/ext/appsec`

The agent-side state for cloud-managed or standalone open-appsec runs is persisted by the separate `ghcr.io/openappsec/agent` container, not by the NPM container itself.
The recommended deployment does **not** require `ipc: host` or `ipc: shareable`; it uses a shared tmpfs volume mounted at `/dev/shm/check-point` instead.

## PUID / PGID support

The combined image keeps the upstream NPM startup model for running application processes with `PUID` / `PGID`.

- Set `PUID` and `PGID` on the NPM container to match the owner of your bind-mounted files
- The added `/ext/appsec` path is included in the ownership preparation so the shared open-appsec path follows the same uid/gid handling as the rest of the NPM data paths

The upstream base image still performs its initialization as root before dropping service processes to the configured uid/gid, so this is the same rootless-style process model that upstream NPM already uses.

## Cloud-managed open-appsec configuration

This image only adds the open-appsec NGINX attachment into the NPM container.
To actually enforce policy, run a separate `ghcr.io/openappsec/agent` container alongside it.

For the cloud-managed / SaaS-managed use case, the important agent environment variables are:

### Required

- `AGENT_TOKEN`
  - Profile/API token from the open-appsec Web UI / SaaS portal
  - This is the key value required to connect the deployed agent to cloud-managed policy
- `user_email`
  - Email address associated with the deployment or operator
- `registered_server`
  - Use `NGINX` for this image because the attachment is an NGINX module

### Common optional variables

- `autoPolicyLoad`
  - Useful for local declarative policy workflows
  - Usually not the primary control point for cloud-managed policy deployments
- `https_proxy`
  - Set this only if the agent must reach open-appsec services through an outbound proxy

### Required persistent mounts for the agent

- `/etc/cp/conf`
  - Agent configuration files
- `/etc/cp/data`
  - Agent data, including persisted ML assets such as the advanced model
- `/var/log/nano_agent`
  - Agent logs
- `/ext/appsec`
  - Local policy/config exchange path shared between the NPM container and the agent container

For cloud-managed deployments, use `/cp-nano-agent` without `--standalone`.
`--standalone` is for locally managed policy mode and is not the primary use case documented here.
The included compose example follows the NPMplus-style shared-memory layout by mounting a shared tmpfs volume at `/dev/shm/check-point` in both containers, so the attachment/agent IPC stays inside the compose stack without requiring host IPC.

See `examples/docker-compose.cloud-managed.yml` for a working example.

## CrowdSec compatibility

This image is intended to remain compatible with existing CrowdSec-based NPM setups.

- It keeps the upstream `jc21/nginx-proxy-manager` runtime image as the base
- It only adds the open-appsec module binaries and one `load_module` line in `nginx.conf`
- It does not replace the existing `/data/nginx/...` include structure used by NPM custom configuration
- It does not remove or override CrowdSec-related custom snippets, bouncer configuration, or mounted NPM data
- The example deployment removes the `ipc: host` requirement by using a shared tmpfs mount at `/dev/shm/check-point` instead

In practice, CrowdSec integration should continue to work as long as your existing CrowdSec configuration remains mounted through the normal NPM data/custom config paths.

## Automated image workflow

Workflow: `.github/workflows/build-image.yml`

- Nightly build (`schedule`) to pick up base image CVE/security updates
- Manual `workflow_dispatch` with optional:
  - `npm_tag` (defaults to latest NPM release)
  - `attachment_ref` (defaults to `main`)
- Published tags:
  - `<npm-release-tag>`
  - `<npm-release-tag>-oas-<attachment-commit-short-sha>`
  - `nightly` (nightly runs)

## Example deployment

An example cloud-managed compose file is included at:

- `examples/docker-compose.cloud-managed.yml`

Before starting it, set at least:

- `APPSEC_AGENT_TOKEN`
- `APPSEC_USER_EMAIL`

Optional but recommended on the NPM container:

- `PUID`
- `PGID`

The example keeps the upstream NPM-style mounts:

- NPM state in `./data`
- Let's Encrypt state in `./letsencrypt`

To keep the layout cleaner, the open-appsec agent state is grouped under `./data/openappsec/`:

- shared local policy/config exchange in `./data/openappsec/localconfig`
- open-appsec config in `./data/openappsec/conf`
- open-appsec data / advanced model storage in `./data/openappsec/data`
- open-appsec logs in `./data/openappsec/logs`
- shared attachment/agent memory path in the `shm-volume` tmpfs volume mounted to `/dev/shm/check-point`

This keeps the normal NPM mounts familiar while co-locating open-appsec state beneath the main data directory in a way that is closer to NPMplus-style organization.
