# Tailscale-Sidecar für devdock-Workspaces

Stand: 2026-10-13 · Status: Design abgestimmt, Spike offen

## Ziel

Ein Workspace kann auf Wunsch ins Tailnet: Aus dem Dev-Container sind
Tailnet-Maschinen transparent erreichbar (`ssh`, `psql`, `curl`, statische
Go-Binaries, MagicDNS-Namen), ohne Proxy-Variablen. Eingerichtet wird einmal
pro Workspace, danach verbindet sich der Workspace bei jedem Container-Start
von selbst.

## Rahmenbedingungen

- **Der Host bleibt unberührt.** Kein Tailscale auf dem Host, kein
  `tailscale0`, keine Routen, keine iptables-Regeln im Host-Namespace.
- **Opt-in pro Workspace.** Workspaces ohne Tailscale laufen exakt wie heute
  im Host-Netz.
- Tailnet-Zugriff von außen auf den Container (`tailscale serve`, eingehendes
  `tailscale ssh`) ist kein Ziel, wird aber nicht verbaut.

## Warum ein Sidecar und kein tailscaled im Dev-Container

`compose.yml` startet `dev` mit `network_mode: host`. Ein `tailscaled` im
Kernel-Modus legte `tailscale0`, Routen und Regeln damit im Host-Namespace an,
also genau dort, wo nichts passieren darf. Der Userspace-Modus ließe den Host in
Ruhe, erreicht das Tailnet ausgehend aber nur über SOCKS5/HTTP-Proxy; Clients
ohne Proxy-Unterstützung (Datenbanken, statische Binaries) blieben draußen.

Deshalb bekommt ein Tailscale-Workspace einen eigenen Netz-Namespace: Ein
Sidecar mit dem offiziellen Image `tailscale/tailscale` läuft im Kernel-Modus
auf einem gewöhnlichen Docker-Bridge-Netz, und `dev` teilt dessen Namespace
(`network_mode: service:tailscale`). `NET_ADMIN` und `/dev/net/tun` braucht nur
der Sidecar, und beides wirkt nur in diesem Namespace.

Der Preis: In einem Tailscale-Workspace ist `localhost` nicht mehr der Host.

| Richtung | Host-Netz (heute) | Tailscale-Workspace |
| --- | --- | --- |
| Host → Dev-Server im Container | `localhost:PORT` | Bridge-IP des Workspaces, oder `localhost:PORT` für publizierte Ports |
| Container → Dienst auf dem Host | `localhost:PORT` | `host.docker.internal:PORT` |
| Container → per `docker run -p` gestarteter Dienst | `localhost:PORT` | `host.docker.internal:PORT` |
| Port-Konkurrenz zwischen Workspaces | ja, ein Namespace | nein, außer bei publizierten Ports |

Docker-Socket, SSH-Agent, Wayland und GPU sind Sockets bzw. Devices und
funktionieren in beiden Modi gleich.

## Bedienung

Ein Container kann seinen Netzmodus nicht selbst wechseln, das braucht ein
Neuerstellen. Geschaltet wird deshalb auf dem Host:

```
devdock tailscale on [PORT...]   Workspace auf Tailscale umstellen; PORTs werden auf
                                 127.0.0.1 des Hosts publiziert (ersetzt die Liste)
devdock tailscale off            zurück ins Host-Netz; die Tailnet-Identität bleibt
devdock tailscale login          Login-URL aus dem Log des Sidecars zeigen
devdock tailscale [ARGS...]      durchgereicht an das tailscale-CLI im Sidecar
                                 (status, ping, netcheck, logout, …)
devdock ports                    erreichbare Server aller laufenden Workspaces
```

`on` und `off` ändern nur die Konfiguration. Wirksam wird sie beim nächsten
`devdock` (bzw. `devdock up`), das den Container neu erstellt; laufende
tmux-Sessions enden dabei. Beide Kommandos sagen das, wenn der Container gerade
läuft.

### Marker und Port-Liste: `<workspace>/.devdock/tailscale`

Existiert die Datei, ist der Workspace ein Tailscale-Workspace. Inhalt: ein Port
pro Zeile, `#` leitet Kommentare ein, die Datei darf leer sein. `on PORT...`
schreibt sie neu, `on` ohne Ports legt sie leer an bzw. lässt eine vorhandene
Liste stehen, `off` löscht sie. Von Hand editieren ist erlaubt. Legt `devdock`
dabei `.devdock/` neu an, kommt wie gewohnt ein `.gitignore` mit `*` hinein.

### Login

