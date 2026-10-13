# Tailscale-Sidecar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ein devdock-Workspace kann per `devdock tailscale on` in einen eigenen Netz-Namespace mit Tailscale-Sidecar wechseln und erreicht das Tailnet transparent, ohne dass der Host etwas davon merkt.

**Architecture:** Ein Compose-Overlay `compose.tailscale.yml` startet `tailscale/tailscale:stable` im Kernel-Modus als Sidecar; `dev` teilt dessen Netz-Namespace (`network_mode: service:tailscale`). `./devdock` hängt das Overlay an, wenn `<workspace>/.devdock/tailscale` existiert, und erzeugt aus der darin stehenden Port-Liste ein zweites Overlay mit `127.0.0.1:P:P`-Mappings. Im Container kennt `bin/devdock-net` die Netzlage und liefert URLs, MOTD und die Port-Übersicht, die `devdock ports` auf dem Host einsammelt.

**Tech Stack:** bash, Docker Compose (5.6), offizielles Image `tailscale/tailscale` (containerboot), iptables, iproute2 (`ip`, `ss`), jq (nur Tests, Host).

**Spec:** `docs/superpowers/specs/2026-10-13-tailscale-sidecar-design.md`

## Global Constraints

- Der Host bleibt unberührt: keine Routen, Interfaces oder iptables-Regeln im Host-Namespace; Tailscale läuft ausschließlich im Sidecar.
- Opt-in pro Workspace: Ohne `<workspace>/.devdock/tailscale` bleibt `dev` im Host-Netz (`network_mode: host`), ohne Sidecar.
- Sidecar-Image `tailscale/tailscale:stable`, Kernel-Modus (`TS_USERSPACE=false`), `cap_add: [NET_ADMIN]`, `devices: [/dev/net/tun:/dev/net/tun]` nur am Sidecar.
- Tailnet-State im projekteigenen Volume `tailscale-state` (Docker-Name `<project>_tailscale-state`), nie im Workspace.
- Node-Name `devdock-<slug>`, Slug wie im Compose-Projektnamen (`basename`, klein, `[^a-z0-9]` → `-`).
- Publizierte Ports immer als `127.0.0.1:P:P` am Sidecar.
- Meldungen, Kommentare, README auf Deutsch im Ton des Repos; Commit-Messages englisch wie die bisherigen (`Let …`, `Add …`, `Move …`).
- Shell-Stil wie `devdock` und `ok-autostart`: `set -euo pipefail`, `die`/`note`, erklärender Kommentar über jeder Funktion, keine `cond && cmd` als letzte Anweisung eines Blocks (unter `set -e` liefert das einen Fehlerstatus).
- Commits nur nach Freigabe durch den User (Kürzel `ci`); vor dem ersten Commit einmal fragen, ob pro Task committet werden soll.
- Keine Lastsimulation auf dem Host; Wartezeiten nur als kurze `sleep`-Polls.

## Review Focus

- Ein Dev-Server, der auf `localhost` lauscht, landet je nach Auflösung auf `[::1]`; die Loopback-Weiterleitung deckt nur IPv4 ab. Erwartet: `devdock-net ports` markiert reine `[::1]`-Server als von außen unerreichbar (Test in Task 4), der Spike klärt, wohin Node `localhost` auflöst (Task 1, S6).
- Die Marker-Datei wird von Hand editiert: Kommentare, Leerzeilen, CRLF, `08`, `99999`. Erwartet: Kommentare/Leerzeilen/CRLF werden ignoriert, alles andere bricht mit Dateiname und Wert ab (Tests in Task 2).
- `devdock tailscale status` ohne laufenden Sidecar. Erwartet: verständliche Meldung mit dem nächsten Schritt statt eines Compose-Fehlers (Test in Task 3).
- `devdock tailscale on`/`off` bei laufendem Container. Erwartet: Warnung, dass das nächste `devdock` neu erstellt; nach `off` verschwindet der Sidecar beim nächsten Start (`--remove-orphans`) (Prüfung in Task 7).
- `DEVDOCK_PUBLISHED_PORTS="5173"` und Port `517`. Erwartet: kein Teilstring-Treffer, URL mit Bridge-IP (Test in Task 4).

---

### Task 1: Spike (Wegwerf-Compose, nichts davon bleibt im Repo)

**Files:**
- Create: `<scratchpad>/tailscale-spike/compose.yml` (Scratchpad der Session, nicht im Repo)
- Modify: `docs/superpowers/specs/2026-10-13-tailscale-sidecar-design.md` (Abschnitt „Spike-Ergebnisse“ anhängen)

**Interfaces:**
- Consumes: Image `devdock:latest` (existiert), Auth-Key-Datei vom User (Pfad, nicht Inhalt) oder interaktiver Login.
- Produces: Ergebnisse S1–S6 in der Spec; sie entscheiden die Varianten in Task 2 (Weiterleitung, IPv6) und Task 4 (Markierung).

- [ ] **Step 1: User nach Login-Weg und Testziel fragen**

Fragen: (a) Pfad zu einer Datei mit einem *ephemeral* Auth-Key, oder Login-URL anklicken; (b) eine Tailnet-Maschine samt offenem TCP-Port (z. B. `homeserver`, Port 22) und den Tailnet-Namen (`<tailnet>.ts.net`). Den Key nie ausgeben, nie in Dateien im Repo schreiben.

- [ ] **Step 2: Spike-Compose schreiben**

```yaml
# Wegwerf: prüft Sidecar + geteilten Namespace, bevor devdock es bekommt
services:
  tailscale:
    image: tailscale/tailscale:stable
    cap_add: [NET_ADMIN]
    devices: [/dev/net/tun:/dev/net/tun]
    sysctls:
      net.ipv4.conf.all.route_localnet: 1
    environment:
      TS_USERSPACE: "false"
      TS_STATE_DIR: /var/lib/tailscale
      TS_SOCKET: /var/run/tailscale/tailscaled.sock
      TS_HOSTNAME: devdock-spike
      TS_ACCEPT_DNS: "true"
      TS_AUTHKEY: ${TS_AUTHKEY:-}
    entrypoint:
      - /bin/sh
      - -c
      - |
        iptables -t nat -A PREROUTING -i eth0 -p tcp -j DNAT --to-destination 127.0.0.1 \
          || echo "spike: DNAT-Regel gescheitert" >&2
        exec /usr/local/bin/containerboot
    extra_hosts:
      - host.docker.internal:host-gateway
    ports:
      - "127.0.0.1:47173:5173"
    volumes:
      - state:/var/lib/tailscale
  dev:
    image: devdock:latest
    entrypoint: [sleep, infinity]
    network_mode: service:tailscale
    depends_on: [tailscale]
volumes:
  state: {}
```

