#!/usr/bin/env bash
# Interactive bootstrap for a Rocky/RHEL 10 VM running the cloud-managed
# open-appsec example with the advanced model.

set -Eeuo pipefail

RAW_BASE_URL="${RAW_BASE_URL:-https://raw.githubusercontent.com/djr747/npm-open-appsec-combined/main}"
REMOTE_COMPOSE_URL="${RAW_BASE_URL}/examples/docker-compose.cloud-managed.yml"
REMOTE_CROWDSEC_URL="${RAW_BASE_URL}/crowdsec/acquis.d/npm-open-appsec.yaml"

CONTAINER_USER="${CONTAINER_USER:-containeruser}"
CONTROL_DIR="${CONTROL_DIR:-/home/${CONTAINER_USER}/npm-open-appsec}"
IMAGE_REPOSITORY="${IMAGE_REPOSITORY:-ghcr.io/djr747/npm-open-appsec-combined}"
NPM_IMAGE_TAG="${NPM_IMAGE_TAG:-latest}"
TZ_NAME="${TZ:-UTC}"
NPM_HTTP_PORT="${NPM_HTTP_PORT:-8080}"
NPM_ADMIN_PORT="${NPM_ADMIN_PORT:-8181}"
NPM_HTTPS_PORT="${NPM_HTTPS_PORT:-8443}"

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

prompt_yes_no() {
    local var_name="$1"
    local question="$2"
    local default_value="${3:-Y}"
    local reply
    case "${default_value}" in
        true|TRUE) default_value="Y" ;;
        false|FALSE) default_value="N" ;;
    esac
    read -r -p "${question} [${default_value}]: " reply
    reply="${reply:-${default_value}}"
    case "${reply}" in
        y|Y|yes|YES|true|TRUE) printf -v "${var_name}" 'true' ;;
        n|N|no|NO|false|FALSE) printf -v "${var_name}" 'false' ;;
        *) die "Please answer yes or no for: ${question}" ;;
    esac
}

prompt_yes_no_with_previous() {
    local var_name="$1"
    local question="$2"
    local previous_value="${3:-}"
    local default_value="${4:-Y}"
    local prompt_default="${default_value}"
    if [ -n "${previous_value}" ]; then
        case "${previous_value}" in
            true|TRUE|yes|YES|y|Y) prompt_default="Y" ;;
            false|FALSE|no|NO|n|N) prompt_default="N" ;;
        esac
    fi
    prompt_yes_no "${var_name}" "${question}" "${prompt_default}"
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

install_text_for_container_user() {
    local src="$1"
    local dest="$2"
    local mode="$3"
    sudo install -D -o "${CONTAINER_USER}" -g "${CONTAINER_USER}" -m "${mode}" "${src}" "${dest}"
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
    local user_home="/home/${CONTAINER_USER}"
    local user_path="${user_home}/.local/bin:/usr/local/bin:/usr/bin:/bin"
    local podman_compose

    if sudo -u "${CONTAINER_USER}" -H sh -lc "export HOME=\"${user_home}\"; export XDG_RUNTIME_DIR=\"${runtime_dir}\"; export PATH=\"${user_path}\"; cd \"\$HOME\" && podman compose version" >/dev/null 2>&1; then
        printf '%s compose' "$(command -v podman)"
        return 0
    fi

    podman_compose="$(sudo -u "${CONTAINER_USER}" -H sh -lc "export HOME=\"${user_home}\"; export PATH=\"${user_path}\"; cd \"\$HOME\" && command -v podman-compose" 2>/dev/null || true)"
    if [ -n "${podman_compose}" ]; then
        printf '%s' "${podman_compose}"
        return 0
    fi

    return 1
}

install_rocky_packages() {
    local packages=(
        podman
        firewalld
        slirp4netns
        fuse-overlayfs
        curl
        wget
        python3
        python3-pip
        shadow-utils
    )
    sudo dnf install -y "${packages[@]}" >/dev/null

    if ! command -v newuidmap >/dev/null 2>&1 || ! command -v newgidmap >/dev/null 2>&1; then
        sudo dnf install -y shadow-utils-subid >/dev/null 2>&1 || true
    fi

    command -v newuidmap >/dev/null 2>&1 || die "newuidmap was not found after installing rootless Podman prerequisites."
    command -v newgidmap >/dev/null 2>&1 || die "newgidmap was not found after installing rootless Podman prerequisites."
}

