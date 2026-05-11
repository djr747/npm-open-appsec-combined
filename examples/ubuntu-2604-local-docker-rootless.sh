#!/usr/bin/env bash
# Interactive bootstrap for an Ubuntu 26.04 VM running the local-policy
# open-appsec example with rootless Docker.

set -Eeuo pipefail

RAW_BASE_URL="${RAW_BASE_URL:-https://raw.githubusercontent.com/djr747/npm-open-appsec-combined/main}"
REMOTE_COMPOSE_URL="${RAW_BASE_URL}/examples/docker-compose.local-policy.yml"
REMOTE_POLICY_URL="https://raw.githubusercontent.com/openappsec/open-appsec-npm/main/deployment/local_policy.yaml"

CONTAINER_USER="${CONTAINER_USER:-containeruser}"
CONTROL_DIR="${CONTROL_DIR:-/home/${CONTAINER_USER}/npm-open-appsec}"
IMAGE_REPOSITORY="${IMAGE_REPOSITORY:-ghcr.io/djr747/npm-open-appsec-combined}"
NPM_IMAGE_TAG="${NPM_IMAGE_TAG:-latest}"
TZ_NAME="${TZ:-UTC}"

info() { printf '[%s] %s\n' "$(date -Iseconds)" "$*"; }
die() { info "FATAL: $*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

prompt() {
    local var_name="$1"
    local question="$2"
    local default_value="${3:-}"
    local reply
    if [ -n "${default_value}" ]; then
        read -r -p "${question} [${default_value}]: " reply
        reply="${reply:-$default_value}"
    else
        read -r -p "${question}: " reply
    fi
    printf -v "${var_name}" '%s' "${reply}"
}

load_previous_env() {
    if sudo test -f "${CONTROL_DIR}/.env"; then
        local env_tmp
        env_tmp="$(mktemp /tmp/npm-open-appsec-existing-env.XXXXXX)"
        sudo cp "${CONTROL_DIR}/.env" "${env_tmp}"
        # shellcheck disable=SC1090
        set -a
        . "${env_tmp}"
        set +a
        rm -f "${env_tmp}"
    fi
}

ensure_subid_range() {
    local file="$1"
    local entry="${CONTAINER_USER}:100000:65536"
    sudo grep -Fxq "${entry}" "${file}" 2>/dev/null || printf '%s\n' "${entry}" | sudo tee -a "${file}" >/dev/null
}

fetch_file() {
    local url="$1"
    local dest="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --retry-delay 2 "${url}" -o "${dest}"
    else
        wget -qO "${dest}" "${url}"
    fi
}

install_for_container_user() {
    local src="$1"
    local dest="$2"
    local mode="$3"
    if ! sudo test -f "${dest}" || ! sudo cmp -s "${dest}" "${src}" 2>/dev/null; then
        sudo install -o "${CONTAINER_USER}" -g "${CONTAINER_USER}" -m "${mode}" "${src}" "${dest}"
    fi
}

write_env_var() {
    local key="$1"
    local value="$2"
    printf "%s='" "${key}"
    while [ -n "${value}" ]; do
        case "${value}" in
            *"'"*)
                printf "%s'\\''" "${value%%\'*}"
                value="${value#*\'}"
                ;;
            *)
                printf "%s" "${value}"
                value=""
                ;;
        esac
    done
    printf "'\n"
}

detect_compose_exec() {
    local uid
    uid="$(id -u "${CONTAINER_USER}")"
    local runtime_dir="/run/user/${uid}"

    if sudo -u "${CONTAINER_USER}" -H env HOME="/home/${CONTAINER_USER}" XDG_RUNTIME_DIR="${runtime_dir}" docker compose version >/dev/null 2>&1; then
        printf '%s compose' "$(command -v docker)"
        return 0
    fi

    if command -v docker-compose >/dev/null 2>&1; then
        printf '%s' "$(command -v docker-compose)"
        return 0
    fi

    return 1
}

install_ubuntu_packages() {
    local packages=(
        docker.io
        uidmap
        slirp4netns
        fuse-overlayfs
        dbus-user-session
        rootlesskit
        curl
        wget
    )
    sudo apt-get update -y >/dev/null
    sudo apt-get install -y "${packages[@]}" >/dev/null

    command -v newuidmap >/dev/null 2>&1 || die "newuidmap was not found after installing rootless Docker prerequisites."
    command -v newgidmap >/dev/null 2>&1 || die "newgidmap was not found after installing rootless Docker prerequisites."
}