- [ ] **Step 3: Starten**

Mit Key: `TS_AUTHKEY="$(cat "$KEYFILE")" docker compose -f "$SPIKE/compose.yml" -p devdock-spike up -d`
Ohne Key: `docker compose -f "$SPIKE/compose.yml" -p devdock-spike up -d`, dann `docker compose -p devdock-spike logs tailscale | grep -oE 'https://[^ ]+/a/[^ ]+'` und dem User die URL zeigen.
Expected: `docker compose -p devdock-spike exec tailscale tailscale status` zeigt die eigene Zeile ohne „Logged out“.

- [ ] **Step 4: S1 – Tailnet aus `dev`**

Run: `docker compose -p devdock-spike exec dev bash -c 'timeout 5 bash -c "</dev/tcp/$0/$1" && echo TCP-OK' <tailnet-ip> <port>`
Expected: `TCP-OK`.

- [ ] **Step 5: S2 – MagicDNS in `dev`**

Run: `docker compose -p devdock-spike exec dev bash -c 'cat /etc/resolv.conf; getent hosts <maschine>; getent hosts <maschine>.<tailnet>.ts.net; getent hosts github.com'`
Expected: `resolv.conf` nennt `100.100.100.100`, alle drei Namen lösen auf. Gegenprobe im Sidecar: `docker compose -p devdock-spike exec tailscale cat /etc/resolv.conf` (gleicher Inhalt = geteilt).

- [ ] **Step 6: S3/S4 – Loopback-Weiterleitung und publizierter Port**

Run:
```bash
docker compose -p devdock-spike exec -d dev python3 -m http.server --bind 127.0.0.1 5173
ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' devdock-spike-tailscale-1)
curl -s -o /dev/null -w '%{http_code}\n' "http://$ip:5173/"
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:47173/
docker compose -p devdock-spike exec tailscale iptables -t nat -S PREROUTING
docker compose -p devdock-spike exec dev curl -s -o /dev/null -w '%{http_code}\n' https://github.com
docker compose -p devdock-spike exec tailscale tailscale status --peers=false
```
Expected: zweimal `200`, die DNAT-Regel steht in der Liste, GitHub antwortet (`200`/`301`), Tailscale weiter verbunden. Danach S1 noch einmal wiederholen (Regel stört WireGuard nicht).

- [ ] **Step 7: S5 – `host.docker.internal` in `dev`**

Run: `docker compose -p devdock-spike exec dev getent hosts host.docker.internal`
Expected: eine Adresse (Gateway der Bridge).

- [ ] **Step 8: S6 – wohin `localhost` in `dev` auflöst**

Run: `docker compose -p devdock-spike exec dev node -e "require('http').createServer().listen(5174,'localhost',function(){console.log(this.address());this.close()})"`
Expected: `address: '127.0.0.1'`. Kommt `'::1'`: im Spike-Compose am Sidecar `net.ipv6.conf.all.disable_ipv6: 1` unter `sysctls` ergänzen, `up -d` (erstellt beide neu), Step 8 und Step 6 wiederholen und festhalten, ob es dann `127.0.0.1` ist und alles andere weiter geht.

- [ ] **Step 9: Ergebnisse in die Spec, aufräumen**

An die Spec anhängen:

```markdown
## Spike-Ergebnisse (YYYY-MM-DD)

| Punkt | Ergebnis | Folge für die Implementierung |
| --- | --- | --- |
| S1 Tailnet aus dev | … | … |
| S2 MagicDNS | … | … |
| S3 Loopback-Weiterleitung | … | … |
| S4 publizierter Port | … | … |
| S5 host.docker.internal | … | … |
| S6 localhost-Auflösung | … | … |
```

(Die `…` füllt der Spike mit den tatsächlichen Ausgaben.) Aufräumen: `docker compose -f "$SPIKE/compose.yml" -p devdock-spike down -v`. War der Key nicht ephemeral: User bitten, `devdock-spike` im Admin-Panel zu entfernen.

**Entscheidungsregeln für die folgenden Tasks:**
- S1 oder S2 gescheitert → STOP, Ergebnis dem User vorlegen; das Design braucht eine Rückfrage (DNS-Plan B), bevor Task 2 beginnt.
- S3 gescheitert → Task 2 ohne `entrypoint`-Wrapper und ohne `sysctls`; Task 4 in der Variante „ohne Weiterleitung“.
- S6 liefert `::1` und `disable_ipv6` hilft → Task 2 ergänzt `net.ipv6.conf.all.disable_ipv6: 1` unter `sysctls`.

- [ ] **Step 10: Commit (nach Freigabe)**

```bash
git add docs/superpowers/specs/2026-10-13-tailscale-sidecar-design.md
git commit -m "Record the Tailscale sidecar spike results in the design"
```

---

### Task 2: Overlay `compose.tailscale.yml` und Verdrahtung in `devdock`

**Files:**
- Create: `compose.tailscale.yml`
- Create: `tests/compose-config.sh`
- Modify: `devdock` (Abschnitt `# --- Compose ---`, nach der Zeile `project="devdock-${slug}-…"`; Funktion `compose_up`)

**Interfaces:**
- Consumes: nichts aus anderen Tasks.
- Produces: `ts_marker` (Pfad), `valid_port PORT` (Status 0/1), `tailscale_ports` (Ports zeilenweise auf stdout, `die` bei Unsinn), exportierte `DEVDOCK_SLUG`, `DEVDOCK_PUBLISHED_PORTS` (durch Leerzeichen getrennt); im Container `DEVDOCK_NET=tailscale`, `DEVDOCK_PUBLISHED_PORTS`, `DEVDOCK_TS_HOSTNAME`. `compose_up` entfernt verwaiste Services.

- [ ] **Step 1: Failing Test schreiben**

`tests/compose-config.sh`:

```bash
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
  if "$devdock" -w "$2" config --format json 2>/dev/null | jq -e "$3" >/dev/null; then
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

ts=$tmp/ts
marker "$ts" ''
check "Marker: dev im Namespace des Sidecars" "$ts" '.services.dev.network_mode == "service:tailscale"'
check "Marker: NET_ADMIN am Sidecar" "$ts" '.services.tailscale.cap_add | index("NET_ADMIN") != null'
check "Marker: /dev/net/tun am Sidecar" "$ts" '.services.tailscale.devices | tostring | test("/dev/net/tun")'
check "Marker: dev ohne Capabilities" "$ts" '.services.dev.cap_add == null'
check "Marker: Node-Name aus dem Slug" "$ts" '.services.tailscale.environment.TS_HOSTNAME == "devdock-ts"'
check "Marker: Kernel-Modus" "$ts" '.services.tailscale.environment.TS_USERSPACE == "false"'
check "Marker: State-Volume" "$ts" '.volumes | has("tailscale-state")'
check "Marker: Netzlage im dev-Environment" "$ts" '.services.dev.environment.DEVDOCK_NET == "tailscale"'
check "Marker: Node-Name im dev-Environment" "$ts" '.services.dev.environment.DEVDOCK_TS_HOSTNAME == "devdock-ts"'
check "leerer Marker: keine Ports" "$ts" '.services.tailscale.ports == null'

marker "$ts" '5173\n4700\n'
check "Ports: auf 127.0.0.1 publiziert" "$ts" \
  '[.services.tailscale.ports[] | "\(.host_ip):\(.published):\(.target)"] == ["127.0.0.1:5173:5173","127.0.0.1:4700:4700"]'
check "Ports: Liste im dev-Environment" "$ts" '.services.dev.environment.DEVDOCK_PUBLISHED_PORTS == "5173 4700"'

marker "$ts" '# Kommentar\r\n\r\n8080 # Dev-Server\r\n'
check "Marker mit Kommentar, Leerzeile, CRLF" "$ts" '.services.dev.environment.DEVDOCK_PUBLISHED_PORTS == "8080"'

marker "$ts" 'abc\n'
rejects "Marker mit Wort wird abgelehnt" "$ts"
marker "$ts" '08\n'
rejects "Marker mit führender Null wird abgelehnt" "$ts"
marker "$ts" '99999\n'
rejects "Marker mit Port über 65535 wird abgelehnt" "$ts"

((fails == 0)) || { echo "$fails Prüfung(en) gescheitert"; exit 1; }
echo "alle Prüfungen bestanden"
```

`chmod +x tests/compose-config.sh`

- [ ] **Step 2: Test laufen lassen, Scheitern prüfen**

Run: `tests/compose-config.sh`
Expected: `ok` für die beiden „ohne Marker“-Zeilen, `FAIL` für alle Marker-Zeilen, Exit 1.

- [ ] **Step 3: `compose.tailscale.yml` anlegen**

```yaml
# Tailscale-Workspace (devdock tailscale on): Der Sidecar hält einen eigenen
# Netz-Namespace samt tailscale0, dev teilt ihn statt des Host-Netzes.
# NET_ADMIN und /dev/net/tun wirken nur in diesem Namespace, der Host bleibt
# unberührt. Publizierte Ports hängt ./devdock als eigenes Overlay an.
services:
  tailscale:
    image: tailscale/tailscale:stable
    hostname: devdock-${DEVDOCK_SLUG}
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    # Erlaubt die Weiterleitung von eth0 auf 127.0.0.1 (Entrypoint unten)
    sysctls:
      net.ipv4.conf.all.route_localnet: 1
    environment:
      TS_USERSPACE: "false"
      TS_STATE_DIR: /var/lib/tailscale
      # Der Default-Pfad des CLI, damit "tailscale …" im Sidecar ohne --socket geht
      TS_SOCKET: /var/run/tailscale/tailscaled.sock
      TS_HOSTNAME: devdock-${DEVDOCK_SLUG}
      TS_ACCEPT_DNS: "true"
      TS_AUTHKEY: ${TS_AUTHKEY:-}
      TS_EXTRA_ARGS: ${TS_EXTRA_ARGS:-}
    # Dev-Server lauschen oft nur auf 127.0.0.1 (Vite, Next, …). Neue
    # TCP-Verbindungen über die Bridge landen deshalb auf dem Loopback;
    # Antworten auf ausgehende Verbindungen, UDP (WireGuard) und tailscale0
    # bleiben unberührt.
    entrypoint:
      - /bin/sh
      - -c
      - |
        iptables -t nat -A PREROUTING -i eth0 -p tcp -j DNAT --to-destination 127.0.0.1 \
          || echo "devdock: Loopback-Weiterleitung nicht gesetzt" >&2
        exec /usr/local/bin/containerboot
    # dev darf im fremden Namespace selbst keine extra_hosts setzen
    extra_hosts:
      - host.docker.internal:host-gateway
    volumes:
      - tailscale-state:/var/lib/tailscale

  dev:
    network_mode: service:tailscale
    depends_on:
      - tailscale
    environment:
      DEVDOCK_NET: tailscale
      DEVDOCK_TS_HOSTNAME: devdock-${DEVDOCK_SLUG}
      DEVDOCK_PUBLISHED_PORTS: ${DEVDOCK_PUBLISHED_PORTS:-}

# Gehört dem Compose-Projekt des Workspaces: <project>_tailscale-state. Bleibt
# bei devdock down stehen und hält die Identität des Nodes.
volumes:
  tailscale-state: {}
```

Varianten nach dem Spike: S3 gescheitert → `sysctls`-Block und `entrypoint`-Block samt Kommentar weglassen. S6 `::1` und `disable_ipv6` hilft → unter `sysctls` zusätzlich `net.ipv6.conf.all.disable_ipv6: 1` mit dem Kommentar `# localhost löst sonst auf [::1] auf, das die Weiterleitung nicht erreicht`.

- [ ] **Step 4: `devdock` verdrahten**

Direkt nach `project="devdock-${slug}-$(printf %s "$workspace" | sha1sum | cut -c1-6)"` einfügen:

```bash
export DEVDOCK_SLUG=$slug

# --- Tailscale ---------------------------------------------------------------
#
# Existiert <workspace>/.devdock/tailscale (devdock tailscale on), läuft dev im
# Netz-Namespace eines Tailscale-Sidecars statt im Host-Netz. Die Datei listet
# die Ports, die auf 127.0.0.1 des Hosts publiziert werden. Compose kann sie
# nicht selbst lesen, deshalb entsteht daraus ein eigenes Overlay.

ts_marker=$workspace/.devdock/tailscale

# Ohne führende Null: bash liest "08" sonst als (ungültige) Oktalzahl
valid_port() {
  [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (($1 <= 65535))
}

# Ports aus der Marker-Datei, einer pro Zeile; # leitet Kommentare ein
tailscale_ports() {
  local line
  [[ -f $ts_marker ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%%#*}
    line=${line//[[:space:]]/}
    [[ -n $line ]] || continue
    valid_port "$line" || die "$ts_marker: '$line' ist kein Port"
    echo "$line"
  done < "$ts_marker"
}

export DEVDOCK_PUBLISHED_PORTS=
if [[ -f $ts_marker ]]; then
  files+=(-f "$here/compose.tailscale.yml")
  ts_ports=$(tailscale_ports)
  DEVDOCK_PUBLISHED_PORTS=${ts_ports//$'\n'/ }
  if [[ -n $ts_ports ]]; then
    ts_ports_file=$config_dir/.devdock/$project.ports.yml
    mkdir -p "${ts_ports_file%/*}"
    {
      echo "# Von devdock aus $ts_marker erzeugt, bei jedem Aufruf neu"
      echo "services:"
      echo "  tailscale:"
      echo "    ports:"
      for port in $ts_ports; do
        echo "      - \"127.0.0.1:$port:$port\""
      done
    } > "$ts_ports_file"
    files+=(-f "$ts_ports_file")
  fi
fi
```

In `compose_up` die Zeile `compose up -d "$@"` ersetzen durch:

```bash
  # --remove-orphans: nach "devdock tailscale off" verschwindet der Sidecar
  compose up -d --remove-orphans "$@"
```

- [ ] **Step 5: Test laufen lassen**

Run: `tests/compose-config.sh && bash -n devdock`
Expected: alle Zeilen `ok`, `alle Prüfungen bestanden`, Exit 0.

- [ ] **Step 6: Commit (nach Freigabe)**

```bash
git add compose.tailscale.yml devdock tests/compose-config.sh
git commit -m "Let a .devdock/tailscale marker move a workspace into a Tailscale sidecar namespace"
```

---

### Task 3: `devdock tailscale on|off|login|…`

**Files:**
- Modify: `devdock` (Kopfkommentar; neue Funktionen nach `in_container`; letzter `case`)
- Modify: `tests/compose-config.sh` (Abschnitt vor der Schlussauswertung)

**Interfaces:**
- Consumes: `ts_marker`, `valid_port`, `compose`, `compose_up`, `die`, `note`, `project` (Task 2 bzw. bestehend).
- Produces: Kommando `devdock tailscale [on [PORT...] | off | login | ARGS...]`; Funktionen `tailscale_running SERVICE`, `require_tailscale`, `tailscale_cmd ARGS...`.

- [ ] **Step 1: Failing Tests ergänzen**

In `tests/compose-config.sh` vor `((fails == 0)) || …` einfügen:

```bash
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
if "$devdock" -w "$fresh" tailscale status 2>&1 | grep -q 'Sidecar läuft nicht'; then
  pass "Durchreiche ohne laufenden Sidecar erklärt sich"
else
  fail "Durchreiche ohne laufenden Sidecar erklärt sich"
fi
ok_if "off" "$devdock" -w "$fresh" tailscale off
ok_if "off löscht den Marker" test ! -e "$fresh/.devdock/tailscale"
fails_if "off ohne Marker scheitert" "$devdock" -w "$fresh" tailscale off
check "off wirkt auf die Konfiguration" "$fresh" '.services.dev.network_mode == "host"'
```

- [ ] **Step 2: Test laufen lassen, Scheitern prüfen**

Run: `tests/compose-config.sh`
Expected: Task-2-Zeilen `ok`, die neuen `on`/`off`-Zeilen `FAIL` (`unbekanntes Kommando 'tailscale'`), Exit 1.

- [ ] **Step 3: Funktionen einfügen**

Nach der Funktion `in_container` einfügen:

```bash
# --- devdock tailscale -------------------------------------------------------
#
# on/off schalten nur die Marker-Datei; wirksam wird das beim nächsten
# devdock, das den Container wegen des anderen Netzes neu erstellt. Alles
# andere geht an das tailscale-CLI im Sidecar.

tailscale_running() {
  [[ -n $(compose ps -q --status running "$1" 2>/dev/null) ]]
}

require_tailscale() {
  [[ -f $ts_marker ]] || die "Tailscale ist für diesen Workspace aus (einschalten: devdock tailscale on)"
}

warn_recreate() {
  tailscale_running dev || return 0
  note "der Container läuft noch im alten Netz; das nächste devdock erstellt ihn neu, laufende tmux-Sessions enden dabei"
}

# on [PORT...]: mit Ports wird die Liste ersetzt, ohne bleibt eine vorhandene stehen
tailscale_on() {
  local port dir=${ts_marker%/*}
  for port; do
    valid_port "$port" || die "'$port' ist kein Port"
  done
  if [[ ! -d $dir ]]; then
    mkdir -p "$dir"
    # .devdock/ ist lokaler Zustand und gehört nicht ins Repo
    echo '*' > "$dir/.gitignore"
  fi
  if (($#)) || [[ ! -f $ts_marker ]]; then
    {
      echo "# devdock tailscale: ein Port pro Zeile, publiziert auf 127.0.0.1 des Hosts"
      if (($#)); then
        printf '%s\n' "$@"
      fi
    } > "$ts_marker"
  fi
  note "Tailscale ist für diesen Workspace an${*:+, Ports: $*}"
  warn_recreate
}

tailscale_off() {
  require_tailscale
  rm -f "$ts_marker"
  note "Tailscale ist für diesen Workspace aus; die Identität bleibt im Volume ${project}_tailscale-state"
  warn_recreate
}

# Wert eines String-Felds aus "tailscale status --json" (stdin)
json_field() {
  grep -oE "\"$1\": *\"[^\"]*\"" | head -n1 | cut -d'"' -f4 || true
}

# Startet den Workspace und zeigt die Login-URL, sobald der Sidecar eine hat
tailscale_login() {
  require_tailscale
  compose_up
  local i json state url
  for ((i = 0; i < 30; i++)); do
    json=$(compose exec -T tailscale tailscale status --json 2>/dev/null || true)
    state=$(json_field BackendState <<<"$json")
    url=$(json_field AuthURL <<<"$json")
    if [[ $state == Running ]]; then
      note "schon angemeldet"
      compose exec -T tailscale tailscale status --peers=false
      return 0
    fi
    if [[ -n $url ]]; then
      echo "$url"
      return 0
    fi
    sleep 1
  done
  die "nach 30 s keine Login-URL (Log: devdock logs tailscale)"
}

tailscale_cmd() {
  local tty=()
  case ${1:-} in
    on) shift; tailscale_on "$@" ;;
    off) tailscale_off ;;
    login) tailscale_login ;;
    *)
      require_tailscale
      (($#)) || set -- status
      tailscale_running tailscale || die "der Tailscale-Sidecar läuft nicht (starten: devdock up)"
      [[ -t 0 && -t 1 ]] || tty=(-T)
      compose exec "${tty[@]}" tailscale tailscale "$@"
      ;;
  esac
}
```

