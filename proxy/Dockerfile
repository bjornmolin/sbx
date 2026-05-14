FROM alpine:3.20

# sniproxy reads the TLS SNI extension and forwards to allowlisted hosts
# without terminating TLS (no custom CA needed in the sandbox).
# dnsmasq is the captive resolver: it returns the proxy's own IP for every
# A query, so any hostname the sandbox tries to reach lands on sniproxy.
RUN apk add --no-cache sniproxy dnsmasq bash tini ca-certificates iproute2

COPY dnsmasq.conf       /etc/dnsmasq.conf
COPY sniproxy.conf.tmpl /etc/sniproxy.conf.tmpl
COPY render-config.sh   /usr/local/bin/render-config.sh
COPY entrypoint.sh      /usr/local/bin/entrypoint.sh

# Allowlist files (baseline + optional project-local) are bind-mounted at
# run time into /etc/sbx/. The image itself is project-agnostic and shared.
RUN mkdir -p /etc/sbx \
 && chmod +x /usr/local/bin/render-config.sh /usr/local/bin/entrypoint.sh

EXPOSE 53/udp 443/tcp

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