ensure_podman_compose() {
    local user_home="/home/${CONTAINER_USER}"
    local user_path="${user_home}/.local/bin:/usr/local/bin:/usr/bin:/bin"

    if detect_compose_exec >/dev/null 2>&1; then
        return 0
    fi

    info "podman-compose package was not available from the base install; checking optional distro package..."
    sudo dnf install -y podman-compose >/dev/null 2>&1 || true
    if detect_compose_exec >/dev/null 2>&1; then
        return 0
    fi

    info "Installing podman-compose for ${CONTAINER_USER} with pip..."
    if ! sudo -u "${CONTAINER_USER}" -H sh -lc "export HOME=\"${user_home}\"; export PATH=\"${user_path}\"; cd \"\$HOME\" && python3 -m pip install --user --upgrade podman-compose" >/dev/null 2>&1; then
        sudo -u "${CONTAINER_USER}" -H sh -lc "export HOME=\"${user_home}\"; export PATH=\"${user_path}\"; cd \"\$HOME\" && python3 -m pip install --user --break-system-packages --upgrade podman-compose" >/dev/null \
            || die "podman-compose could not be installed. Install a Compose provider manually, then rerun this script."
    fi

    detect_compose_exec >/dev/null 2>&1 || die "podman-compose installed, but it was not found in ${user_path}."
}

configure_firewall_port_forwards() {
    info "Configuring firewalld port forwarding for rootless Podman..."
    sudo systemctl enable --now firewalld >/dev/null
    sudo firewall-cmd --permanent --add-forward-port="port=80:proto=tcp:toport=${NPM_HTTP_PORT}" >/dev/null 2>&1 || true
    sudo firewall-cmd --permanent --add-forward-port="port=81:proto=tcp:toport=${NPM_ADMIN_PORT}" >/dev/null 2>&1 || true
    sudo firewall-cmd --permanent --add-forward-port="port=443:proto=tcp:toport=${NPM_HTTPS_PORT}" >/dev/null 2>&1 || true
    sudo firewall-cmd --reload >/dev/null
}

if [ "$(id -u)" -eq 0 ]; then
    die "Run this script as a sudo-capable admin user, not as root."
fi

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<EOF
Usage:
  curl -fsSL ${RAW_BASE_URL}/examples/rocky-rhel10-cloud-managed-advanced.sh -o rocky-rhel10-cloud-managed-advanced.sh
  chmod +x rocky-rhel10-cloud-managed-advanced.sh
  ./rocky-rhel10-cloud-managed-advanced.sh
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
cd /
PREVIOUS_ADVANCED_MODEL_SOURCE="${ADVANCED_MODEL_SOURCE:-}"
PREVIOUS_CROWDSEC_ENABLED="${CROWDSEC_ENABLED:-}"

prompt "APPSEC_AGENT_TOKEN" "Cloud-managed open-appsec agent token" "${APPSEC_AGENT_TOKEN:-}"
prompt "APPSEC_USER_EMAIL" "Deployment operator email" "${APPSEC_USER_EMAIL:-}"
prompt_yes_no_with_previous "ENABLE_CROWDSEC" "Enable CrowdSec integration and auto-registration" "${PREVIOUS_CROWDSEC_ENABLED}" "Y"
if [ "${ENABLE_CROWDSEC}" = "true" ]; then
    prompt "CROWDSEC_ENROLL_KEY" "CrowdSec enrollment key (leave blank to skip registration)" "${CROWDSEC_ENROLL_KEY:-}"
    prompt "CROWDSEC_ENROLL_INSTANCE_NAME" "CrowdSec instance name" "${CROWDSEC_ENROLL_INSTANCE_NAME:-npm-open-appsec}"
    COMPOSE_PROFILES="crowdsec"
    COMPOSE_PROFILE_ARG="--profile crowdsec"
else
    CROWDSEC_ENROLL_KEY=""
    CROWDSEC_ENROLL_INSTANCE_NAME=""
    COMPOSE_PROFILES=""
    COMPOSE_PROFILE_ARG=""
fi
prompt "ADVANCED_MODEL_SOURCE" "Advanced model tarball URL or local path" "${ADVANCED_MODEL_SOURCE:-}"