Im letzten `case $cmd in` vor `*)` ergänzen:

```bash
  tailscale) tailscale_cmd "$@" ;;
```

Im Kopfkommentar nach der Zeile `#   devdock [-w DIR] up|down|ps|logs|config` ergänzen:

```bash
#   devdock [-w DIR] tailscale on [PORT...]
#                                   Workspace ins Tailnet (eigenes Netz mit
#                                   Tailscale-Sidecar); PORTs auf 127.0.0.1 des
#                                   Hosts publizieren
#   devdock [-w DIR] tailscale off  zurück ins Host-Netz, die Identität bleibt
#   devdock [-w DIR] tailscale login  Login-URL des Sidecars zeigen
#   devdock [-w DIR] tailscale ARGS...  tailscale-CLI im Sidecar (status, ping, …)
```

- [ ] **Step 4: Test laufen lassen**

Run: `tests/compose-config.sh && bash -n devdock && ./devdock -h | grep -c tailscale`
Expected: alle Zeilen `ok`, Exit 0; `grep -c` ≥ 4.

- [ ] **Step 5: Commit (nach Freigabe)**

```bash
git add devdock tests/compose-config.sh
git commit -m "Add devdock tailscale to switch a workspace into the tailnet and talk to its sidecar"
```

---

### Task 4: `devdock-net` im Container (URL, MOTD, Port-Übersicht)

**Files:**
- Create: `bin/devdock-net`
- Create: `tests/devdock-net.sh`
- Modify: `Dockerfile` (COPY-Zeile der Scripts)
- Modify: `config/bashrc` (MOTD-Block am Ende)
- Modify: `bin/ok-autostart` (vier URL-Ausgaben)

**Interfaces:**
- Consumes: Environment aus Task 2 (`DEVDOCK_NET`, `DEVDOCK_PUBLISHED_PORTS`, `DEVDOCK_TS_HOSTNAME`), `DEVDOCK_WORKSPACE` (besteht).
- Produces: `devdock-net url PORT` (eine URL), `devdock-net motd` (eine Zeile oder nichts), `devdock-net ports` (Kopfzeile `WORKSPACE  host` bzw. `WORKSPACE  tailscale  NODE  BRIDGE-IP`, dann je Port `  URL  PROZESS[  (Hinweis)]`). Task 5 ruft `devdock-net ports` per `docker exec`.

- [ ] **Step 1: Failing Test schreiben**

`tests/devdock-net.sh`:

```bash
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

((fails == 0)) || { echo "$fails Prüfung(en) gescheitert"; exit 1; }
echo "alle Prüfungen bestanden"
```

`chmod +x tests/devdock-net.sh`

- [ ] **Step 2: Test laufen lassen, Scheitern prüfen**

Run: `tests/devdock-net.sh`
Expected: `FAIL`-Zeilen (`/repo/bin/devdock-net: No such file or directory`), Exit 1.

- [ ] **Step 3: `bin/devdock-net` schreiben**

```bash
#!/usr/bin/env bash
# Netzlage des Containers: Host-Netz oder eigener Namespace mit dem
# Tailscale-Sidecar (devdock tailscale on). Für die Shell, ok-autostart und
# "devdock ports" auf dem Host.
#
#   devdock-net url PORT   URL, unter der der Host einen Server auf PORT erreicht
#   devdock-net motd       eine Zeile für die Shell, nur im Tailscale-Workspace
#   devdock-net ports      lauschende Server dieses Containers samt URL
set -euo pipefail

die() { echo "devdock-net: $*" >&2; exit 1; }

usage() {
  sed -n '2,/^[^#]/s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"
}

tailscale_mode() {
  [[ ${DEVDOCK_NET:-host} == tailscale ]]
}

# Erste IPv4-Adresse eines Interfaces, leer, wenn es fehlt
ipv4() {
  local addr
  addr=$(ip -4 -o addr show "$1" 2>/dev/null | awk '{print $4; exit}')
  echo "${addr%/*}"
}

# Port steht in der Liste, die ./devdock auf 127.0.0.1 des Hosts publiziert
published() {
  [[ " ${DEVDOCK_PUBLISHED_PORTS:-} " == *" $1 "* ]]
}

url() {
  if ! tailscale_mode || published "$1"; then
    echo "http://localhost:$1"
  else
    echo "http://$(ipv4 eth0):$1"
  fi
}

motd() {
  tailscale_mode || return 0
  local ts
  ts=$(ipv4 tailscale0)
  echo "Tailscale: ${DEVDOCK_TS_HOSTNAME:-?} (${ts:-nicht verbunden, auf dem Host: devdock tailscale login}) · von außen: $(ipv4 eth0)"
}

# ss -p nennt nur Prozesse, die in diesem Container sichtbar sind. Im Host-Netz
# fallen so die Ports des Hosts und anderer Container heraus, im
# Tailscale-Workspace die von tailscaled im Sidecar.
ports() {
  local -A procs=() addrs=()
  local local_addr proc port addr reachable note
  while read -r _ _ _ local_addr _ proc; do
    [[ ${proc:-} == users:* ]] || continue
    port=${local_addr##*:}
    proc=${proc#*\"}
    procs[$port]=${proc%%\"*}
    addrs[$port]+=" ${local_addr%:*}"
  done < <(ss -Hltnp)

  if tailscale_mode; then
    echo "${DEVDOCK_WORKSPACE:-?}  tailscale  ${DEVDOCK_TS_HOSTNAME:-?}  $(ipv4 eth0)"
  else
    echo "${DEVDOCK_WORKSPACE:-?}  host"
  fi
  for port in $(printf '%s\n' "${!procs[@]}" | sort -n); do
    note=
    if tailscale_mode; then
      # Die Loopback-Weiterleitung im Sidecar deckt nur IPv4 ab
      reachable=0
      for addr in ${addrs[$port]}; do
        if [[ $addr != '[::1]' ]]; then
          reachable=1
        fi
      done
      if ((!reachable)); then
        note="  (nur [::1], von außen nicht erreichbar: auf 127.0.0.1 oder 0.0.0.0 starten)"
      fi
    fi
    printf '  %-28s %s%s\n' "$(url "$port")" "${procs[$port]}" "$note"
  done
}

case ${1:-} in
  url)
    [[ ${2:-} =~ ^[0-9]+$ ]] || die "url braucht einen Port"
    url "$2"
    ;;
  motd) motd ;;
  ports) ports ;;
  -h | --help | help) usage ;;
  *) die "unbekanntes Kommando '${1:-}' (siehe devdock-net --help)" ;;
esac
```

