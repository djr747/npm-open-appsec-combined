# npm-open-appsec-combined

Builds a combined NGINX Proxy Manager image with the latest open-appsec attachment module.

## What this repo provides

- Multi-stage `Dockerfile` based on `jc21/nginx-proxy-manager:<release-tag>`
- Attachment build from `openappsec/attachment` git ref (default: `main`)
- Separate builder stage so gcc/cmake/build dependencies are not left in the final runtime image
- Minimal NGINX patching to load `libngx_module.so`
- Persistence mount points for open-appsec data and model/config storage outside the container:
  - `/ext/appsec`
  - `/ext/appsec-logs`
  - `/etc/cp/conf`
  - `/etc/cp/data`

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
  - Local policy/config exchange path used by open-appsec integrations

For cloud-managed deployments, use `/cp-nano-agent` without `--standalone`.
`--standalone` is for locally managed policy mode and is not the primary use case documented here.

See `examples/docker-compose.cloud-managed.yml` for a working example.

## CrowdSec compatibility

This image is intended to remain compatible with existing CrowdSec-based NPM setups.

- It keeps the upstream `jc21/nginx-proxy-manager` runtime image as the base
- It only adds the open-appsec module binaries and one `load_module` line in `nginx.conf`
- It does not replace the existing `/data/nginx/...` include structure used by NPM custom configuration
- It does not remove or override CrowdSec-related custom snippets, bouncer configuration, or mounted NPM data

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

The example also externalizes:

- NPM state in `./data`
- Let's Encrypt state in `./letsencrypt`
- open-appsec config in `./appsec-config`
- open-appsec data / advanced model storage in `./appsec-data`
- open-appsec logs in `./appsec-logs`