[ -n "${IMAGE_REPOSITORY}" ] || die "IMAGE_REPOSITORY is required."
[ -n "${APPSEC_AGENT_TOKEN}" ] || die "APPSEC_AGENT_TOKEN is required."
[ -n "${APPSEC_USER_EMAIL}" ] || die "APPSEC_USER_EMAIL is required."
[ -n "${ADVANCED_MODEL_SOURCE}" ] || die "Advanced model source is required."

info "Installing packages and enabling rootless Podman support..."
install_rocky_packages
configure_firewall_port_forwards

info "Ensuring ${CONTAINER_USER} exists and has rootless ranges..."
if ! id "${CONTAINER_USER}" >/dev/null 2>&1; then
    sudo useradd --create-home --user-group --shell /bin/bash "${CONTAINER_USER}"
fi
sudo loginctl enable-linger "${CONTAINER_USER}"
ensure_subid_range /etc/subuid
ensure_subid_range /etc/subgid
PUID="$(id -u "${CONTAINER_USER}")"
PGID="$(id -g "${CONTAINER_USER}")"
sudo systemctl start "user@${PUID}.service" >/dev/null 2>&1 || true
ensure_podman_compose

info "Preparing private control directory under ${CONTROL_DIR}..."
sudo install -d -o "${CONTAINER_USER}" -g "${CONTAINER_USER}" -m 0700 "${CONTROL_DIR}"

info "Preparing service data directories under /opt..."
sudo install -d -o "${CONTAINER_USER}" -g "${CONTAINER_USER}" -m 0755 \
    "/opt/npm/data" \
    "/opt/npm/data/logs" \
    "/opt/npm/letsencrypt" \
    "/opt/openappsec/localconfig" \
    "/opt/openappsec/conf" \
    "/opt/openappsec/data" \
    "/opt/openappsec/logs" \
    "/opt/crowdsec/data" \
    "/opt/crowdsec/acquis.d"

info "Downloading the compose and CrowdSec assets..."
COMPOSE_TMP="$(mktemp /tmp/npm-open-appsec-compose.XXXXXX)"
fetch_file "${REMOTE_COMPOSE_URL}" "${COMPOSE_TMP}"
install_for_container_user "${COMPOSE_TMP}" "${CONTROL_DIR}/docker-compose.yml" 0644
rm -f "${COMPOSE_TMP}"
if [ ! -s "/opt/crowdsec/acquis.d/npm-open-appsec.yaml" ]; then
    CROWDSEC_TMP="$(mktemp /tmp/npm-open-appsec-crowdsec.XXXXXX)"
    fetch_file "${REMOTE_CROWDSEC_URL}" "${CROWDSEC_TMP}"
    install_for_container_user "${CROWDSEC_TMP}" "/opt/crowdsec/acquis.d/npm-open-appsec.yaml" 0644
    rm -f "${CROWDSEC_TMP}"
fi