`chmod +x bin/devdock-net`

Variante, falls der Spike S3 gescheitert ist (keine Weiterleitung): die Bedingung `if [[ $addr != '[::1]' ]]; then` ersetzen durch `if [[ $addr != '[::1]' && $addr != 127.* ]]; then`, den Kommentar durch `# Ohne Weiterleitung erreicht der Host nur Server, die nicht auf Loopback lauschen`, den Hinweis durch `"  (nur Loopback, von außen nicht erreichbar: auf 0.0.0.0 starten)"`. Im Test dann die Erwartung für 8101 auf `"*python3*von außen nicht erreichbar*"` ändern.

- [ ] **Step 4: Test laufen lassen**

Run: `tests/devdock-net.sh`
Expected: alle Zeilen `ok` (ggf. eine `skip`-Zeile für `[::1]`), `alle Prüfungen bestanden`.

- [ ] **Step 5: ok-autostart auf `devdock-net url` umstellen**

In `bin/ok-autostart`:
- `await_server`: `echo "OpenKnowledge läuft: http://localhost:$port"` → `echo "OpenKnowledge läuft: $(devdock-net url "$port")"`
- `activate`: `echo "OpenKnowledge läuft schon: http://localhost:$port"` → `echo "OpenKnowledge läuft schon: $(devdock-net url "$port")"`
- `boot`: `note "$rel: gestartet auf http://localhost:$port"` → `note "$rel: gestartet auf $(devdock-net url "$port")"`
- `status`: `lines+=("$(printf '  http://localhost:%-5s  %s%s' "$port" "$rel" "${state:+ $state}")")` → `lines+=("$(printf '  %-28s %s%s' "$(devdock-net url "$port")" "$rel" "${state:+ $state}")")`

Kommentar über `listening()` ergänzen: `# Im Tailscale-Workspace sieht ss nur den eigenen Namespace; dort konkurriert auch kein anderer Workspace`. Die Zeile `# Alle Container laufen im Host-Netz, ss sieht also auch deren Ports` wird zu `# Im Host-Netz sieht ss auch die Ports der anderen Container`.

Run: `bash -n bin/ok-autostart && grep -c 'devdock-net url' bin/ok-autostart`
Expected: `4`.

- [ ] **Step 6: Dockerfile und MOTD**

`Dockerfile`, COPY-Zeile der Scripts:

```dockerfile
COPY bin/install-hermes bin/hermes bin/install-openknowledge bin/ok bin/ok-autostart \
  bin/devdock-net bin/devdock-entrypoint /usr/local/bin/
```

`config/bashrc`, der MOTD-Block am Ende wird zu:

```bash
# MOTD: Netzlage im Tailscale-Workspace und welche OpenKnowledge-Server mit dem
# Container gestartet wurden (ok activate). In tmux nur im ersten Pane einer
# neuen Session, nicht in jedem.
if [[ -z ${TMUX:-} || $(tmux display -p '#{session_windows}#{window_panes}' 2>/dev/null) == 11 ]]; then
  devdock-net motd
  ok-autostart status
fi
```

Run: `bash -n config/bashrc`
Expected: keine Ausgabe.

- [ ] **Step 7: Commit (nach Freigabe)**

```bash
git add bin/devdock-net tests/devdock-net.sh bin/ok-autostart Dockerfile config/bashrc
git commit -m "Add devdock-net so the shell and ok-autostart show URLs the host can actually reach"
```

---

### Task 5: `devdock ports`, `status`, `destroy`, `build`

**Files:**
- Modify: `devdock` (Kopfkommentar; `show_status`; `destroy`; neue `show_ports`; erster `case` für `status|destroy`; `build`-Zweig im letzten `case`)

**Interfaces:**
- Consumes: `devdock-net ports` im Container (Task 4), `devdock_containers` (besteht).
- Produces: Kommando `devdock ports`; `status` mit einer Zeile pro Workspace und Vermerk `tailscale`; `destroy --volumes` nimmt `*_tailscale-state` mit; `build` aktualisiert das Sidecar-Image.

- [ ] **Step 1: `show_ports` nach `show_status` einfügen**

```bash
# Erreichbare Server aller laufenden Workspaces. Was dort lauscht und unter
# welcher URL der Host es erreicht, weiß nur der Container (devdock-net).
show_ports() {
  local id first=1
  while read -r id; do
    if ((!first)); then
      echo
    fi
    first=0
    docker exec "$id" devdock-net ports 2>/dev/null \
      || echo "$(docker inspect -f '{{.Config.WorkingDir}}' "$id")  (Image ohne devdock-net; neu erstellen: devdock down, dann devdock)"
  done < <(devdock_containers -q --filter label=com.docker.compose.service=dev --filter status=running)
  if ((first)); then
    note "kein devdock-Container läuft"
  fi
}
```

Im ersten `case $cmd in` (der mit `status)` und `destroy)`) ergänzen:

```bash
  ports) show_ports; exit 0 ;;
```

Kopfkommentar nach der `devdock status`-Zeile:

```bash
#   devdock ports                   erreichbare Server aller laufenden Workspaces
```

- [ ] **Step 2: `show_status` auf `dev`-Container beschränken**

In `show_status`: `local image_id id state status dir container_image notes seen=0` → zusätzlich `compose_project` in die `local`-Liste. Den Block

```bash
      IFS=$'\t' read -r dir container_image \
        < <(docker inspect -f $'{{.Config.WorkingDir}}\t{{.Image}}' "$id")
```

ersetzen durch

```bash
      IFS=$'\t' read -r dir container_image compose_project \
        < <(docker inspect -f $'{{.Config.WorkingDir}}\t{{.Image}}\t{{index .Config.Labels "com.docker.compose.project"}}' "$id")
```

nach der Zeile mit `altes Image` einfügen:

```bash
      if [[ -n $(docker ps -aq --filter "label=com.docker.compose.project=$compose_project" \
        --filter label=com.docker.compose.service=tailscale) ]]; then
        notes+="${notes:+, }tailscale"
      fi
```

und `done < <(devdock_containers --format $'{{.ID}}\t{{.State}}\t{{.Status}}')` ersetzen durch

