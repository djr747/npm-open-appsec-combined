ARG NPM_TAG=latest
ARG CERT_PRUNE_VERSION=v0.0.0-20230515051954-ab01c6e0bab5

FROM golang:1.26-bookworm AS cert-prune-builder
ARG CERT_PRUNE_VERSION
ENV CGO_ENABLED=0
RUN go install github.com/axllent/cert-prune@${CERT_PRUNE_VERSION}

FROM jc21/nginx-proxy-manager:${NPM_TAG} AS attachment-builder

ARG ATTACHMENT_REF=main

RUN DEBIAN_FRONTEND=noninteractive apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends -o Dpkg::Options::="--force-confold" \
        build-essential \
        ca-certificates \
        cmake \
        dos2unix \
        git \
        libbrotli-dev \
        libmaxminddb-dev \
        libpcre3-dev \
        libssl-dev \
        libxml2-dev \
        pkg-config \
        wget \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

RUN git clone https://github.com/openappsec/attachment.git /tmp/attachment \
    && cd /tmp/attachment \
    && git checkout "${ATTACHMENT_REF}" \
    && git rev-parse HEAD > /tmp/attachment-commit

# Install a wget shim so the attachment configuration script fetches nginx source
# from the OpenResty GitHub release (https://github.com/openresty/openresty) instead
# of nginx.org, which may be unreachable in some CI environments. The shim extracts
# the bundled nginx source (matching the version running in the NPM container) and
# repacks it in the layout that the attachment script expects. /usr/local/bin takes
# PATH priority over /usr/bin.
COPY scripts/wget-nginx-github-shim.sh /usr/local/bin/wget
RUN chmod +x /usr/local/bin/wget

RUN nginx -V &> /tmp/nginx.ver \
    && cd /tmp/attachment \
    && ./attachments/nginx/ngx_module/nginx_version_configuration.sh --conf /tmp/nginx.ver /tmp/build_out \
    && cmake -DCMAKE_INSTALL_PREFIX=/tmp/build_out . \
    && make -j"$(nproc)" install

FROM debian:bookworm-slim AS appsec-installers

ARG OPENAPPSEC_REF=main

RUN DEBIAN_FRONTEND=noninteractive apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        cmake \
        git \
        libboost-all-dev \
        libbrotli-dev \
        libcurl4-openssl-dev \
        libgmock-dev \
        libgtest-dev \
        libhiredis-dev \
        libmaxminddb-dev \
        libpcre2-dev \
        libssl-dev \
        libxml2-dev \
        pkg-config \
        python3 \
        redis-server \
        yq \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

RUN git clone https://github.com/openappsec/openappsec.git /tmp/openappsec \
    && cd /tmp/openappsec \
    && git checkout "${OPENAPPSEC_REF}" \
    && git rev-parse HEAD > /tmp/openappsec-commit \
    && cmake -DCMAKE_INSTALL_PREFIX=/tmp/openappsec-build . \
    && make -j"$(nproc)" install \
    && make -j"$(nproc)" package

RUN mkdir -p /nano-service-installers \
    && cp /tmp/openappsec-build/install-cp-nano-agent.sh /nano-service-installers/ \
    && cp /tmp/openappsec-build/install-cp-nano-attachment-registration-manager.sh /nano-service-installers/ \
    && cp /tmp/openappsec-build/install-cp-nano-agent-cache.sh /nano-service-installers/ \
    && cp /tmp/openappsec-build/install-cp-nano-service-http-transaction-handler.sh /nano-service-installers/

FROM jc21/nginx-proxy-manager:${NPM_TAG}

