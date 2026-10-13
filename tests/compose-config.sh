#!/usr/bin/env bash
# Prüft die Compose-Konfiguration, die ./devdock für Workspaces mit und ohne
# Tailscale erzeugt. Startet keinen Container; braucht docker (compose config)
# und jq.
set -euo pipefail

devdock=$(readlink -f "$(dirname "${BASH_SOURCE[0]}")/../devdock")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# Eigenes Config-Verzeichnis: keine .env, Generiertes landet im tmp
export DEVDOCK_CONFIG=$tmp/config
mkdir -p "$DEVDOCK_CONFIG"
fails=0

pass() { echo "ok    $1"; }
fail() { echo "FAIL  $1"; fails=$((fails + 1)); }

# check NAME WORKSPACE JQ-FILTER: Filter muss auf der Konfiguration true ergeben
check() {
  if "$devdock" -w "$2" config --format json 2>/dev/null | jq -e "$3" >/dev/null 2>&1; then
    pass "$1"
  else
    fail "$1"
  fi
}

# rejects NAME WORKSPACE: devdock config muss scheitern
rejects() {
  if "$devdock" -w "$2" config >/dev/null 2>&1; then
    fail "$1"
  else
    pass "$1"
  fi
}

marker() {
  mkdir -p "$1/.devdock"
  printf "$2" > "$1/.devdock/tailscale"
}

plain=$tmp/plain
mkdir -p "$plain"
check "ohne Marker: Host-Netz" "$plain" '.services.dev.network_mode == "host"'
check "ohne Marker: kein Sidecar" "$plain" '.services | has("tailscale") | not'
check "Quellstand als Build-Argument" "$plain" '.services.dev.build.args.SOURCE_HASH | test("^[0-9a-f]{12}$")'

ts=$tmp/ts
marker "$ts" ''
check "Marker: dev im Namespace des Sidecars" "$ts" '.services.dev.network_mode == "service:tailscale"'
check "Marker: NET_ADMIN am Sidecar" "$ts" '.services.tailscale.cap_add | index("NET_ADMIN") != null'
check "Marker: /dev/net/tun am Sidecar" "$ts" '.services.tailscale.devices | tostring | test("/dev/net/tun")'
check "Marker: dev ohne Capabilities" "$ts" '.services.dev.cap_add == null'
check "Marker: Node-Name aus dem Slug" "$ts" '.services.tailscale.environment.TS_HOSTNAME == "devdock-ts"'
check "Marker: Kernel-Modus" "$ts" '.services.tailscale.environment.TS_USERSPACE == "false"'
check "Marker: wartet auf den Login" "$ts" '.services.tailscale.environment.TS_BOOT_TIMEOUT == "8760h"'
check "Marker: Weiterleitung per iptables-nft" "$ts" '.services.tailscale.entrypoint | tostring | test("iptables-nft")'
check "Marker: tailscaled wählt das Firewall-Backend selbst" "$ts" '.services.tailscale.environment.TS_DEBUG_FIREWALL_MODE == "auto"'
check "Marker: route_localnet" "$ts" '.services.tailscale.sysctls["net.ipv4.conf.all.route_localnet"] | tostring == "1"'
check "Marker: kein IPv6" "$ts" '.services.tailscale.sysctls["net.ipv6.conf.all.disable_ipv6"] | tostring == "1"'
check "Default ephemeral: kein State-Verzeichnis" "$ts" '.services.tailscale.environment | has("TS_STATE_DIR") | not'
check "Default ephemeral: kein State-Volume" "$ts" '(.volumes // {}) | has("tailscale-state") | not'
check "Marker: Netzlage im dev-Environment" "$ts" '.services.dev.environment.DEVDOCK_NET == "tailscale"'
check "Marker: Node-Name im dev-Environment" "$ts" '.services.dev.environment.DEVDOCK_TS_HOSTNAME == "devdock-ts"'
check "leerer Marker: keine Ports" "$ts" '.services.tailscale.ports == null'

