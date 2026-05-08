ARG NPM_TAG=latest

FROM jc21/nginx-proxy-manager:${NPM_TAG} AS attachment-builder

ARG ATTACHMENT_REF=main

RUN DEBIAN_FRONTEND=noninteractive apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends -o Dpkg::Options::="--force-confold" \
        build-essential \
        ca-certificates \
        cmake \
        git \
        libmaxminddb-dev \
        libpcre3-dev \
        libssl-dev \
        libxml2-dev \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

RUN git clone https://github.com/openappsec/attachment.git /tmp/attachment \
    && cd /tmp/attachment \
    && git checkout "${ATTACHMENT_REF}" \
    && git rev-parse HEAD > /tmp/attachment-commit

RUN nginx -V &> /tmp/nginx.ver \
    && cd /tmp/attachment \
    && ./attachments/nginx/ngx_module/nginx_version_configuration.sh --conf /tmp/nginx.ver /tmp/build_out \
    && cmake -DCMAKE_INSTALL_PREFIX=/tmp/build_out . \
    && make -j"$(nproc)" install

FROM jc21/nginx-proxy-manager:${NPM_TAG}

ARG ATTACHMENT_REF=main

RUN DEBIAN_FRONTEND=noninteractive apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get -y upgrade -o Dpkg::Options::="--force-confold" \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /usr/lib/nginx/modules /ext/appsec /ext/appsec-logs /etc/cp/conf /etc/cp/data

COPY --from=attachment-builder /tmp/build_out/lib/libngx_module.so /usr/lib/nginx/modules/libngx_module.so
COPY --from=attachment-builder /tmp/build_out/lib/libosrc_nginx_attachment_util.so /usr/lib/libosrc_nginx_attachment_util.so
COPY --from=attachment-builder /tmp/build_out/lib/libosrc_compression_utils.so /usr/lib/libosrc_compression_utils.so
COPY --from=attachment-builder /tmp/build_out/lib/libosrc_shmem_ipc.so /usr/lib/libosrc_shmem_ipc.so
COPY --from=attachment-builder /tmp/attachment-commit /etc/openappsec-attachment.commit

RUN grep -q "load_module /usr/lib/nginx/modules/libngx_module.so;" /etc/nginx/nginx.conf \
    || sed -i '/include \/etc\/nginx\/modules\/\*\.conf/a\load_module /usr/lib/nginx/modules/libngx_module.so;' /etc/nginx/nginx.conf

RUN grep -q "^tcp_worker_processes" /etc/nginx/nginx.conf \
    || sed -i '/http {/a\\tcp_worker_processes           auto;' /etc/nginx/nginx.conf

VOLUME ["/data", "/etc/letsencrypt", "/ext/appsec", "/ext/appsec-logs", "/etc/cp/conf", "/etc/cp/data"]