- **Ohne `TS_AUTHKEY`:** Beim ersten Start schreibt der Sidecar eine Login-URL
  ins Log; `devdock tailscale login` zeigt sie. Einmal pro Workspace, danach
  trägt der State.
- **Mit `TS_AUTHKEY` in `.env`:** Login automatisch beim ersten Start. Weil
  `.env` für alle Workspaces gilt, muss der Key *reusable* sein; ein Tag
  (`tag:devdock`) hält die Nodes in ACLs auseinander.

Jeder Workspace ist ein eigener Node mit dem Namen `devdock-<slug>` (Slug wie
im Compose-Projektnamen). Gleichnamige Workspaces bekommen von Tailscale ein
Suffix.

## Komponenten

### `compose.tailscale.yml` (neu)

Overlay, das `./devdock` anhängt, wenn `.devdock/tailscale` existiert.

- Service `tailscale`, Image `tailscale/tailscale:stable`:
  - `cap_add: [NET_ADMIN]`, `devices: [/dev/net/tun:/dev/net/tun]`
  - Environment: `TS_USERSPACE=false`, `TS_STATE_DIR=/var/lib/tailscale`,
    `TS_HOSTNAME=devdock-${DEVDOCK_SLUG}`, `TS_ACCEPT_DNS=true`,
    `TS_AUTHKEY=${TS_AUTHKEY:-}`, `TS_EXTRA_ARGS=${TS_EXTRA_ARGS:-}`
  - Volume `tailscale-state:/var/lib/tailscale`
  - `sysctls: net.ipv4.conf.all.route_localnet: 1`
  - `extra_hosts: host.docker.internal:host-gateway`, weil `dev` im fremden
    Namespace selbst keine setzen darf
  - `ports:` aus der Port-Liste, je `127.0.0.1:P:P`
  - Entrypoint-Wrapper: setzt die Loopback-Weiterleitung (unten) und startet
    dann per `exec` das `containerboot` des Images
- Service `dev`: `network_mode: service:tailscale`, `depends_on: [tailscale]`,
  zusätzlich `DEVDOCK_NET=tailscale` und `DEVDOCK_PUBLISHED_PORTS` (Liste,
  durch Leerzeichen getrennt) im Environment.
- Volume `tailscale-state`: gehört dem Compose-Projekt (nicht `external`), heißt
  damit `<project>_tailscale-state`, überlebt `devdock down` und geht erst mit
  `down -v` oder `destroy --volumes`.

Die Port-Liste kann Compose nicht aus einer Datei lesen. `./devdock` erzeugt
deshalb die `ports:`-Einträge in ein generiertes Overlay
(`$config_dir/.devdock/<project>.ports.yml`) und hängt es mit an, wenn die Liste
nicht leer ist.

**Warum der State nicht in `.devdock/` liegt:** Der Sidecar läuft als root, seine
Dateien gehörten im Workspace root (`rm -rf .devdock` bräuchte `sudo`), und der
private Schlüssel des Nodes läge im Projektbaum, wo ihn Backups und
Synchronisierung mitnehmen.

### Loopback-Weiterleitung im Sidecar

Viele Dev-Server (Vite, Next, …) lauschen standardmäßig nur auf `127.0.0.1`. Im
Host-Netz war das der Loopback des Hosts, im eigenen Namespace sind sie damit
von außen unerreichbar. Der Wrapper setzt im Namespace des Sidecars:

```
iptables -t nat -A PREROUTING -i eth0 -p tcp -j DNAT --to-destination 127.0.0.1
```

zusammen mit `route_localnet=1`. Neue TCP-Verbindungen, die über das Bridge-
Interface hereinkommen (vom Host direkt oder über publizierte Ports), landen auf
dem Loopback; Antworten auf ausgehende Verbindungen sind schon im conntrack und
bleiben unberührt, UDP (WireGuard) ebenso, `tailscale0` ebenso. Server, die auf
`0.0.0.0` lauschen, sind auf Loopback ohnehin erreichbar.

### `devdock` (Host-Script)

- `DEVDOCK_SLUG` exportieren (heute nur lokal für den Projektnamen berechnet).
- Overlay `compose.tailscale.yml` plus generiertes Port-Overlay anhängen, wenn
  `$workspace/.devdock/tailscale` existiert.
- `compose_up` mit `--remove-orphans`, damit nach `off` der verwaiste Sidecar
  verschwindet.
- Neue Kommandos `tailscale …` und `ports` (siehe Bedienung).
  `tailscale ARGS` → `compose exec tailscale tailscale ARGS`;
  `login` → letzte Login-URL aus `compose logs tailscale`.
