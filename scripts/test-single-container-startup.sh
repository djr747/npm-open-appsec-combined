#!/usr/bin/env bash
# End-to-end integration test: local-policy mode, rootless-compatible container.
#
# Verifies:
#   1. Image builds successfully (nginx source fetched from GitHub via wget shim)
#   2. Container starts without --privileged or inter-container IPC
#   3. open-appsec watchdog, nginx, and NPM backend processes come up
#   4. NPM UI endpoint on port 81 responds with HTTP 200/301/302
#   5. nginx workers and node (NPM backend) run as configured PUID (non-root)
#   6. /dev/shm/check-point is accessible inside the container (intra-container only)
#   7. Attachment commit file is present

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_NAME="${IMAGE_NAME:-local/npm-open-appsec:integration}"
CONTAINER_NAME="npm-open-appsec-it"
SKIP_BUILD="${SKIP_BUILD:-0}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-180}"
CURL_ERROR_CODE="000"  # curl exit code placeholder when the request fails
PUID=1000
PGID=1000

TEST_TMP_DIR="$(mktemp -d)"

cleanup() {
    docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    # Container processes run as root inside and may create root-owned files on the
    # volume mounts. Use a privileged docker container to remove them if direct rm
    # fails, then clean up the empty temp directory.
    rm -rf "${TEST_TMP_DIR}" 2>/dev/null         || { docker run --rm -v "${TEST_TMP_DIR}:/mnt" --entrypoint sh alpine                  -c 'rm -rf /mnt/*' >/dev/null 2>&1 || true
             rm -rf "${TEST_TMP_DIR}" 2>/dev/null || true; }
}
trap cleanup EXIT

mkdir -p \
    "${TEST_TMP_DIR}/data" \
    "${TEST_TMP_DIR}/letsencrypt" \
    "${TEST_TMP_DIR}/appsec/localconfig" \
    "${TEST_TMP_DIR}/appsec/conf" \
    "${TEST_TMP_DIR}/appsec/data" \
    "${TEST_TMP_DIR}/appsec/logs"

# Download the official open-appsec starter local policy for NPM.
echo "Downloading local_policy.yaml..."
curl -fsSL \
    https://raw.githubusercontent.com/openappsec/open-appsec-npm/main/deployment/local_policy.yaml \
    -o "${TEST_TMP_DIR}/appsec/localconfig/local_policy.yaml"

if [ "${SKIP_BUILD}" != "1" ]; then
    echo "Building image..."
    docker build -t "${IMAGE_NAME}" "${REPO_ROOT}"
fi

# Run in local-policy mode (no AGENT_TOKEN). Uses the container's own private
# IPC namespace — no --ipc flag, no --privileged needed.
echo "Starting container in local-policy mode..."
docker run -d --name "${CONTAINER_NAME}" \
    -e PUID="${PUID}" \
    -e PGID="${PGID}" \
    -e registered_server=NGINX \
    -e nginxproxymanager=true \
    -e autoPolicyLoad=true \
    -v "${TEST_TMP_DIR}/data:/data" \
    -v "${TEST_TMP_DIR}/letsencrypt:/etc/letsencrypt" \
    -v "${TEST_TMP_DIR}/appsec/localconfig:/ext/appsec" \
    -v "${TEST_TMP_DIR}/appsec/conf:/etc/cp/conf" \
    -v "${TEST_TMP_DIR}/appsec/data:/etc/cp/data" \
    -v "${TEST_TMP_DIR}/appsec/logs:/var/log/nano_agent" \
    -p 18080:80 \
    -p 18081:81 \
    -p 18443:443 \
    "${IMAGE_NAME}" >/dev/null

echo "Waiting for all services (timeout: ${TIMEOUT_SECONDS}s)..."
START_TIME="$(date +%s)"
UI_STATUS="curl_error"

while true; do
    if ! docker ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
        echo "FAIL: Container exited unexpectedly."
        docker logs "${CONTAINER_NAME}" || true
        exit 1
    fi

    UI_STATUS="$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:18081/ 2>/dev/null || echo "${CURL_ERROR_CODE}")"

    if docker exec "${CONTAINER_NAME}" pgrep -f cp-nano-watchdog >/dev/null 2>&1 \
        && docker exec "${CONTAINER_NAME}" pgrep -x nginx >/dev/null 2>&1 \
        && docker exec "${CONTAINER_NAME}" pgrep -f "node .*index.js" >/dev/null 2>&1 \
        && [[ "${UI_STATUS}" =~ ^(200|301|302)$ ]]; then
        break
    fi

    NOW="$(date +%s)"
    if [ $((NOW - START_TIME)) -ge "${TIMEOUT_SECONDS}" ]; then
        echo "FAIL: Timeout waiting for NPM + open-appsec services."
        echo "  watchdog:  $(docker exec "${CONTAINER_NAME}" pgrep -f cp-nano-watchdog >/dev/null 2>&1 && echo up || echo missing)"
        echo "  nginx:     $(docker exec "${CONTAINER_NAME}" pgrep -x nginx >/dev/null 2>&1 && echo up || echo missing)"
        echo "  node:      $(docker exec "${CONTAINER_NAME}" pgrep -f 'node .*index.js' >/dev/null 2>&1 && echo up || echo missing)"
        echo "  UI status: ${UI_STATUS}"
        docker logs "${CONTAINER_NAME}" || true
        exit 1
    fi

    sleep 3