ensure_docker_compose() {
    if detect_compose_exec >/dev/null 2>&1; then
        return 0
    fi

    info "Docker Compose was not available from the base install; checking optional distro packages..."
    sudo apt-get install -y docker-compose-v2 >/dev/null 2>&1 || true
    if detect_compose_exec >/dev/null 2>&1; then
        return 0
    fi

    sudo apt-get install -y docker-compose-plugin >/dev/null 2>&1 || true
    if detect_compose_exec >/dev/null 2>&1; then
        return 0
    fi

    sudo apt-get install -y docker-compose >/dev/null 2>&1 || true
    detect_compose_exec >/dev/null 2>&1 || die "Docker Compose support was not found. Install docker compose or docker-compose, then rerun this script."
}

if [ "$(id -u)" -eq 0 ]; then
    die "Run this script as a sudo-capable admin user, not as root."
fi

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<EOF
Usage:
  curl -fsSL ${RAW_BASE_URL}/examples/ubuntu-2604-local-docker-rootless.sh -o ubuntu-2604-local-docker-rootless.sh
  chmod +x ubuntu-2604-local-docker-rootless.sh
  ./ubuntu-2604-local-docker-rootless.sh
EOF
    exit 0
fi

need sudo

sudo -v
sudo_keepalive() {
    while true; do
        sudo -n true >/dev/null 2>&1 || exit 0
        sleep 60
    done
}
sudo_keepalive &
SUDO_KEEPALIVE_PID="$!"
trap 'kill "${SUDO_KEEPALIVE_PID}" >/dev/null 2>&1 || true' EXIT

load_previous_env

info "Installing packages and enabling rootless Docker support..."
install_ubuntu_packages
sudo systemctl disable --now docker.service docker.socket >/dev/null 2>&1 || true
if ! sudo grep -Fxq 'net.ipv4.ip_unprivileged_port_start = 0' /etc/sysctl.d/99-openappsec-rootless-ports.conf 2>/dev/null; then
    printf 'net.ipv4.ip_unprivileged_port_start = 0\n' | sudo tee /etc/sysctl.d/99-openappsec-rootless-ports.conf >/dev/null
    sudo sysctl --system >/dev/null
fi

info "Ensuring ${CONTAINER_USER} exists and has rootless ranges..."
if ! id "${CONTAINER_USER}" >/dev/null 2>&1; then
    sudo useradd --create-home --user-group --shell /bin/bash "${CONTAINER_USER}"
fi
sudo loginctl enable-linger "${CONTAINER_USER}"
ensure_subid_range /etc/subuid
ensure_subid_range /etc/subgid

PUID="$(id -u "${CONTAINER_USER}")"
PGID="$(id -g "${CONTAINER_USER}")"
USER_HOME="/home/${CONTAINER_USER}"
USER_RUNTIME_DIR="/run/user/${PUID}"
USER_ENV=(HOME="${USER_HOME}" XDG_RUNTIME_DIR="${USER_RUNTIME_DIR}" DBUS_SESSION_BUS_ADDRESS="unix:path=${USER_RUNTIME_DIR}/bus" PATH="${USER_HOME}/bin:${USER_HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin")
sudo systemctl start "user@${PUID}.service" >/dev/null 2>&1 || true
sudo install -d -o "${CONTAINER_USER}" -g "${CONTAINER_USER}" -m 0700 "${USER_RUNTIME_DIR}"
ensure_docker_compose

info "Configuring rootless Docker for ${CONTAINER_USER}..."
if ! sudo -u "${CONTAINER_USER}" -H env "${USER_ENV[@]}" DOCKER_HOST="unix://${USER_RUNTIME_DIR}/docker.sock" docker info >/dev/null 2>&1; then
    if ! command -v dockerd-rootless-setuptool.sh >/dev/null 2>&1; then
        die "dockerd-rootless-setuptool.sh was not found. Install Docker rootless extras, then rerun this script."
    fi
    sudo -u "${CONTAINER_USER}" -H env "${USER_ENV[@]}" dockerd-rootless-setuptool.sh install --force >/dev/null
    sudo -u "${CONTAINER_USER}" -H env "${USER_ENV[@]}" systemctl --user enable --now docker.service >/dev/null
fi
sudo -u "${CONTAINER_USER}" -H env "${USER_ENV[@]}" DOCKER_HOST="unix://${USER_RUNTIME_DIR}/docker.sock" docker info >/dev/null \
    || die "Rootless Docker did not start for ${CONTAINER_USER}."

info "Preparing private control directory under ${CONTROL_DIR}..."
sudo install -d -o "${CONTAINER_USER}" -g "${CONTAINER_USER}" -m 0700 "${CONTROL_DIR}"