marker "$ts" '5173\n4700\n'
check "Ports: auf 127.0.0.1 publiziert" "$ts" \
  '[.services.tailscale.ports[] | "\(.host_ip):\(.published):\(.target)"] == ["127.0.0.1:5173:5173","127.0.0.1:4700:4700"]'
check "Ports: Liste im dev-Environment" "$ts" '.services.dev.environment.DEVDOCK_PUBLISHED_PORTS == "5173 4700"'

marker "$ts" '# Kommentar\r\n\r\n8080 # Dev-Server\r\n'
check "Marker mit Kommentar, Leerzeile, CRLF" "$ts" '.services.dev.environment.DEVDOCK_PUBLISHED_PORTS == "8080"'

marker "$ts" 'persistent\n5173\n'
check "persistent: State-Verzeichnis" "$ts" '.services.tailscale.environment.TS_STATE_DIR == "/var/lib/tailscale"'
check "persistent: State-Volume eingebunden" "$ts" \
  '(.volumes | has("tailscale-state")) and ([.services.tailscale.volumes[] | select(.source == "tailscale-state")] | length == 1)'
check "persistent: Ports bleiben Ports" "$ts" '.services.dev.environment.DEVDOCK_PUBLISHED_PORTS == "5173"'

marker "$ts" 'abc\n'
rejects "Marker mit Wort wird abgelehnt" "$ts"
marker "$ts" '08\n'
rejects "Marker mit führender Null wird abgelehnt" "$ts"
marker "$ts" '99999\n'
rejects "Marker mit Port über 65535 wird abgelehnt" "$ts"

# says NAME MUSTER CMD...: die Ausgabe von CMD enthält MUSTER, der Exit-Code
# zählt nicht (unter pipefail färbte er eine Pipe in grep rot)
says() {
  local name=$1 pattern=$2 out
  shift 2
  out=$("$@" 2>&1 || true)
  if grep -q "$pattern" <<<"$out"; then pass "$name"; else fail "$name"; fi
}

# ok_if NAME CMD...: CMD muss gelingen; fails_if: CMD muss scheitern
ok_if() {
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi
}
fails_if() {
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then fail "$name"; else pass "$name"; fi
}

fresh=$tmp/fresh
mkdir -p "$fresh"
fails_if "Durchreiche ohne Marker scheitert" "$devdock" -w "$fresh" tailscale status
fails_if "on mit Unsinn scheitert" "$devdock" -w "$fresh" tailscale on 99999
ok_if "on mit Unsinn schreibt keinen Marker" test ! -e "$fresh/.devdock/tailscale"
ok_if "on 5173" "$devdock" -w "$fresh" tailscale on 5173
ok_if "on legt .devdock/.gitignore an" grep -qx '\*' "$fresh/.devdock/.gitignore"
ok_if "on schreibt die Ports" grep -qx 5173 "$fresh/.devdock/tailscale"
ok_if "on ohne Ports" "$devdock" -w "$fresh" tailscale on
ok_if "on ohne Ports lässt die Liste stehen" grep -qx 5173 "$fresh/.devdock/tailscale"
check "on wirkt auf die Konfiguration" "$fresh" '.services.dev.network_mode == "service:tailscale"'
says "Durchreiche ohne laufenden Sidecar erklärt sich" 'Sidecar läuft nicht' \
  "$devdock" -w "$fresh" tailscale status
ok_if "off" "$devdock" -w "$fresh" tailscale off
ok_if "off löscht den Marker" test ! -e "$fresh/.devdock/tailscale"
fails_if "off ohne Marker scheitert" "$devdock" -w "$fresh" tailscale off
check "off wirkt auf die Konfiguration" "$fresh" '.services.dev.network_mode == "host"'