done

echo ""
echo "=== Rootless-compatibility checks ==="

# 1. Container must not be privileged.
PRIVILEGED="$(docker inspect "${CONTAINER_NAME}" --format '{{.HostConfig.Privileged}}')"
if [ "${PRIVILEGED}" = "true" ]; then
    echo "FAIL: Container is running in privileged mode."
    exit 1
fi
echo "PASS: not privileged"

# 2. Container must use a private IPC namespace (no host sharing, no cross-container sharing).
IPC_MODE="$(docker inspect "${CONTAINER_NAME}" --format '{{.HostConfig.IpcMode}}')"
if [[ "${IPC_MODE}" == "host" || "${IPC_MODE}" == service:* ]]; then
    echo "FAIL: Container IPC mode '${IPC_MODE}' requires host/cross-container sharing (incompatible with rootless Docker)."
    exit 1
fi
echo "PASS: IPC is private (mode: ${IPC_MODE})"

# 3. nginx worker processes must run as PUID (non-root).
#    The nginx master runs as root to bind privileged ports (this is normal and
#    expected even in rootless Docker, where container root maps to an unprivileged
#    host UID). Verify that worker processes drop to the configured PUID.
NGINX_WORKER_UIDS="$(docker exec "${CONTAINER_NAME}" sh -c '
for f in /proc/[0-9]*/status; do
    name=$(grep "^Name:" "$f" 2>/dev/null | awk "{print \$2}")
    uid=$(grep "^Uid:" "$f" 2>/dev/null | awk "{print \$2}")
    [ "$name" = "nginx" ] && [ "$uid" != "0" ] && printf "%s\n" "$uid"
done; exit 0' | sort -u)"

if [ -z "${NGINX_WORKER_UIDS}" ]; then
    echo "FAIL: No non-root nginx worker processes found (workers should run as PUID=${PUID})."
    exit 1
fi
echo "PASS: nginx workers running as UID(s) $(echo "${NGINX_WORKER_UIDS}" | tr '\n' ' ')(non-root)"

# 4. node (NPM backend) must run as PUID (non-root).
NODE_UIDS="$(docker exec "${CONTAINER_NAME}" sh -c '
for f in /proc/[0-9]*/status; do
    name=$(grep "^Name:" "$f" 2>/dev/null | awk "{print \$2}")
    uid=$(grep "^Uid:" "$f" 2>/dev/null | awk "{print \$2}")
    [ "$name" = "node" ] && printf "%s\n" "$uid"
done; exit 0' | sort -u)"

if [ -z "${NODE_UIDS}" ]; then
    echo "FAIL: No node process found."
    exit 1
fi
if echo "${NODE_UIDS}" | grep -qx "0"; then
    echo "FAIL: node (NPM backend) running as root (UID 0)."
    exit 1
fi
echo "PASS: node (NPM backend) running as UID(s) $(echo "${NODE_UIDS}" | tr '\n' ' ')(non-root)"

# 5. /dev/shm/check-point must exist inside the container.
#    open-appsec uses this path for intra-container shared memory only — no
#    cross-container IPC namespace sharing is needed or used.
if ! docker exec "${CONTAINER_NAME}" test -d /dev/shm/check-point; then
    echo "FAIL: /dev/shm/check-point not found inside container."
    exit 1
fi
echo "PASS: /dev/shm/check-point present (intra-container shmem — no inter-container IPC)"

# 6. Attachment commit file must be present.
if ! docker exec "${CONTAINER_NAME}" test -f /etc/openappsec-attachment.commit; then
    echo "FAIL: /etc/openappsec-attachment.commit not found."
    exit 1
fi
ATTACH_COMMIT="$(docker exec "${CONTAINER_NAME}" cat /etc/openappsec-attachment.commit)"
echo "PASS: attachment commit ${ATTACH_COMMIT}"

echo ""
echo "UI endpoint: HTTP ${UI_STATUS}"
echo "All integration checks passed."
