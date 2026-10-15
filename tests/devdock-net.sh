#!/usr/bin/env bash
# Prüft bin/devdock-net. Läuft auf dem Host und startet sich selbst in einem
# Wegwerf-Container aus devdock:latest (Bridge-Netz, Repo per Bind-Mount, also
# ohne Rebuild).
set -euo pipefail

if [[ ${1:-} != --inside ]]; then
  repo=$(readlink -f "$(dirname "${BASH_SOURCE[0]}")/..")
  exec docker run --rm -v "$repo:/repo:ro" --entrypoint bash devdock:latest \
    /repo/tests/devdock-net.sh --inside
fi

net=/repo/bin/devdock-net
fails=0

expect() {
  if [[ $3 == "$2" ]]; then
    echo "ok    $1"
  else
    echo "FAIL  $1: '$3' statt '$2'"
    fails=$((fails + 1))
  fi
}

# expect_line NAME PORT MUSTER: die Zeile für PORT in $out passt auf MUSTER
expect_line() {
  local line
  line=$(grep -F ":$2 " <<<"$out" || true)
  # shellcheck disable=SC2053 # MUSTER ist bewusst ein Glob
  if [[ -n $line && $line == $3 ]]; then
    echo "ok    $1"
  else
    echo "FAIL  $1: '$line'"
    fails=$((fails + 1))
  fi
}

bridge=$(ip -4 -o addr show eth0 | awk '{print $4; exit}')
bridge=${bridge%/*}

expect "url im Host-Netz" "http://localhost:4700" "$(env -u DEVDOCK_NET "$net" url 4700)"
expect "url im Tailscale-Workspace" "http://$bridge:4700" "$(DEVDOCK_NET=tailscale "$net" url 4700)"
expect "url für publizierten Port" "http://localhost:5173" \
  "$(DEVDOCK_NET=tailscale DEVDOCK_PUBLISHED_PORTS='4700 5173' "$net" url 5173)"
expect "url: Teilstring ist kein publizierter Port" "http://$bridge:517" \
  "$(DEVDOCK_NET=tailscale DEVDOCK_PUBLISHED_PORTS='5173' "$net" url 517)"
expect "motd im Host-Netz leer" "" "$(env -u DEVDOCK_NET "$net" motd)"
expect "url in der Offline-Sandbox" "http://localhost:4700" "$(DEVDOCK_NET=offline "$net" url 4700)"
expect "motd in der Offline-Sandbox" \
  "Offline-Sandbox: kein Netz außer localhost, ohne docker und SSH-Agent; der Host erreicht hier nichts" \
  "$(DEVDOCK_NET=offline "$net" motd)"
expect "motd ohne tailscale0" \
  "Tailscale: devdock-x (nicht verbunden, auf dem Host: devdock tailscale login) · von außen: $bridge" \
  "$(DEVDOCK_NET=tailscale DEVDOCK_TS_HOSTNAME=devdock-x "$net" motd)"

python3 -m http.server --bind 127.0.0.1 8101 >/dev/null 2>&1 &
python3 -m http.server --bind 0.0.0.0 8102 >/dev/null 2>&1 &
want=2
if ip -6 addr show lo 2>/dev/null | grep -q '::1/'; then
  python3 -m http.server --bind ::1 8103 >/dev/null 2>&1 &
  want=3
fi
for _ in $(seq 50); do
  (($(ss -Hltn | grep -cE ':810[123] ') >= want)) && break
  sleep 0.1
done

out=$(DEVDOCK_NET=tailscale DEVDOCK_WORKSPACE=/ws DEVDOCK_TS_HOSTNAME=devdock-x "$net" ports)
expect "ports: Kopfzeile Tailscale" "/ws  tailscale  devdock-x  $bridge" "$(head -n1 <<<"$out")"
expect_line "ports: 127.0.0.1 über die Weiterleitung" 8101 "  http://$bridge:8101 *python3"
expect_line "ports: 0.0.0.0" 8102 "  http://$bridge:8102 *python3"
if ((want == 3)); then
  expect_line "ports: nur [::1] wird markiert" 8103 "*python3*von außen nicht erreichbar*"
else
  echo "skip  ports: [::1] (kein IPv6-Loopback im Testcontainer)"
fi

out=$(env -u DEVDOCK_NET DEVDOCK_WORKSPACE=/ws "$net" ports)
expect "ports: Kopfzeile Host-Netz" "/ws  host" "$(head -n1 <<<"$out")"
expect_line "ports: Host-Netz nimmt localhost" 8101 "  http://localhost:8101 *python3"

out=$(DEVDOCK_NET=offline DEVDOCK_WORKSPACE=/ws "$net" ports)
expect "ports: Kopfzeile Offline-Sandbox" "/ws  offline-sandbox  (nur im Container erreichbar)" "$(head -n1 <<<"$out")"
expect_line "ports: Offline-Sandbox nimmt localhost" 8101 "  http://localhost:8101 *python3"

((fails == 0)) || { echo "$fails Prüfung(en) gescheitert"; exit 1; }
echo "alle Prüfungen bestanden"
