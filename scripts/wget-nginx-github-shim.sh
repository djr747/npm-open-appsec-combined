#!/usr/bin/env bash
# wget shim used only during the Docker attachment build stage.
#
# The open-appsec attachment configuration script fetches nginx source with:
#   wget --no-check-certificate https://nginx.org/download/nginx-VERSION.tar.gz
#
# jc21/nginx-proxy-manager is based on OpenResty, which bundles a patched nginx
# whose version matches the VERSION in the URL. This shim:
#   1. Intercepts the nginx.org URL.
#   2. Detects the exact OpenResty release from `nginx -V` (e.g. openresty/1.27.1.2).
#   3. Downloads the matching OpenResty source release from GitHub, which includes
#      the bundled nginx source (with its configure script) at the correct version.
#   4. Repacks the bundled nginx as nginx-VERSION.tar.gz so the attachment script
#      finds exactly what it expects.
# All other wget invocations are passed through unchanged.

set -euo pipefail

url=""
other_args=()

for arg in "$@"; do
    if [[ "$arg" == https://nginx.org/download/nginx-*.tar.gz ]]; then
        url="$arg"
    else
        other_args+=("$arg")
    fi
done

if [ -z "$url" ]; then
    exec /usr/bin/wget "$@"
fi

nginx_ver="${url#*nginx-}"
nginx_ver="${nginx_ver%.tar.gz}"

# Detect whether the installed nginx is OpenResty (as used in jc21/nginx-proxy-manager).
nginx_v="$(nginx -V 2>&1 || true)"
if [[ "$nginx_v" != *"openresty/"* ]]; then
    echo "wget shim: non-OpenResty nginx detected; passing through to nginx.org" >&2
    exec /usr/bin/wget "$@"
fi

openresty_ver="$(echo "$nginx_v" | grep -oP '(?<=openresty/)[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"
gh_url="https://github.com/openresty/openresty/releases/download/v${openresty_ver}/openresty-${openresty_ver}.tar.gz"

echo "wget shim: NPM uses openresty/${openresty_ver} — downloading OpenResty source (nginx ${nginx_ver} bundle) from GitHub" >&2

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

/usr/bin/wget "${other_args[@]}" -O "${tmp}/openresty.tar.gz" "${gh_url}"

# Extract only the bundled nginx directory (avoids unpacking the full OpenResty tree).
tar -xzf "${tmp}/openresty.tar.gz" -C "${tmp}/" \
    "openresty-${openresty_ver}/bundle/nginx-${nginx_ver}"

bundled_nginx="${tmp}/openresty-${openresty_ver}/bundle/nginx-${nginx_ver}"

if [ ! -f "${bundled_nginx}/configure" ]; then
    echo "wget shim: configure script not found in bundled nginx — cannot proceed" >&2
    exit 1
fi

# Repack as nginx-VERSION.tar.gz with nginx-VERSION/ at the root, matching the
# layout that nginx.org tarballs use (the attachment script does mv nginx-VERSION nginx-src).
mv "${bundled_nginx}" "${tmp}/nginx-${nginx_ver}"
tar -czf "nginx-${nginx_ver}.tar.gz" -C "${tmp}" "nginx-${nginx_ver}"