# Apply all available security patches from the Debian 12 repository.
# `apt-get -y upgrade` upgrades every installed package to the latest version
# provided by the upstream repos, closing any CVEs that have been fixed there.
# `jq` is intentionally purged because it is not needed at runtime in this image
# and removing it reduces attack surface and package CVE exposure.
# Vulnerabilities that remain after this step have no available fix yet in
# Debian 12 and will be resolved by the nightly rebuild once a fix is released.
RUN DEBIAN_FRONTEND=noninteractive apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get -y upgrade -o Dpkg::Options::="--force-confold" \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        -o Dpkg::Options::="--force-confold" \
        libicu72 \
        procps \
    && DEBIAN_FRONTEND=noninteractive apt-get purge -y --auto-remove jq \
    && rm -rf /tmp/openresty \
    && cd /app \
    && npm install --omit=dev --no-audit --no-fund basic-ftp@5.3.0 \
    && /opt/certbot/bin/pip install --no-cache-dir --upgrade "multipart>=1.3.1" \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /usr/lib/nginx/modules /ext/appsec /etc/cp/conf /etc/cp/data /var/log/nano_agent /dev/shm/check-point \
    && grep -q '"\/etc\/nginx\/conf.d"' /etc/s6-overlay/s6-rc.d/prepare/30-ownership.sh \
    && sed -i '/"\/etc\/nginx\/conf.d"/a\ \t"\/ext\/appsec"\
\t"\/etc\/cp\/conf"\
\t"\/etc\/cp\/data"\
\t"\/var\/log\/nano_agent"' /etc/s6-overlay/s6-rc.d/prepare/30-ownership.sh \
    && grep -q '"\/ext\/appsec"' /etc/s6-overlay/s6-rc.d/prepare/30-ownership.sh \
    && grep -q '"\/etc\/cp\/conf"' /etc/s6-overlay/s6-rc.d/prepare/30-ownership.sh \
    && grep -q '"\/etc\/cp\/data"' /etc/s6-overlay/s6-rc.d/prepare/30-ownership.sh \
    && grep -q '"\/var\/log\/nano_agent"' /etc/s6-overlay/s6-rc.d/prepare/30-ownership.sh

COPY --from=attachment-builder /tmp/build_out/lib/libngx_module.so /usr/lib/nginx/modules/libngx_module.so
COPY --from=attachment-builder /tmp/build_out/lib/libosrc_nginx_attachment_util.so /usr/lib/libosrc_nginx_attachment_util.so
COPY --from=attachment-builder /tmp/build_out/lib/libosrc_compression_utils.so /usr/lib/libosrc_compression_utils.so
COPY --from=attachment-builder /tmp/build_out/lib/libosrc_shmem_ipc.so /usr/lib/libosrc_shmem_ipc.so
COPY --from=attachment-builder /tmp/attachment-commit /etc/openappsec-attachment.commit
COPY --from=appsec-installers /nano-service-installers /nano-service-installers
COPY --from=appsec-installers /tmp/openappsec-commit /etc/openappsec-core.commit
COPY --from=cert-prune-builder /go/bin/cert-prune /usr/bin/cert-prune
COPY scripts/start-openappsec-agent.sh /usr/local/bin/start-openappsec-agent

RUN grep -q '^include /etc/nginx/modules/\*\.conf;$' /etc/nginx/nginx.conf \
    || (echo "Expected '/etc/nginx/modules/*.conf' include missing in nginx.conf; this directive is required to load dynamic modules like open-appsec. If missing, check whether the selected NPM_TAG changed nginx.conf structure or pin NPM_TAG to a known working release." >&2; exit 1)
RUN grep -q "load_module /usr/lib/nginx/modules/libngx_module.so;" /etc/nginx/nginx.conf \
    || sed -i '/include \/etc\/nginx\/modules\/\*\.conf/a\load_module /usr/lib/nginx/modules/libngx_module.so;' /etc/nginx/nginx.conf
RUN grep -q "load_module /usr/lib/nginx/modules/libngx_module.so;" /etc/nginx/nginx.conf
RUN chmod +x /usr/local/bin/start-openappsec-agent /nano-service-installers/*.sh

RUN mkdir -p /etc/s6-overlay/s6-rc.d/appsec-agent/dependencies.d \
    && printf "longrun\n" > /etc/s6-overlay/s6-rc.d/appsec-agent/type \
    && printf "#!/command/with-contenv bash\nset -e\nexec /usr/local/bin/start-openappsec-agent\n" > /etc/s6-overlay/s6-rc.d/appsec-agent/run \
    && chmod +x /etc/s6-overlay/s6-rc.d/appsec-agent/run \
    && touch /etc/s6-overlay/s6-rc.d/appsec-agent/dependencies.d/prepare \
    && touch /etc/s6-overlay/s6-rc.d/nginx/dependencies.d/appsec-agent \
    && touch /etc/s6-overlay/s6-rc.d/user/contents.d/appsec-agent

ENV registered_server=NGINX \
    nginxproxymanager=true

VOLUME ["/data", "/etc/letsencrypt", "/ext/appsec", "/etc/cp/conf", "/etc/cp/data", "/var/log/nano_agent"]
