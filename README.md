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
official `crowdsec-nginx-bouncer` (Lua-based) cannot be used. Instead:

1. **CrowdSec agent** — runs as a sidecar container, parses NPM nginx access logs (and
   optionally open-appsec logs), and maintains a local IP ban database.
2. **`fbonalair/traefik-crowdsec-bouncer`** — a lightweight Go HTTP service that exposes
   `GET /api/v1/forwardAuth`, returning `200` (allow) or `403` (ban) based on the client IP.
3. **nginx `auth_request`** — nginx's built-in module sends a subrequest to the bouncer for
   every inbound request. No Lua needed.

### Quick start

```bash
# 1. Create the custom nginx config directory if needed
mkdir -p ./data/nginx/custom

# 2. Drop the http-level bouncer snippet in place
cp examples/crowdsec-snippets/http_top.conf ./data/nginx/custom/http_top.conf

# 3. Create acquis.d directory and drop the log acquisition config in place
mkdir -p ./crowdsec/conf/acquis.d
cp examples/crowdsec-snippets/acquis.yaml ./crowdsec/conf/acquis.d/npm-open-appsec.yaml

# 4. Start the three-service stack
docker compose -f examples/docker-compose.crowdsec.yml up -d

# 5. Create a bouncer API key
docker exec crowdsec cscli bouncers add npm-bouncer
# Copy the output key into CROWDSEC_BOUNCER_API_KEY (env file or inline)

# 6. Restart the bouncer so it picks up the key
docker compose -f examples/docker-compose.crowdsec.yml restart crowdsec-bouncer

# 7. For each NPM proxy host to protect, paste the contents of
#    examples/crowdsec-snippets/proxy-host-advanced.conf into the host's
#    "Advanced" configuration textarea in the NPM UI.
```

### Auto-generation of http_top.conf

Set `CROWDSEC_BOUNCER_URL=crowdsec-bouncer:8080` in the `npm-open-appsec` container environment.
The startup script generates `./data/nginx/custom/http_top.conf` automatically on first container
start (the file is **never overwritten** once it exists).

### Excluding specific hosts from CrowdSec checks

**Manual method** — edit the `map` block in `./data/nginx/custom/http_top.conf`:

```nginx
map $host $crowdsec_skip {
    default 0;
    "internal.example.com"    1;   # bypasses CrowdSec for this host
    "webhook.example.com"     1;
}
```

**Env-var method** — set `CROWDSEC_SKIP_HOSTS` in the container environment:

```yaml
environment:
  - CROWDSEC_BOUNCER_URL=crowdsec-bouncer:8080
  - CROWDSEC_SKIP_HOSTS=internal.example.com,webhook.example.com
```

The startup script populates the `map` block from this list when it generates `http_top.conf` on
first start. After initial generation, edit the file directly to add or remove exclusions.

### CrowdSec AppSec (optional WAF rules)

CrowdSec includes a WAF component (AppSec) that inspects request headers against virtual-patch
rules. To enable it:

```bash
docker exec crowdsec cscli collections install \
  crowdsecurity/appsec-virtual-patching \
  crowdsecurity/appsec-generic-rules
```

Then uncomment the AppSec sections in `http_top.conf`, `proxy-host-advanced.conf`, and
`acquis.yaml`. The `auth_request` subrequest forwards request headers (not the body) to the
AppSec endpoint on port `7422`. Header-based attacks (URL injection, header manipulation) are
detected; POST-body inspection requires a Lua-capable nginx build.

### open-appsec log ingestion into CrowdSec

CrowdSec can parse open-appsec intrusion event logs to issue additional IP bans in response to
events detected by open-appsec. Uncomment the `openappsec` section in `acquis.yaml` and the
corresponding log volume mount in `docker-compose.crowdsec.yml`.

If using the open-appsec cloud backend, ensure the default log trigger in the cloud dashboard is
set to **"Log to gateway/agent"**; otherwise intrusion events are not written to local log files.

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

### CrowdSec + open-appsec (`examples/docker-compose.crowdsec.yml`)

Adds CrowdSec IP-reputation blocking alongside open-appsec. See the [CrowdSec integration](#crowdsec-integration) section above for the full setup guide.

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
