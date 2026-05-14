#!/usr/bin/env bash
# Render /etc/sniproxy.conf and /etc/dnsmasq.runtime.conf at container start.
# - Reads the allowlist from /etc/sbx/allowlist.conf (bind-mounted).
# - Substitutes the proxy's own container IP into the dnsmasq config.
# - Expands "*.example.com" into an any-depth subdomain regex for sniproxy.

set -euo pipefail

ALLOWLIST="${ALLOWLIST:-/etc/sbx/allowlist.conf}"
ALLOWLIST_LOCAL="${ALLOWLIST_LOCAL:-/etc/sbx/allowlist.local.conf}"
SNI_TMPL="/etc/sniproxy.conf.tmpl"
SNI_OUT="/etc/sniproxy.conf"
DNS_TMPL="/etc/dnsmasq.conf"
DNS_OUT="/etc/dnsmasq.runtime.conf"
TABLE_TMP="/tmp/sniproxy.table"

if [[ ! -f "$ALLOWLIST" ]]; then
  echo "render-config: missing allowlist at $ALLOWLIST" >&2
  exit 1
fi

# Sources are appended in order; later entries simply add more rules. There is
# no precedence between them because sniproxy stops at the first matching row.
sources=("$ALLOWLIST")
[[ -f "$ALLOWLIST_LOCAL" ]] && sources+=("$ALLOWLIST_LOCAL")

# Proxy IP advertised to sandbox containers. The proxy is dual-homed (an
# internal --internal network for the sandbox, plus an external bridge for
# outbound). The internal interface is the one WITHOUT a default route, so
# we discover it by elimination — no INTERNAL_CIDR env var required.
default_iface="$(ip -4 route show default | awk '{print $5; exit}')"
PROXY_IP="$(
  ip -4 -o addr show |
  awk -v def="$default_iface" '
    $2 != "lo" && $2 != def && $4 ~ /^(10|172|192)\./ {
      sub(/\/.*/, "", $4); print $4; exit
    }
  '
)"
[[ -n "$PROXY_IP" ]] || { echo "render-config: could not detect internal interface" >&2; exit 1; }

# Render dnsmasq.
sed "s|__PROXY_IP__|${PROXY_IP}|g" "$DNS_TMPL" > "$DNS_OUT"

# Build the sniproxy table into a temp file (line-by-line, no awk -v which
# would re-process backslash escapes and silently un-escape \. into .).
: > "$TABLE_TMP"
count=0
for src in "${sources[@]}"; do
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    line="${raw%%#*}"
    line="$(printf '%s' "$line" | tr -d '[:space:]')"
    [[ -z "$line" ]] && continue

    if [[ "$line" == \*.* ]]; then
      rest="${line#\*.}"
      escaped="${rest//./\\.}"
      # match any-depth subdomain (does NOT match the bare apex).
      pattern="^.+\\.${escaped}\$"
    else
      escaped="${line//./\\.}"
      pattern="^${escaped}\$"
    fi
    printf '    %s *\n' "$pattern" >> "$TABLE_TMP"
    count=$((count + 1))
  done < "$src"
done

if (( count == 0 )); then
  echo "render-config: allowlist is empty; refusing to start with no rules" >&2
  exit 1
fi

# Substitute the marker line with the file contents — sed's `r` command reads
# the table verbatim, so backslashes survive unmodified.
sed -e "/__ALLOWLIST_TABLE__/{r ${TABLE_TMP}" -e 'd;}' "$SNI_TMPL" > "$SNI_OUT"

rm -f "$TABLE_TMP"
echo "render-config: proxy ip $PROXY_IP, allowlist rules: $count (sources: ${sources[*]})"