if [[ "${ADVANCED_MODEL_SOURCE}" =~ ^https?:// ]]; then
    info "Downloading advanced model archive..."
    if [ ! -s "/opt/openappsec/open-appsec-advanced-model.tgz" ] || [ "${ADVANCED_MODEL_SOURCE}" != "${PREVIOUS_ADVANCED_MODEL_SOURCE}" ]; then
        MODEL_TMP="$(mktemp /tmp/open-appsec-advanced-model.XXXXXX)"
        fetch_file "${ADVANCED_MODEL_SOURCE}" "${MODEL_TMP}"
        install_for_container_user "${MODEL_TMP}" "/opt/openappsec/open-appsec-advanced-model.tgz" 0644
        rm -f "${MODEL_TMP}"
    fi
else
    [ -f "${ADVANCED_MODEL_SOURCE}" ] || die "Advanced model file not found: ${ADVANCED_MODEL_SOURCE}"
    if ! cmp -s "${ADVANCED_MODEL_SOURCE}" "/opt/openappsec/open-appsec-advanced-model.tgz" 2>/dev/null; then
        install_for_container_user "${ADVANCED_MODEL_SOURCE}" "/opt/openappsec/open-appsec-advanced-model.tgz" 0644
    fi
fi

info "Writing compose environment file..."
ENV_TMP="$(mktemp /tmp/npm-open-appsec-env.XXXXXX)"
{
    write_env_var IMAGE_REPOSITORY "${IMAGE_REPOSITORY}"
    write_env_var NPM_IMAGE_TAG "${NPM_IMAGE_TAG}"
    write_env_var PUID "${PUID}"
    write_env_var PGID "${PGID}"
    write_env_var TZ "${TZ_NAME}"
    write_env_var NPM_HTTP_PORT "${NPM_HTTP_PORT}"
    write_env_var NPM_ADMIN_PORT "${NPM_ADMIN_PORT}"
    write_env_var NPM_HTTPS_PORT "${NPM_HTTPS_PORT}"
    write_env_var APPSEC_AGENT_TOKEN "${APPSEC_AGENT_TOKEN}"
    write_env_var APPSEC_USER_EMAIL "${APPSEC_USER_EMAIL}"
    write_env_var APPSEC_AUTO_POLICY_LOAD "true"
    write_env_var CROWDSEC_ENABLED "${ENABLE_CROWDSEC}"
    write_env_var CROWDSEC_APPSEC_URL "crowdsec:7422"
    write_env_var CROWDSEC_ENROLL_KEY "${CROWDSEC_ENROLL_KEY}"
    write_env_var CROWDSEC_ENROLL_INSTANCE_NAME "${CROWDSEC_ENROLL_INSTANCE_NAME}"
    write_env_var COMPOSE_PROFILES "${COMPOSE_PROFILES}"
    write_env_var ADVANCED_MODEL_SOURCE "${ADVANCED_MODEL_SOURCE}"
} >"${ENV_TMP}"
if ! sudo test -f "${CONTROL_DIR}/.env" || ! sudo cmp -s "${CONTROL_DIR}/.env" "${ENV_TMP}" 2>/dev/null; then
    install_for_container_user "${ENV_TMP}" "${CONTROL_DIR}/.env" 0600
else
    rm -f "${ENV_TMP}"
fi
rm -f "${ENV_TMP}"

COMPOSE_EXEC="$(detect_compose_exec)" || die "Podman compose support was not found."
UNIT_PATH="/home/${CONTAINER_USER}/.config/systemd/user/npm-open-appsec.service"
sudo install -d -o "${CONTAINER_USER}" -g "${CONTAINER_USER}" -m 0700 "/home/${CONTAINER_USER}/.config/systemd/user"
info "Creating user service at ${UNIT_PATH}..."
UNIT_TMP="$(mktemp /tmp/npm-open-appsec-systemd.XXXXXX)"
cat >"${UNIT_TMP}" <<EOF
[Unit]
Description=NPM open-appsec cloud-managed deployment (Rocky/RHEL 10, rootless Podman)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${CONTROL_DIR}
ExecStart=${COMPOSE_EXEC} ${COMPOSE_PROFILE_ARG:+${COMPOSE_PROFILE_ARG} }--env-file .env -f docker-compose.yml up -d --remove-orphans
ExecStop=-${COMPOSE_EXEC} ${COMPOSE_PROFILE_ARG:+${COMPOSE_PROFILE_ARG} }--env-file .env -f docker-compose.yml down --remove-orphans
TimeoutStartSec=0
TimeoutStopSec=0

[Install]
WantedBy=default.target
EOF
install_text_for_container_user "${UNIT_TMP}" "${UNIT_PATH}" 0644
rm -f "${UNIT_TMP}"
sudo restorecon -F "${UNIT_PATH}" >/dev/null 2>&1 || true
sudo -u "${CONTAINER_USER}" -H sh -lc "export HOME=\"/home/${CONTAINER_USER}\"; export XDG_RUNTIME_DIR=\"/run/user/${PUID}\"; export DBUS_SESSION_BUS_ADDRESS=\"unix:path=/run/user/${PUID}/bus\"; cd \"\$HOME\" && systemctl --user daemon-reload && systemctl --user reset-failed npm-open-appsec.service >/dev/null 2>&1 || true"

info "Starting the service..."
info "Cleaning up any previous deployment..."
timeout 30s sudo -u "${CONTAINER_USER}" -H sh -lc "export HOME=\"/home/${CONTAINER_USER}\"; export XDG_RUNTIME_DIR=\"/run/user/${PUID}\"; export DBUS_SESSION_BUS_ADDRESS=\"unix:path=/run/user/${PUID}/bus\"; cd \"\$HOME\" && systemctl --user stop npm-open-appsec.service >/dev/null 2>&1 || true" || true
timeout 30s sudo -u "${CONTAINER_USER}" -H sh -lc "export HOME=\"/home/${CONTAINER_USER}\"; export XDG_RUNTIME_DIR=\"/run/user/${PUID}\"; export DOCKER_HOST=\"unix:///run/user/${PUID}/docker.sock\"; cd \"${CONTROL_DIR}\" && ${COMPOSE_EXEC} --env-file .env -f docker-compose.yml down --remove-orphans >/dev/null 2>&1 || true" || true
timeout 30s sudo -u "${CONTAINER_USER}" -H sh -lc "export HOME=\"/home/${CONTAINER_USER}\"; export XDG_RUNTIME_DIR=\"/run/user/${PUID}\"; export DOCKER_HOST=\"unix:///run/user/${PUID}/docker.sock\"; cd \"\$HOME\" && podman rm -f npm-open-appsec crowdsec >/dev/null 2>&1 || true" || true
if sudo -u "${CONTAINER_USER}" -H sh -lc "export HOME=\"/home/${CONTAINER_USER}\"; export XDG_RUNTIME_DIR=\"/run/user/${PUID}\"; export DOCKER_HOST=\"unix:///run/user/${PUID}/docker.sock\"; cd \"\$HOME\" && podman ps -a --format '{{.Names}}'" | grep -Eq '^(npm-open-appsec|crowdsec)$'; then
    die "Previous containers are still present after cleanup. Remove them manually with podman rm -f npm-open-appsec crowdsec, then rerun the script."
fi
sudo install -d -o "${CONTAINER_USER}" -g "${CONTAINER_USER}" -m 0755 "/home/${CONTAINER_USER}/.config/systemd/user/default.target.wants"
sudo -u "${CONTAINER_USER}" -H sh -lc "export HOME=\"/home/${CONTAINER_USER}\"; cd \"\$HOME\" && ln -sfn \"../npm-open-appsec.service\" \".config/systemd/user/default.target.wants/npm-open-appsec.service\""
if sudo -u "${CONTAINER_USER}" -H sh -lc "export HOME=\"/home/${CONTAINER_USER}\"; export XDG_RUNTIME_DIR=\"/run/user/${PUID}\"; export DBUS_SESSION_BUS_ADDRESS=\"unix:path=/run/user/${PUID}/bus\"; cd \"\$HOME\" && systemctl --user is-active --quiet npm-open-appsec.service"; then
    sudo -u "${CONTAINER_USER}" -H sh -lc "export HOME=\"/home/${CONTAINER_USER}\"; export XDG_RUNTIME_DIR=\"/run/user/${PUID}\"; export DBUS_SESSION_BUS_ADDRESS=\"unix:path=/run/user/${PUID}/bus\"; cd \"\$HOME\" && systemctl --user restart npm-open-appsec.service"
else
    sudo -u "${CONTAINER_USER}" -H sh -lc "export HOME=\"/home/${CONTAINER_USER}\"; export XDG_RUNTIME_DIR=\"/run/user/${PUID}\"; export DBUS_SESSION_BUS_ADDRESS=\"unix:path=/run/user/${PUID}/bus\"; cd \"\$HOME\" && systemctl --user start npm-open-appsec.service"
fi

if [ "${ENABLE_CROWDSEC}" = "true" ]; then
    if ! sudo -u "${CONTAINER_USER}" -H sh -lc "export HOME=\"/home/${CONTAINER_USER}\"; export XDG_RUNTIME_DIR=\"/run/user/${PUID}\"; export DOCKER_HOST=\"unix:///run/user/${PUID}/docker.sock\"; cd \"\$HOME\" && podman ps --format \"{{.Names}}\"" | grep -Fxq crowdsec; then
        sudo -u "${CONTAINER_USER}" -H sh -lc "export HOME=\"/home/${CONTAINER_USER}\"; export XDG_RUNTIME_DIR=\"/run/user/${PUID}\"; export DOCKER_HOST=\"unix:///run/user/${PUID}/docker.sock\"; cd \"\$HOME\" && podman logs crowdsec --tail 50" >/dev/null 2>&1 || true
        die "CrowdSec was enabled, but the crowdsec container did not start. Check the compose logs and the enrollment key."
    fi
fi

info "Done."
info "Control directory: ${CONTROL_DIR}"
info "Service directories: /opt/npm, /opt/openappsec, /opt/crowdsec"
info "To manage later, run systemctl --user as ${CONTAINER_USER} with XDG_RUNTIME_DIR=/run/user/${PUID}."
