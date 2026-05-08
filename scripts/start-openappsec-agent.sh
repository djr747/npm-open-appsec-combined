#!/usr/bin/env bash

set -euo pipefail

INSTALL_MARKER="/etc/cp/.npm_openappsec_installed"
ADVANCED_MODEL="/advanced-model/open-appsec-advanced-model.tgz"
WATCHDOG_PID=""
WATCHDOG_LOG="/var/log/nano_agent/watchdog.log"

mkdir -p /etc/cp/conf /etc/cp/data /var/log/nano_agent /ext/appsec /dev/shm/check-point

install_agent_if_needed() {
    if [ -f "${INSTALL_MARKER}" ]; then
        return
    fi

    orchestration_args=(--install --container_mode --skip_registration --hybrid_mode)

    if [ -n "${AGENT_TOKEN:-}" ]; then
        orchestration_args+=(--token "${AGENT_TOKEN}")
    fi

    /nano-service-installers/install-cp-nano-agent.sh "${orchestration_args[@]}"
    /nano-service-installers/install-cp-nano-attachment-registration-manager.sh --install
    /nano-service-installers/install-cp-nano-agent-cache.sh --install
    /nano-service-installers/install-cp-nano-service-http-transaction-handler.sh --install

    touch "${INSTALL_MARKER}"
}

start_watchdog() {
    touch /etc/cp/watchdog/wd.startup
    /etc/cp/watchdog/cp-nano-watchdog >>"${WATCHDOG_LOG}" 2>&1 &
    WATCHDOG_PID="$!"
}

cleanup() {
    if [ -n "${WATCHDOG_PID}" ] && ps -p "${WATCHDOG_PID}" >/dev/null 2>&1; then
        kill -TERM "${WATCHDOG_PID}" 2>/dev/null || true
        wait "${WATCHDOG_PID}" 2>/dev/null || true
    fi
}

trap cleanup SIGTERM SIGINT

install_agent_if_needed

if [ -f "${ADVANCED_MODEL}" ]; then
    mkdir -p /etc/cp/conf/waap
    tar -xzf "${ADVANCED_MODEL}" -C /etc/cp/conf/waap
fi

start_watchdog

while true; do
    # External trigger file used by open-appsec runtime components to request watchdog restart.
    if [ -f /tmp/restart_watchdog ]; then
        rm -f /tmp/restart_watchdog
        kill -TERM "${WATCHDOG_PID}" 2>/dev/null || true
        wait "${WATCHDOG_PID}" 2>/dev/null || true
        WATCHDOG_PID=""
    fi

    if [ -z "${WATCHDOG_PID}" ] || ! ps -p "${WATCHDOG_PID}" >/dev/null 2>&1; then
        start_watchdog
    fi

    sleep 5
done