- `build`: zieht zusätzlich `tailscale/tailscale:stable`, sofern das Image
  lokal schon existiert (also mindestens ein Workspace es benutzt hat).
- `status`: zeigt nur `dev`-Container als Zeile (über das Label
  `com.docker.compose.service`), mit dem Vermerk `tailscale`, wenn das Projekt
  einen Sidecar hat. Heute erschiene der Sidecar als eigene Zeile mit
  falschem Workspace-Pfad.
- `destroy --volumes`: entfernt zusätzlich alle `tailscale-state`-Volumes der
  devdock-Projekte (Label `com.docker.compose.volume=tailscale-state`, Projekt
  mit Präfix `devdock-`).

### `devdock ports`

Für jeden laufenden `dev`-Container:

1. `docker exec <dev> ss -Hltnp` als `devel`. Nur Zeilen mit Prozessangabe
   zählen: Im Host-Modus fallen so Ports des Hosts und anderer Container heraus,
   im Tailscale-Modus die von tailscaled (anderer PID-Namespace).
2. URL bilden: publizierter Port → `http://localhost:P`; Tailscale-Workspace →
   `http://<Bridge-IP>:P` (IP des Sidecars aus `docker inspect`); Host-Modus →
   `http://localhost:P`.
3. Lauscht ein Server nur auf Loopback und die Weiterleitung fehlt (Spike
   gescheitert), Vermerk `nur Loopback`.

```
foo  tailscale  devdock-foo  172.21.0.2
  http://localhost:5173    node
  http://172.21.0.2:4700   open-knowledge-server
bar  host
  http://localhost:3000    node
```

### Im Container

- **MOTD** (`config/bashrc`): Im Tailscale-Modus eine Zeile
  `Tailscale: devdock-foo (100.x.y.z) · von außen: 172.21.0.2`, unter denselben
  tmux-Bedingungen wie `ok-autostart status`. Die Tailnet-IP kommt aus
  `ip -4 addr show tailscale0`, die Bridge-IP aus `eth0`; ein `tailscale`-CLI
  braucht der Dev-Container dafür nicht.
- **`ok-autostart`:** Die angezeigten URLs nehmen `localhost`, wenn
  `DEVDOCK_NET` nicht `tailscale` ist oder der Port in
  `DEVDOCK_PUBLISHED_PORTS` steht, sonst die Bridge-IP. Die Port-Prüfung
  (`ss`) sieht im Tailscale-Modus nur den eigenen Namespace; das ist richtig,
  weil andere Workspaces dort nicht konkurrieren.
- Kein `tailscale`-CLI im Dev-Image (YAGNI). Schreibende Befehle bräuchten
  Operator-Rechte über die Container-Grenze; `devdock tailscale …` deckt das ab.

### `.env.example`, README

- `.env.example`: `TS_AUTHKEY` und `TS_EXTRA_ARGS`, auskommentiert, mit Hinweis
  auf reusable Key und Tag.
- README: Abschnitt „Tailscale“ mit Zweck, Bedienung, Tabelle der
  `localhost`-Änderungen, Loopback-Weiterleitung, Login, Zurücksetzen
  (`devdock tailscale logout`, dann `docker volume rm <project>_tailscale-state`)
  und den Kanten unten. Die Overlay-Tabelle bekommt eine Zeile für
  `compose.tailscale.yml`.

## Kanten

- **Neustart des Sidecars:** `dev` hängt im Namespace des Sidecars. Wird der
  Sidecar neu erstellt oder neu gestartet, verliert `dev` sein Netz (Docker
  hängt den Namespace nicht neu ein). Abhilfe: `devdock down`, dann `devdock`.
  Der Sidecar bekommt keine Restart-Policy, damit das nicht unbemerkt passiert.
- **Sidecar startet nicht** (kein `/dev/net/tun`, `tun`-Modul fehlt):
  `compose up` scheitert sichtbar; der Workspace ist bis `devdock tailscale off`
  nicht startbar. Die Fehlermeldung von Docker nennt das Device.
- **Kollision publizierter Ports:** Zwei Workspaces mit demselben publizierten
  Port: Docker verweigert den Start des zweiten Sidecars mit „port is already
  allocated“. Gleiches Verhalten wie heute im Host-Netz.
- **Abgelaufener Node-Key:** Der Sidecar läuft weiter, das Tailnet ist weg;
  `devdock tailscale status` zeigt es, `devdock tailscale login` hilft.
- **Wechsel `on`/`off` bei laufendem Container:** Container wird beim nächsten
  `devdock` neu erstellt, tmux-Sessions enden; `on`/`off` warnen.