# Modus: ephemeral ist Default, --persistent und --ephemeral schalten, Ports
# und Modus ändern sich unabhängig voneinander
mode=$tmp/mode
mkdir -p "$mode"
ok_if "on ohne Flag" "$devdock" -w "$mode" tailscale on 5173
fails_if "on ohne Flag ist ephemeral" grep -qx persistent "$mode/.devdock/tailscale"
ok_if "on --persistent" "$devdock" -w "$mode" tailscale on --persistent
ok_if "on --persistent schreibt den Modus" grep -qx persistent "$mode/.devdock/tailscale"
ok_if "on --persistent lässt die Ports stehen" grep -qx 5173 "$mode/.devdock/tailscale"
ok_if "on 4700" "$devdock" -w "$mode" tailscale on 4700
ok_if "on PORT lässt den Modus stehen" grep -qx persistent "$mode/.devdock/tailscale"
fails_if "on PORT ersetzt die Ports" grep -qx 5173 "$mode/.devdock/tailscale"
ok_if "on --ephemeral" "$devdock" -w "$mode" tailscale on --ephemeral
fails_if "on --ephemeral entfernt den Modus" grep -qx persistent "$mode/.devdock/tailscale"
ok_if "on --ephemeral lässt die Ports stehen" grep -qx 4700 "$mode/.devdock/tailscale"
fails_if "on mit unbekannter Option scheitert" "$devdock" -w "$mode" tailscale on --sonstwas

# logout und forget ohne Tailnet-Identität: klare Meldung statt docker-Fehler
says "logout ephemeral erklärt sich" 'ephemeral' "$devdock" -w "$mode" tailscale logout
ok_if "on --persistent für logout" "$devdock" -w "$mode" tailscale on --persistent
says "logout ohne State-Volume erklärt sich" 'keine Tailnet-Identität' "$devdock" -w "$mode" tailscale logout
says "forget ohne State-Volume erklärt sich" 'keine Tailnet-Identität' "$devdock" -w "$mode" tailscale forget

# Ein kaputter Marker darf die Kommandos nicht sperren, die ihn reparieren
broken=$tmp/broken
marker "$broken" '08\n'
ok_if "kaputter Marker: off geht trotzdem" "$devdock" -w "$broken" tailscale off
marker "$broken" '08\n'
ok_if "kaputter Marker: on PORT schreibt neu" "$devdock" -w "$broken" tailscale on 5173
ok_if "kaputter Marker: Liste ersetzt" grep -qx 5173 "$broken/.devdock/tailscale"
marker "$broken" '08\n'
ok_if "kaputter Marker: down geht trotzdem" "$devdock" -w "$broken" down

# Der Auth-Key aus .env ist für den Sidecar, nicht für jeden Prozess in dev
keyed=$tmp/keyed
marker "$keyed" ''
printf 'TS_AUTHKEY=tskey-test\n' > "$DEVDOCK_CONFIG/.env"
check "Auth-Key erreicht den Sidecar" "$keyed" '.services.tailscale.environment.TS_AUTHKEY == "tskey-test"'
check "Auth-Key bleibt aus dev heraus" "$keyed" '(.services.dev.environment.TS_AUTHKEY // "") == ""'
check "Auth-Key bleibt aus dev im Host-Netz heraus" "$plain" '(.services.dev.environment.TS_AUTHKEY // "") == ""'
rm "$DEVDOCK_CONFIG/.env"

# Hostnamen dürfen höchstens 63 Zeichen haben, sonst startet der Sidecar nicht
long=$tmp/$(printf 'a%.0s' {1..70})
marker "$long" ''
check "langer Workspace-Name: Hostnamen kurz genug" "$long" \
  '(.services.tailscale.hostname | length) <= 63 and (.services.tailscale.environment.TS_HOSTNAME | length) <= 63'

((fails == 0)) || { echo "$fails Prüfung(en) gescheitert"; exit 1; }
echo "alle Prüfungen bestanden"
