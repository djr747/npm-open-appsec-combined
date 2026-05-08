# npm-open-appsec-combined

Builds a combined NGINX Proxy Manager image with the latest open-appsec attachment module.

## What this repo provides

- `Dockerfile` based on `nginxproxymanager/nginx-proxy-manager:<release-tag>`
- Attachment build from `openappsec/attachment` git ref (default: `main`)
- NGINX patching to load `libngx_module.so`
- Persistence mount points for open-appsec data and model/config storage outside the container:
  - `/ext/appsec`
  - `/ext/appsec-logs`
  - `/etc/cp/conf`
  - `/etc/cp/data`

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
