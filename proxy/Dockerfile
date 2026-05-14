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

# Allowlist is baked into the image at build time. The wrapper assembles a
# build context that always contains both files (the local one may be empty)
# so this COPY never fails. Edit allowlist.conf / allowlist.local.conf on the
# host and run `sbx build-proxy` to apply.
COPY allowlist.conf       /etc/sbx/allowlist.conf
COPY allowlist.local.conf /etc/sbx/allowlist.local.conf

RUN chmod +x /usr/local/bin/render-config.sh /usr/local/bin/entrypoint.sh

EXPOSE 53/udp 443/tcp

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