info "Preparing service data directories under /opt..."
sudo install -d -o "${CONTAINER_USER}" -g "${CONTAINER_USER}" -m 0755 \
    "/opt/npm/data" \
    "/opt/npm/letsencrypt" \
    "/opt/openappsec/localconfig" \
    "/opt/openappsec/conf" \
    "/opt/openappsec/data" \
    "/opt/openappsec/logs"

info "Downloading compose and local policy files..."
COMPOSE_TMP="$(mktemp /tmp/npm-open-appsec-compose.XXXXXX)"
fetch_file "${REMOTE_COMPOSE_URL}" "${COMPOSE_TMP}"
if [ ! -s "/opt/openappsec/localconfig/local_policy.yaml" ]; then
    POLICY_TMP="$(mktemp /tmp/npm-open-appsec-policy.XXXXXX)"
    fetch_file "${REMOTE_POLICY_URL}" "${POLICY_TMP}"
    install_for_container_user "${POLICY_TMP}" "/opt/openappsec/localconfig/local_policy.yaml" 0644
    rm -f "${POLICY_TMP}"
fi
if ! sudo test -f "${CONTROL_DIR}/docker-compose.yml" || ! sudo cmp -s "${CONTROL_DIR}/docker-compose.yml" "${COMPOSE_TMP}" 2>/dev/null; then
    install_for_container_user "${COMPOSE_TMP}" "${CONTROL_DIR}/docker-compose.yml" 0644
fi
rm -f "${COMPOSE_TMP}"

info "Writing compose environment file..."
ENV_TMP="$(mktemp /tmp/npm-open-appsec-env.XXXXXX)"
{
    write_env_var IMAGE_REPOSITORY "${IMAGE_REPOSITORY}"
    write_env_var NPM_IMAGE_TAG "${NPM_IMAGE_TAG}"
    write_env_var PUID "${PUID}"
    write_env_var PGID "${PGID}"
    write_env_var TZ "${TZ_NAME}"
    write_env_var APPSEC_AUTO_POLICY_LOAD "true"
} >"${ENV_TMP}"
if ! sudo test -f "${CONTROL_DIR}/.env" || ! sudo cmp -s "${CONTROL_DIR}/.env" "${ENV_TMP}" 2>/dev/null; then
    install_for_container_user "${ENV_TMP}" "${CONTROL_DIR}/.env" 0600
else
    rm -f "${ENV_TMP}"
fi
rm -f "${ENV_TMP}"

COMPOSE_EXEC="$(detect_compose_exec)" || die "Docker compose support was not found."
UNIT_PATH="/home/${CONTAINER_USER}/.config/systemd/user/npm-open-appsec.service"
info "Creating user service at ${UNIT_PATH}..."
UNIT_TMP="${UNIT_PATH}.new"
sudo install -D -o "${CONTAINER_USER}" -g "${CONTAINER_USER}" -m 0644 /dev/null "${UNIT_TMP}"
sudo tee "${UNIT_TMP}" >/dev/null <<EOF
[Unit]
Description=NPM open-appsec local-policy deployment (Ubuntu 26.04, rootless Docker)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${CONTROL_DIR}
Environment=DOCKER_HOST=unix:///run/user/${PUID}/docker.sock
ExecStart=${COMPOSE_EXEC} --env-file .env -f docker-compose.yml up -d --remove-orphans
ExecStop=${COMPOSE_EXEC} --env-file .env -f docker-compose.yml down --remove-orphans
TimeoutStartSec=0
TimeoutStopSec=0

[Install]
WantedBy=default.target
EOF
if ! sudo test -f "${UNIT_PATH}" || ! sudo cmp -s "${UNIT_PATH}" "${UNIT_TMP}" 2>/dev/null; then
    sudo mv "${UNIT_TMP}" "${UNIT_PATH}"
else
    sudo rm -f "${UNIT_TMP}"
fi
sudo chown "${CONTAINER_USER}:${CONTAINER_USER}" "${UNIT_PATH}"

info "Starting the service..."
sudo -u "${CONTAINER_USER}" -H env HOME="/home/${CONTAINER_USER}" XDG_RUNTIME_DIR="/run/user/${PUID}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${PUID}/bus" systemctl --user daemon-reload
sudo -u "${CONTAINER_USER}" -H env HOME="/home/${CONTAINER_USER}" XDG_RUNTIME_DIR="/run/user/${PUID}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${PUID}/bus" systemctl --user enable --now npm-open-appsec.service

info "Done."
info "Control directory: ${CONTROL_DIR}"
info "Service directories: /opt/npm and /opt/openappsec"
info "To manage later, run systemctl --user as ${CONTAINER_USER} with XDG_RUNTIME_DIR=/run/user/${PUID}."