```bash
    # Nur dev: Der Tailscale-Sidecar trägt dasselbe Label, aber keinen Workspace
    done < <(devdock_containers --filter label=com.docker.compose.service=dev \
      --format $'{{.ID}}\t{{.State}}\t{{.Status}}')
```

- [ ] **Step 3: `destroy --volumes` um die State-Volumes erweitern**

In `destroy` nach `((volumes)) && for arg in "${shared_volumes[@]}"; do … done` einfügen:

```bash
  # Tailnet-Identitäten der Workspaces (<project>_tailscale-state)
  if ((volumes)); then
    mapfile -t -O "${#existing[@]}" existing < <(
      docker volume ls -q --filter label=com.docker.compose.volume=tailscale-state | grep '^devdock-' || true
    )
  fi
```

Die Meldung `((${#existing[@]})) && echo "  Volumes ${existing[*]} (Home samt gh- und Claude-Login, Caches, optionale Tools)"` wird zu `… (Home samt gh- und Claude-Login, Caches, optionale Tools, Tailnet-Identitäten)"`.

- [ ] **Step 4: `build` zieht das Sidecar-Image mit**

Im letzten `case`: `build) build_image "$@" ;;` ersetzen durch

```bash
  build)
    build_image "$@"
    # Das Sidecar-Image kommt nicht aus dem Build. Aktualisiert wird es, sobald
    # ein Workspace es einmal benutzt hat.
    if docker image inspect tailscale/tailscale:stable >/dev/null 2>&1; then
      docker pull tailscale/tailscale:stable
    fi
    ;;
```

- [ ] **Step 5: Prüfen**

Run: `bash -n devdock && tests/compose-config.sh && ./devdock status && ./devdock ports`
Expected: Syntax ok, Tests grün; `status` zeigt je Workspace genau eine Zeile; `ports` listet laufende Workspaces (alte Container mit dem Hinweis „Image ohne devdock-net“) oder `kein devdock-Container läuft`. `destroy` wird hier **nicht** ausgeführt (löscht alle Container); geprüft in Task 7 durch den User.

- [ ] **Step 6: Commit (nach Freigabe)**

```bash
git add devdock
git commit -m "Add devdock ports and teach status, destroy and build about the Tailscale sidecar"
```

---

### Task 6: Dokumentation

**Files:**
- Modify: `README.md` (Benutzung, Tabelle „Was vom Host kommt“, OpenKnowledge-Absatz, neuer Abschnitt `## Tailscale` vor `## Umgebungsvariablen`)
- Modify: `.env.example`
- Modify: `compose.yml` (Kopfkommentar, Kommentar an `network_mode`)

**Interfaces:**
- Consumes: Kommandos und Verhalten aus Task 2–5, Spike-Ergebnisse aus Task 1.
- Produces: nichts für andere Tasks.

- [ ] **Step 1: README – Benutzung**

Im Codeblock unter `## Benutzung` nach `./devdock status …`:

```bash
./devdock ports              # erreichbare Server aller laufenden Workspaces
./devdock tailscale on       # Workspace ins Tailnet (siehe Tailscale)
```

- [ ] **Step 2: README – Overlay-Tabelle**

Neue Zeile in der Tabelle unter `## Was vom Host kommt`:

```markdown
| `compose.tailscale.yml` | `<workspace>/.devdock/tailscale` vorhanden | eigenes Netz mit Tailscale-Sidecar statt Host-Netz (siehe [Tailscale](#tailscale)) |
```

- [ ] **Step 3: README – Abschnitt Tailscale**

Vor `## Umgebungsvariablen` einfügen:

````markdown
## Tailscale

Ein Workspace kann ins Tailnet, ohne dass der Host Tailscale bekommt. `devdock tailscale on` stellt ihn auf ein eigenes Netz um: Neben `dev` läuft dann ein Sidecar mit dem offiziellen Image `tailscale/tailscale`, und `dev` teilt dessen Netz-Namespace statt des Host-Netzes. Tailnet-Maschinen sind aus dem Container direkt erreichbar, auch per MagicDNS-Namen und mit Clients ohne Proxy-Unterstützung (`ssh`, `psql`, Go-Binaries). `NET_ADMIN` und `/dev/net/tun` bekommt nur der Sidecar, und beides wirkt nur in seinem Namespace.

```bash
devdock tailscale on 5173 4700   # einschalten, Ports auf localhost des Hosts publizieren
devdock                          # erstellt den Container im neuen Netz
devdock tailscale login          # einmalig: Login-URL zeigen (entfällt mit TS_AUTHKEY)
devdock tailscale status         # beliebige tailscale-Kommandos im Sidecar
devdock ports                    # wo welcher Server von außen erreichbar ist
devdock tailscale off            # zurück ins Host-Netz
```

`on` und `off` ändern nur `<workspace>/.devdock/tailscale` (ein Port pro Zeile, `#` für Kommentare, von Hand editierbar). Wirksam wird das beim nächsten `devdock`, das den Container dafür neu erstellt; laufende tmux-Sessions enden dabei. `on` mit Ports ersetzt die Liste, ohne Ports bleibt sie.

Jeder Workspace ist ein eigener Node namens `devdock-<workspace>`. Seine Identität liegt im Volume `<projekt>_tailscale-state`, übersteht `devdock down` und `devdock tailscale off` und geht erst mit `destroy --volumes` oder von Hand: `devdock tailscale logout`, dann `docker volume rm <projekt>_tailscale-state` (den Namen zeigt `docker volume ls`). Mit `TS_AUTHKEY` in `.env` meldet sich ein neuer Workspace ohne Login-URL an; weil `.env` für alle Workspaces gilt, muss der Key *reusable* sein.

Der Preis ist `localhost`:

| Richtung | Host-Netz | Tailscale-Workspace |
| --- | --- | --- |
| Host → Server im Container | `localhost:PORT` | `localhost:PORT` für publizierte Ports, sonst die Bridge-IP (`devdock ports`) |
| Container → Dienst auf dem Host | `localhost:PORT` | `host.docker.internal:PORT` |
| Container → per `docker run -p` gestarteter Dienst | `localhost:PORT` | `host.docker.internal:PORT` |

