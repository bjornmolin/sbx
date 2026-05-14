#!/usr/bin/env bash
set -euo pipefail

/usr/local/bin/render-config.sh

# dnsmasq runs in the foreground writing to stderr; sniproxy is daemonised
# by default, so we run it with -f to keep it in the foreground and let tini
# reap whichever exits first.
dnsmasq --conf-file=/etc/dnsmasq.runtime.conf --keep-in-foreground --log-facility=- &
DNSMASQ_PID=$!

sniproxy -f -c /etc/sniproxy.conf &
SNIPROXY_PID=$!

# Forward signals; exit when either child exits so the container can be
# restarted cleanly.
term() {
  kill -TERM "$DNSMASQ_PID" "$SNIPROXY_PID" 2>/dev/null || true
}
trap term TERM INT

wait -n "$DNSMASQ_PID" "$SNIPROXY_PID"
exit $?