## Spike (vor der Implementierung)

Wegwerf-Compose im Scratchpad, nicht im Repo. Zu klären:

1. Kernel-Modus im Sidecar plus `network_mode: service:tailscale`: `dev`
   erreicht eine Tailnet-IP (`ping`, TCP).
2. MagicDNS in `dev`: Teilt `dev` die `resolv.conf` des Sidecars, und schreibt
   `containerboot`/`tailscaled` sie so, dass `dev` Tailnet-Namen auflöst? Plan B:
   `dns: [100.100.100.100]` plus `dns_search` am Sidecar.
3. Loopback-Weiterleitung: Ein Server auf `127.0.0.1:5173` in `dev` ist vom Host
   über Bridge-IP und publizierten Port erreichbar; Docker-DNS (`127.0.0.11`)
   und ausgehende Verbindungen funktionieren weiter; das Image hat `iptables`.
4. Publizierte Ports am Sidecar erreichen Server in `dev`.
5. `extra_hosts` am Sidecar wirkt in `dev` (`host.docker.internal`).

Punkte 1 und 2 brauchen einen Login ins Tailnet (Auth-Key oder Login-URL).
Scheitert 2, wird Plan B Teil des Designs. Scheitert 3, entfällt die
Weiterleitung; `devdock ports` markiert Loopback-Server, die README empfiehlt
`--host`.

## Prüfung nach der Implementierung

Kein Test-Framework im Repo; geprüft wird von Hand und mit `bash -n`
(`shellcheck`, falls vorhanden) für `devdock`, `devdock-entrypoint`,
`ok-autostart`:

- Workspace ohne Marker: `devdock config` identisch zu vorher (bis auf
  `--remove-orphans`-Verhalten), Host-Netz.
- `devdock tailscale on 5173` → `devdock` → Login → Tailnet-Host per `ssh`,
  `curl` und MagicDNS-Namen erreichbar; Vite auf `127.0.0.1:5173` vom Host unter
  `localhost:5173` und unter der Bridge-IP erreichbar.
- `devdock ports` zeigt beide Workspaces korrekt.
- `devdock down` + `devdock`: Node verbindet sich ohne neuen Login.
- `devdock tailscale off` → `devdock`: Host-Netz, kein Sidecar mehr, Volume noch
  da.
- `devdock status` und `destroy --volumes` mit Sidecar.
- `ok activate` in einem Tailscale-Workspace: richtige URL in MOTD und Ausgabe.

## Spike-Ergebnisse (2026-10-13)

Wegwerf-Compose mit `tailscale/tailscale:stable` (1.102.5) und `devdock:latest`,
Host mit nftables-Kernel.

| Punkt | Ergebnis | Folge für die Implementierung |
| --- | --- | --- |
| S1 Tailnet aus dev | grün: Route zu Tailnet-IPs über `tailscale0` (Tabelle 52), TCP zu `100.100.100.100:53` | keine |
| S2 MagicDNS | grün: `dev` teilt die `resolv.conf` des Sidecars (`nameserver 100.100.100.100`, `search <tailnet>.ts.net`), Kurz- und FQDN-Namen lösen auf, externe Namen auch | kein Plan B nötig |
| S3 Loopback-Weiterleitung | mit `iptables` (legacy, Default im Image) gescheitert: keine `nat`-Tabelle auf nft-Kerneln; mit `iptables-nft` grün, auch nach dem Login; ausgehende Verbindungen und Docker-DNS unberührt | Wrapper nimmt `iptables-nft`, Rückfall `iptables-legacy` |
| S4 publizierter Port | grün (`127.0.0.1:47173` → Server auf `127.0.0.1:5173` in `dev`) | keine |
| S5 host.docker.internal | grün (`172.17.0.1`) | keine |
| S6 localhost-Auflösung | Node bindet `localhost` an `::1`; mit `net.ipv6.conf.all.disable_ipv6=1` am Sidecar an `127.0.0.1`, dann über die Bridge erreichbar | `disable_ipv6=1` am Sidecar; Tailscale-Workspaces haben kein IPv6 |
| Zusatz: Login-Timeout | `containerboot` beendet sich 60 s nach dem Start, wenn ohne `TS_AUTHKEY` niemand die Login-URL öffnet („context deadline exceeded“); `dev` verliert damit sein Netz. `TS_BOOT_TIMEOUT` steuert die Frist (mit 15 s geprüft) | `TS_BOOT_TIMEOUT=8760h`: Der Sidecar wartet, bis `devdock tailscale login` erledigt ist |