Server, die nur auf `127.0.0.1` lauschen (Vite, Next und viele andere per Default), sind trotzdem erreichbar: Der Sidecar leitet neue TCP-Verbindungen von seinem Bridge-Interface auf den Loopback weiter (`iptables … DNAT --to-destination 127.0.0.1` samt `route_localnet`, nur in seinem Namespace). Das gilt nur für IPv4; einen Server, der allein auf `[::1]` lauscht, markiert `devdock ports`. Die Shell nennt beim Start Node-Name, Tailnet-IP und Bridge-IP, `ok-autostart` die URL, unter der der Host OpenKnowledge erreicht. Weil jeder Tailscale-Workspace ein eigenes Netz hat, dürfen dort zwei Workspaces denselben Port benutzen, solange er nicht publiziert ist.

`dev` hängt am Namespace des Sidecars. Wird der Sidecar allein neu gestartet (`docker restart`), verliert `dev` sein Netz; dann hilft `devdock down` und `devdock`. Fehlt auf dem Host `/dev/net/tun` (Kernel-Modul `tun`), startet der Workspace nicht, bis `devdock tailscale off` ihn zurückstellt.
````

Weicht ein Spike-Ergebnis ab (Task 1), die betroffenen Sätze anpassen: ohne Weiterleitung entfällt der Absatz zu `127.0.0.1` zugunsten von „Dev-Server mit `--host` bzw. auf `0.0.0.0` starten“; mit `disable_ipv6` ein Satz dazu, dass IPv6 im Tailscale-Workspace aus ist.

- [ ] **Step 4: README – OpenKnowledge**

Im OpenKnowledge-Absatz `Durch das Host-Netz ist sie direkt im Browser des Hosts erreichbar.` ersetzen durch `Durch das Host-Netz ist sie direkt im Browser des Hosts erreichbar, in einem Tailscale-Workspace unter der URL, die ok-autostart nennt.`

- [ ] **Step 5: `.env.example`**

Vor `# Beispiel für eigene Variablen` einfügen:

```bash
# Tailscale für Workspaces mit "devdock tailscale on" (README: Tailscale).
# Ohne Key zeigt "devdock tailscale login" einmal pro Workspace eine Login-URL.
# Der Key gilt für alle Workspaces und muss deshalb reusable sein; ein Tag
# hält die Nodes in den ACLs auseinander.
# TS_AUTHKEY=
# Zusätzliche Flags für "tailscale up"
# TS_EXTRA_ARGS=--advertise-tags=tag:devdock
```

- [ ] **Step 6: `compose.yml`**

Kopfkommentar, nach `#   compose.git-ignore.yml  globale Git-ignore-Liste des Hosts`:

```yaml
#   compose.tailscale.yml   eigenes Netz mit Tailscale-Sidecar statt Host-Netz
```

Kommentar über `network_mode: host`:

```yaml
    # Host-Netz: Dev-Server im Container sind auf dem Host unter localhost erreichbar
    # und umgekehrt; kein Port-Mapping nötig. compose.tailscale.yml ersetzt es
    # durch den Namespace des Tailscale-Sidecars.
```

Run: `tests/compose-config.sh`
Expected: weiterhin grün (Kommentare ändern nichts).

- [ ] **Step 7: Commit (nach Freigabe)**

```bash
git add README.md .env.example compose.yml
git commit -m "Document Tailscale workspaces"
```

---

### Task 7: Ende-zu-Ende-Prüfung mit echtem Tailnet

**Files:**
- keine Änderungen, außer Fehler tauchen auf (dann zurück in den Task, dem der Code gehört)

**Interfaces:**
- Consumes: alles aus Task 2–6; ein Wegwerf-Workspace, z. B. `$SCRATCH/ts-e2e` mit einer `package.json`-losen Python-Probe.

- [ ] **Step 1: Image bauen**

Run: `./devdock build`
Expected: Build grün; `docker run --rm --entrypoint devdock-net devdock:latest --help` zeigt die Hilfe.

- [ ] **Step 2: Workspace einschalten und starten**

Run: `./devdock -w "$WS" tailscale on 47173 && ./devdock -w "$WS" up && ./devdock -w "$WS" tailscale login`
Expected: Login-URL (User klickt) oder „schon angemeldet“ mit `TS_AUTHKEY`; danach `./devdock -w "$WS" tailscale status` mit eigener Zeile.

- [ ] **Step 3: Tailnet aus dem Container**

Run: `./devdock -w "$WS" exec bash -c 'getent hosts <maschine> && timeout 5 bash -c "</dev/tcp/<maschine>/<port>" && echo TCP-OK'`
Expected: Adresse und `TCP-OK`.

- [ ] **Step 4: Erreichbarkeit vom Host**

Run:
```bash
./devdock -w "$WS" exec bash -c 'cd /tmp && setsid python3 -m http.server --bind 127.0.0.1 47173 >/dev/null 2>&1 & setsid python3 -m http.server --bind 127.0.0.1 47174 >/dev/null 2>&1 &'
./devdock ports
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:47173/
curl -s -o /dev/null -w '%{http_code}\n' "$(./devdock ports | grep -oE 'http://[0-9.]+:47174')/"
```
Expected: `ports` zeigt 47173 mit `localhost`, 47174 mit Bridge-IP; zweimal `200`.

- [ ] **Step 5: MOTD und Neustart**

Run: `./devdock -w "$WS" exec bash -lic true` (zeigt die MOTD), dann `./devdock -w "$WS" down && ./devdock -w "$WS" up && ./devdock -w "$WS" tailscale status`
Expected: MOTD-Zeile `Tailscale: devdock-ts-e2e (100.…) · von außen: …`; nach dem Neustart verbunden ohne neuen Login.

- [ ] **Step 6: `off` bei laufendem Container**

Run: `./devdock -w "$WS" tailscale off; ./devdock -w "$WS" up; ./devdock -w "$WS" ps; docker volume ls | grep tailscale-state`
Expected: `off` warnt vor dem Neuerstellen; danach nur `dev` (kein Sidecar), Volume noch vorhanden; `./devdock -w "$WS" config --format json | jq -r .services.dev.network_mode` ergibt `host`.

- [ ] **Step 7: `status` und `destroy` (User)**

Run: `./devdock status`
Expected: eine Zeile pro Workspace, Sidecar-Workspaces mit `tailscale`.
`destroy --volumes` nur durch den User, interaktiv mit Antwort `N`: Die Liste muss die `*_tailscale-state`-Volumes nennen.

- [ ] **Step 8: Aufräumen**

Run: `./devdock -w "$WS" tailscale logout` (vorher wieder `on` + `up`, falls in Step 6 ausgeschaltet), `./devdock -w "$WS" down -v`, `rm -rf "$WS"`
Expected: Node aus dem Tailnet ausgetragen, Volume weg.
