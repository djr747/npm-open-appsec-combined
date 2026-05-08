#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_NAME="${IMAGE_NAME:-local/npm-open-appsec:integration}"
CONTAINER_NAME="npm-open-appsec-it"
SKIP_BUILD="${SKIP_BUILD:-0}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-120}"

TEST_TMP_DIR="$(mktemp -d)"

cleanup() {
    docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    rm -rf "${TEST_TMP_DIR}"
}

trap cleanup EXIT

mkdir -p \
    "${TEST_TMP_DIR}/data" \
    "${TEST_TMP_DIR}/letsencrypt" \
    "${TEST_TMP_DIR}/openappsec/localconfig" \
    "${TEST_TMP_DIR}/openappsec/conf" \
    "${TEST_TMP_DIR}/openappsec/data" \
    "${TEST_TMP_DIR}/openappsec/logs"

cat > "${TEST_TMP_DIR}/openappsec/localconfig/local_policy.yaml" <<'EOF'
appSecClassName: "NginxManager"
EOF

if [ "${SKIP_BUILD}" != "1" ]; then
    docker build -t "${IMAGE_NAME}" "${REPO_ROOT}"
fi

docker run -d --name "${CONTAINER_NAME}" \
    -e PUID=1000 \
    -e PGID=1000 \
    -e AGENT_TOKEN=dummy-token-for-startup-test \
    -e user_email=test@example.com \
    -e registered_server=NGINX \
    -e nginxproxymanager=true \
    -e autoPolicyLoad=true \
    -v "${TEST_TMP_DIR}/data:/data" \
    -v "${TEST_TMP_DIR}/letsencrypt:/etc/letsencrypt" \
    -v "${TEST_TMP_DIR}/openappsec/localconfig:/ext/appsec" \
    -v "${TEST_TMP_DIR}/openappsec/conf:/etc/cp/conf" \
    -v "${TEST_TMP_DIR}/openappsec/data:/etc/cp/data" \
    -v "${TEST_TMP_DIR}/openappsec/logs:/var/log/nano_agent" \
    -p 18080:80 \
    -p 18081:81 \
    -p 18443:443 \
    "${IMAGE_NAME}" >/dev/null

START_TIME="$(date +%s)"
while true; do
    if ! docker ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
        echo "Container exited unexpectedly."
        docker logs "${CONTAINER_NAME}" || true
        exit 1
    fi

    UI_STATUS="$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:18081/ || true)"
    if docker exec "${CONTAINER_NAME}" pgrep -f cp-nano-watchdog >/dev/null 2>&1 \
        && docker exec "${CONTAINER_NAME}" pgrep -x nginx >/dev/null 2>&1 \
        && docker exec "${CONTAINER_NAME}" pgrep -f "node .*index.js" >/dev/null 2>&1 \
        && [[ "${UI_STATUS}" =~ ^(200|301|302)$ ]]; then
        break
    fi

    NOW="$(date +%s)"
    if [ $((NOW - START_TIME)) -ge "${TIMEOUT_SECONDS}" ]; then
        echo "Timeout waiting for NPM + open-appsec processes to start."
        docker logs "${CONTAINER_NAME}" || true
        exit 1
    fi

    sleep 3
done

docker exec "${CONTAINER_NAME}" test -f /etc/openappsec-attachment.commit
echo "UI endpoint returned status: ${UI_STATUS}"
echo "Integration startup test passed."
