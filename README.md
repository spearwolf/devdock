# devdock

Dev-Container auf Basis von Ubuntu 26.04 LTS. Er nutzt den Docker-Daemon, den SSH-Agent und das Wayland-Display des Hosts.

## Inhalt

| Quelle | Tools |
| --- | --- |
| mise (Image, `config/mise.toml`) | node 26, pnpm 12, go, rust, neovim, tree-sitter, delta, gh, lazygit, lazydocker, atuin, starship, zoxide, fzf, opencode, claude (Claude Code), uv, bun |
| apt | git, git-lfs, curl, jq, bat, mc, tmux, ripgrep, fd, build-essential, wl-clipboard |
| optional, per `install-*` im Container | [Hermes Agent](https://github.com/NousResearch/hermes-agent) (`hermes`, `install-hermes`), [OpenKnowledge](https://openknowledge.ai) (`ok`, `install-openknowledge`) |
| `docker:cli`-Image | docker, docker compose, docker buildx (nur CLI, der Daemon ist der des Hosts) |

Neovim startet mit [nvim-config-next](https://github.com/spearwolf/nvim-config-next), eine andere Config wählt `DEVDOCK_NEOVIM_CONFIG` in `.env` (siehe [Neovim-Config](#neovim-config)). Die Plugins und Mason-Tools sind schon beim Build installiert. Für Playwright-Browser sind die Systembibliotheken vorinstalliert, die Browser selbst nicht (siehe unten).

## Benutzung

```bash
./devdock build              # Image bauen (einmalig bzw. für Updates)
./devdock build --upgrade    # dito, mise-Tools auf die neuesten Versionen
./devdock                    # Container fürs aktuelle Verzeichnis, tmux-Session
./devdock -w ~/code/foo      # dito im Workspace ~/code/foo
./devdock shell              # Login-Shell statt tmux
./devdock exec pnpm test     # einzelnes Kommando
./devdock down               # Container des Workspaces stoppen und entfernen
./devdock status             # Image und alle devdock-Container: online/offline
./devdock ports              # erreichbare Server aller laufenden Workspaces
./devdock tailscale on       # Workspace ins Tailnet (siehe Tailscale)
./devdock destroy            # alle devdock-Container und das Image löschen (fragt nach)
```

`status` und `destroy` sehen alle Workspaces, nicht nur den aktuellen. `status` markiert Container, die nach einem `build` noch auf dem alten Image laufen; die aktualisiert ein `./devdock down` mit anschließendem Neustart. `destroy` muss vor dem Image alle Container entfernen, auch laufende, sonst verweigert Docker das Löschen. Die Volumes bleiben dabei stehen, `destroy --volumes` nimmt auch sie mit (also das Home samt gh- und Claude-Login und Shell-History, die Caches und die optionalen Tools). `-y` überspringt die Rückfrage.

Wer `devdock` in den `PATH` verlinkt (`ln -s $PWD/devdock ~/.local/bin/`), kann es aus jedem Projekt heraus aufrufen.

Der Workspace liegt im Container unter **demselben Pfad** wie auf dem Host. Dadurch funktionieren Bind-Mounts, die man von drinnen an den Host-Daemon schickt (`docker run -v $PWD:/src …`). Für jeden Workspace gibt es einen eigenen Container. Das Image `devdock:latest` und die Volumes `devdock-home` (das bleibende Home, siehe unten), `devdock-cache` (`~/.cache`: pnpm-Store, Go-Cache, Playwright-Browser) und `devdock-addons` (`~/.addons`: optionale Tools samt Daten, siehe unten) teilen sich alle.

## Home-Volume

`devdock-home` hält, was vom Home bleiben soll, je Pfad in einem eigenen Unterverzeichnis (Compose: `volume.subpath`):

| Pfad | Unterverzeichnis | Inhalt, unter anderem |
| --- | --- | --- |
| `~/.config` | `config` | gh-Login, Starship, Neovim-Config, eigene mise-Tools |
| `~/.local` | `local` | Shell-History (atuin), Neovim-Plugins und Mason-Tools, `~/.local/bin` |
| `~/.claude` | `claude` | Login, Settings und Verlauf von Claude Code |

Was der Build selbst in `~/.config` und `~/.local` anlegt (Neovim-Config samt Plugins und Mason-Tools, den pnpm-Store-Pfad), verdeckt das Volume. Das Image hält es deshalb unter `/opt/devdock/skel` bereit, und `devdock-entrypoint` kopiert beim Container-Start jeden Eintrag (`.config/nvim`, `.local/share/nvim`, …), der im Volume noch ganz fehlt. Danach gehört er dem Volume: Ein Rebuild ändert ihn nicht mehr, ein `git pull` in `~/.config/nvim` bleibt. Zurück auf den Stand des Images geht es mit `rm -rf ~/.config/nvim ~/.local/share/nvim` und einem neuen Container (`./devdock down`, dann `./devdock`). Ebenso einmalig landet `config/starship.toml` als `~/.config/starship.toml` im Volume und ist dort frei editierbar; spätere Änderungen im Repo erreichen sie nicht mehr.

Die Tools aus `config/mise.toml` gehören dagegen dem Image. mise installiert sie in seine System-Ebene (`/etc/mise/config.toml`, `/usr/local/share/mise`), die das Volume nicht verdeckt, und jeder Rebuild bringt neue Versionen mit. `~/.config/mise/config.toml` gilt zusätzlich und ist für eigene Tools da (`mise use -g …`). Die landen wie die Versionen, die ein Projekt pinnt, in `~/.local/share/mise` und überleben damit `./devdock down`, für alle Workspaces. Eine Kopie von `config/mise.toml` gehört nicht dorthin: Sie bliebe nach einem Rebuild auf dem alten Stand, und mise installierte die alten Versionen nebenher ins Volume.

Docker verweigert einen subpath-Mount, dessen Verzeichnis fehlt. `./devdock` legt das Volume deshalb selbst an, gleich samt Unterverzeichnissen. Gibt es dabei noch die Volumes des alten Layouts (`devdock-gh`, `devdock-claude`, `devdock-atuin`), übernimmt es deren Inhalt und lässt sie stehen; gelöscht werden sie von Hand. Ist eines davon noch in einem laufenden Container eingebunden, bricht es ab, bis der gestoppt ist.

## Eigene Shell-Scripts pro Workspace

`devdock-entrypoint` legt im Workspace `.devdock/bashrc.d/` an; ist `.devdock/` dabei neu, kommt ein `.gitignore` mit `*` hinein. Die interaktive Shell sourct alle Dateien darin in Namensreihenfolge, und zwar zuletzt, nach mise, Starship und atuin. So können die Scripts deren Aliase und Einstellungen überschreiben. Ein neues Script greift ab der nächsten Shell.

## Was vom Host kommt

`./devdock` prüft beim Start, was vorhanden ist, und hängt dafür das passende Overlay an:

| Overlay | Bedingung | Wirkung |
| --- | --- | --- |
| `compose.yml` | immer | Workspace, Docker-Socket (GID per `group_add`), Host-Netz, `/etc/localtime` |
| `compose.ssh.yml` | `SSH_AUTH_SOCK` gesetzt | nur der Agent-Socket, kein `~/.ssh`, keine Keys |
| `compose.wayland.yml` | `WAYLAND_DISPLAY` gesetzt | Wayland-Socket, Toolkit-Variablen für Wayland |
| `compose.gpu.yml` | Wayland + `/dev/dri` vorhanden | Render-Nodes samt video/render-Gruppe |
| `compose.tmux.yml` | `~/.config/tmux/tmux.conf` oder `~/.tmux.conf` | tmux-Config, read-only |
| `compose.gitconfig.yml` | `./gitconfig` oder Host-Git-Config vorhanden | globale Git-Config (siehe unten) |
| `compose.git-ignore.yml` | `~/.config/git/ignore` vorhanden | globale ignore-Liste, read-only |
| `compose.tailscale.yml` | `<workspace>/.devdock/tailscale` vorhanden | eigenes Netz mit Tailscale-Sidecar statt Host-Netz (siehe [Tailscale](#tailscale)) |
| `compose.tailscale-state.yml` | dort zusätzlich die Zeile `persistent` | dauerhafte Tailnet-Identität im Volume statt ephemeral |

Bei einem Start ohne Wayland, etwa per SSH auf einem Server, fällt das GUI-Overlay einfach weg.

Der Container-User heißt immer `devel` (Home: `/home/devel`), bekommt beim Build aber UID und GID des Host-Users. Ein Image gehört deshalb zu einem Host-User.

## Playwright mit Fenster

```bash
pnpm exec playwright install chromium   # Browser passend zur Projektversion, landet im cache-Volume
```

Headed Chromium (`headless: false`) erkennt Wayland selbst und braucht dafür kein Flag; getestet mit Chromium 156. Im Container gibt es kein X11, ein Fallback darauf ist also ausgeschlossen.

## Git und gh

Welche globale Git-Config der Container sieht, hängt davon ab, was im Config-Verzeichnis liegt (das devdock-Verzeichnis oder `$DEVDOCK_CONFIG`, siehe [Umgebungsvariablen](#umgebungsvariablen)):

1. **`./gitconfig` existiert:** Sie wird read/write eingebunden und gehört allein dem Container. `git config --global` und `gh auth setup-git` schreiben direkt hinein.
2. **Sonst** nimmt devdock die globale Git-Config des Hosts, und zwar nur die übertragbaren Teile: user.name/email, Aliase, delta, pull/push/merge/diff-Einstellungen, `url.*.insteadOf`, den gh-Credential-Helper und Ähnliches. Signing (`commit.gpgsign`, `user.signingkey`, `gpg.*`), Includes, Host-Pfade und `core.editor` fliegen raus. Die gefilterte Fassung wird bei jedem Start neu nach `.devdock/host.gitconfig` geschrieben und read-only eingebunden.

Mit `./devdock gitconfig` wird die gefilterte Host-Fassung einmalig als `./gitconfig` angelegt. Ab dann gilt Fall 1.

Technisch wird das Verzeichnis eingebunden, nicht die Datei, und `GIT_CONFIG_GLOBAL` zeigt auf die Datei darin. git schreibt nämlich über eine Lock-Datei und benennt sie danach um, und ein `rename` auf einen Datei-Bind-Mount scheitert. Im ersten Fall ist deshalb das devdock-Verzeichnis im Container unter `/opt/devdock-git` beschreibbar.

`delta` ist installiert, damit `core.pager` und `interactive.diffFilter` funktionieren. `gh` liegt zusätzlich unter `/usr/bin/gh`, weil der Credential-Helper diesen festen Pfad aufruft. Die Anmeldung läuft entweder über `GH_TOKEN` in `.env` oder einmalig über `gh auth login` im Container (das Token landet dann in `~/.config/gh` im Volume `devdock-home`).

Claude Code (`claude`) kommt ebenfalls über mise. Angemeldet wird einmalig mit `/login` im Container, alternativ per `ANTHROPIC_API_KEY` in `.env`. `CLAUDE_CONFIG_DIR` zeigt auf `~/.claude`, damit auch die `.claude.json` im Volume `devdock-home` landet und nicht im flüchtigen Home. Der eingebaute Auto-Updater ist abgeschaltet (`DISABLE_AUTOUPDATER=1`), neue Versionen bringt `./devdock build --upgrade` wie bei allen mise-Tools.

## Optionale Tools

Große oder selten gebrauchte Tools sind nicht im Image. Jedes hat ein `install-*`-Script, das es im Container ins Volume `devdock-addons` installiert. Weil alle Workspaces das Volume teilen, wird nur einmal installiert. Jedes Tool bekommt ein eigenes Unterverzeichnis in `~/.addons`, und die Pfade, die es selbst erwartet (`~/.hermes`, `~/.ok`), sind im Image als Symlinks dorthin angelegt. Die Befehle bringt das Image als Launcher mit; ohne Installation melden sie nur, welches `install-*` fehlt. Zurückgesetzt wird ein einzelnes Tool mit `rm -rf ~/.addons/<tool>`, `docker volume rm devdock-addons` nimmt alle mit.

### Hermes Agent

[Hermes Agent](https://hermes-agent.nousresearch.com) ist nicht im Image. Er braucht rund 3 GB und eine lange Installation, deshalb bleibt er optional: `install-hermes` im Container ruft den offiziellen Installer auf (ohne den Computer-Use-Treiber, der im Container nichts steuern könnte). Weitere Optionen reicht das Script an den Installer durch, etwa `install-hermes --skip-browser`. Hermes verwaltet sich selbst: Checkout, eigenes Python, Node, Chromium und ffmpeg liegen zusammen mit Config, `.env`, Sessions, Memories und Skills in `~/.hermes`. Das ganze Verzeichnis liegt deshalb im Volume (`~/.addons/hermes`).

Ist Hermes schon da, verweist `install-hermes` auf `hermes update`, das ihn im Volume aktualisiert; ein Rebuild ändert an der installierten Version nichts. Launcher gibt es für `hermes`, `hermes-acp` und `hermes-agent`. Eingerichtet wird einmalig mit `hermes setup` (Provider, API-Key), der Key landet in `~/.hermes/.env` im Volume. Das Messaging-Gateway lässt sich nicht als Dienst installieren (`hermes gateway install` braucht systemd), läuft aber mit `hermes gateway run` im Vordergrund, etwa in einem eigenen tmux-Fenster.

### OpenKnowledge

[OpenKnowledge](https://openknowledge.ai) ist ein Markdown-Editor für Wissensbasen, in dem Menschen und Agenten an denselben Dateien arbeiten. `install-openknowledge` installiert das npm-Paket `@inkeep/open-knowledge` mit eigenem Prefix nach `~/.addons/openknowledge/npm`; ein gewöhnliches `npm install -g` landete in der Node-Installation von mise und wäre mit dem Container weg. Erneut aufgerufen aktualisiert es, mit Argument auf eine bestimmte Version (`install-openknowledge 0.85.0`). Die globalen Daten (`~/.ok`: Config, Skills, Logs) liegen in `~/.addons/openknowledge/home`.

Der Launcher `ok` (auch `open-knowledge`) startet immer mit dem globalen Node aus `config/mise.toml`. Der `node`-Shim nähme sonst das Node, das ein Projekt im aktuellen Verzeichnis pinnt, und OpenKnowledge braucht mindestens Node 24.

Den MCP-Server startet die `.mcp.json`, die `ok init` ins Projekt schreibt. Ihr Script probiert nacheinander die macOS-App, das Linux-Paket unter `/opt/OpenKnowledge` und zuletzt `npx -y @inkeep/open-knowledge@latest`. Das Image legt dort, wo das Linux-Paket erwartet wird (`/opt/OpenKnowledge/resources/cli/bin/ok.sh`), einen Symlink auf den Launcher an. So nutzen Claude Code, Codex und OpenCode die mit `install-openknowledge` installierte Version, ohne die `.mcp.json` des Projekts anzufassen; auf macOS funktioniert sie unverändert. npx holte sonst bei jedem Start übers Netz die neueste Version, die von der des `ok`-Servers abweichen kann. Ist OpenKnowledge nicht installiert, bricht der MCP-Start mit dem Hinweis auf `install-openknowledge` ab, statt auf npx auszuweichen.

Die Web-App startet im Projekt mit `ok init` und `ok start --no-open-browser` (im Container gibt es keinen Browser, den `ok` öffnen könnte). Durch das Host-Netz ist sie direkt im Browser des Hosts erreichbar, in einem Tailscale-Workspace unter der URL, die `ok-autostart` nennt.

#### Autostart mit dem Container

```bash
ok activate          # Projekt eintragen und Server starten, Port: der erste freie ab 4700
ok activate 4711     # dito auf festem Port, ändert auch den Port eines eingetragenen Projekts
ok deactivate        # Projekt austragen und Server anhalten
ok-autostart         # eingetragene Projekte mit URL und Zustand
```

`ok activate` sucht vom aktuellen Verzeichnis aufwärts bis zum Workspace das nächste Projekt mit `.ok/config.yml` und trägt es in `<workspace>/.devdock/ok-autostart` ein: eine Zeile pro Projekt, Port und Pfad relativ zum Workspace. Ein Workspace kann mehrere Projekte haben, auch verschachtelte. Beim Container-Start startet `devdock-entrypoint` alle eingetragenen Server mit `ok start --no-open-browser --idle-shutdown off --port …`; ohne `--idle-shutdown off` beendete sich ein Server nach 30 Minuten ohne offenen Tab. Legt `ok activate` das Verzeichnis `.devdock/` an, schreibt es ein `.gitignore` mit `*` hinein, damit es nicht in `git status` auftaucht.

Die Registry liegt bewusst nicht in `<workspace>/.ok/config.yml`: Diese Datei macht den ganzen Workspace zum OpenKnowledge-Projekt, und `ok` in einem Unterverzeichnis ohne eigenes `.ok/` würde dann den ganzen Workspace als Projekt starten. Den Port setzt `ok-autostart` per `--port` und nicht über die Variable `PORT`, die auch Vite und andere Dev-Server lesen. Weil alle Container im Host-Netz laufen, muss der Port über alle Workspaces hinweg frei sein. `ok activate` prüft das für die laufenden Container; ein gestoppter Container, der denselben Port eingetragen hat, fällt erst bei seinem nächsten Start auf (`Port … ist belegt` in `devdock logs`).

Die interaktive Shell zeigt beim Start, welche Server auf welchem Port laufen. In tmux erscheint das nur im ersten Pane einer neuen Session. Die Ausgabe der Server landet in `$XDG_RUNTIME_DIR/ok-autostart/<port>.log`, Meldungen vom Container-Start in `devdock logs`.

Der Entrypoint bleibt als Elternprozess stehen, damit er die Server beim Stoppen des Containers per SIGTERM anhält (`stop_grace_period: 30s`). Ohne das bliebe nach dem SIGKILL von Docker `.ok/local/server.lock` mit der PID des Servers im Projekt liegen. Im nächsten Container gehört diese PID womöglich einem anderen Prozess: `ok start` hielte das Lock dann für aktiv, und `ok stop` beendete den fremden Prozess. Aus demselben Grund entfernt `ok-autostart` beim Container-Start ein Lock, auf dessen Port nichts lauscht, und hält nur Server an, die es selbst gestartet hat. `activate` und `deactivate` sind Unterbefehle des Launchers `ok` und keine von OpenKnowledge. Bekäme OpenKnowledge eigene Befehle mit diesen Namen, wären sie hinter dem Launcher versteckt; `ok-autostart activate` funktioniert in jedem Fall.

## Tailscale

Ein Workspace kann ins Tailnet, ohne dass der Host Tailscale bekommt. `devdock tailscale on` stellt ihn auf ein eigenes Netz um: Neben `dev` läuft dann ein Sidecar mit dem offiziellen Image `tailscale/tailscale`, und `dev` teilt dessen Netz-Namespace statt des Host-Netzes. Tailnet-Maschinen sind aus dem Container direkt erreichbar, auch per MagicDNS-Namen und mit Clients ohne Proxy-Unterstützung (`ssh`, `psql`, Go-Binaries). `NET_ADMIN` und `/dev/net/tun` bekommt nur der Sidecar, und beides wirkt nur in seinem Namespace.

```bash
devdock tailscale on 5173 4700   # einschalten, Ports auf localhost des Hosts publizieren
devdock                          # erstellt den Container im neuen Netz
devdock tailscale login          # Login-URL zeigen (entfällt mit TS_AUTHKEY)
devdock tailscale status         # beliebige tailscale-Kommandos im Sidecar
devdock ports                    # wo welcher Server von außen erreichbar ist
devdock tailscale off            # zurück ins Host-Netz
```

`on` und `off` ändern nur `<workspace>/.devdock/tailscale` (ein Port pro Zeile, `#` für Kommentare, von Hand editierbar). Wirksam wird das beim nächsten `devdock`, das den Container dafür neu erstellt; laufende tmux-Sessions enden dabei. `on` mit Ports ersetzt die Liste, ohne Ports bleibt sie.

Jeder Workspace ist ein eigener Node namens `devdock-<workspace>` (auf 63 Zeichen gekürzt). Bis zum Login wartet der Sidecar (`TS_BOOT_TIMEOUT`); `dev` erreicht bis dahin das Internet, aber nicht das Tailnet. Mit `TS_AUTHKEY` in `.env` meldet sich ein Workspace ohne Login-URL an; weil `.env` für alle Workspaces gilt, muss der Key *reusable* sein. Er landet nur im Sidecar, nicht im Environment von `dev`. Auth-Keys darf allerdings nur erzeugen, wer im Tailnet eine Admin-Rolle hat.

Per Default ist der Node **ephemeral**: `tailscaled` hält seinen Zustand im Speicher, meldet sich beim Anhalten selbst ab, und Tailscale entfernt ihn spätestens eine Stunde, nachdem er offline gegangen ist. Im Tailnet bleibt so nichts zurück, auch ohne Admin-Rechte. Dafür braucht jeder neue Container (nach `devdock down`, Reboot oder Image-Update) einen neuen Login. Startet ein Workspace, bevor sein alter Node verschwunden ist, hängt Tailscale an den Namen ein Suffix an.

`devdock tailscale on --persistent` macht die Identität dauerhaft: Sie liegt dann im Volume `<projekt>_tailscale-state` und übersteht `devdock down` und `devdock tailscale off`; `on --ephemeral` schaltet zurück. `devdock tailscale forget` meldet den Node ab und löscht das Volume, `destroy --volumes` meldet die Nodes ebenfalls erst ab; `devdock tailscale logout` meldet ab und lässt das Volume stehen. Abmelden heißt bei einem dauerhaften Node nur, dass sein Login verfällt: Der Eintrag bleibt im Tailnet stehen, bis ein Admin ihn entfernt. Sofort verschwinden nur ephemeral Nodes. Ohne Admin-Rechte hinterlässt deshalb allein der Default keine Spuren. Abgemeldet wird jeweils bei angehaltenem Workspace mit einem kurzlebigen `tailscaled`: `containerboot` im Sidecar beendet sich, sobald der Node den Zustand „Running“ verlässt, und bräche einen Logout von innen ab, bevor der Server ihn bestätigt. Aus demselben Grund beendet `devdock tailscale down` den Sidecar samt Netz von `dev`; vorübergehend raus geht es mit `devdock tailscale off` oder `devdock down`. Verschwindet das Volume ohne Abmelden (`docker volume rm`), bleibt der Login des Nodes gültig, bis sein Key abläuft, obwohl niemand ihn mehr benutzen kann.

Der Node ist im Tailnet auch erreichbar: Server in `dev`, die auf `0.0.0.0` lauschen (`vite --host`, Debugger, Datenbanken), sieht jeder Peer, den die ACLs des Tailnets durchlassen, bei der Default-ACL also alle. Server auf `127.0.0.1` bleiben dem Tailnet verborgen, die Weiterleitung gilt nur für die Bridge. Wer nur hinausgreifen will, setzt `TS_EXTRA_ARGS=--shields-up` in `.env`; dann nimmt der Node keine eingehenden Verbindungen an, auch kein `tailscale ssh` und `serve`.

Der Preis ist `localhost`:

| Richtung | Host-Netz | Tailscale-Workspace |
| --- | --- | --- |
| Host → Server im Container | `localhost:PORT` | `localhost:PORT` für publizierte Ports, sonst die Bridge-IP (`devdock ports`) |
| Container → Dienst auf dem Host | `localhost:PORT` | `host.docker.internal:PORT` |
| Container → per `docker run -p` gestarteter Dienst | `localhost:PORT` | `host.docker.internal:PORT` |

Server, die nur auf `127.0.0.1` lauschen (Vite, Next und viele andere per Default), sind trotzdem erreichbar: Der Sidecar leitet neue TCP-Verbindungen von seinem Bridge-Interface auf den Loopback weiter (`iptables-nft … DNAT --to-destination 127.0.0.1` samt `route_localnet`, nur in seinem Namespace). Die Weiterleitung kennt nur IPv4, deshalb ist IPv6 im Tailscale-Workspace aus: Node bindet `localhost` sonst an `[::1]`, und den erreicht von außen nichts. Damit fehlt auch die IPv6-Adresse im Tailnet. Die Shell nennt beim Start Node-Name, Tailnet-IP und Bridge-IP, `ok-autostart` die URL, unter der der Host OpenKnowledge erreicht. Weil jeder Tailscale-Workspace ein eigenes Netz hat, dürfen dort zwei Workspaces denselben Port benutzen, solange er nicht publiziert ist.

`dev` hängt am Namespace des Sidecars. Wird der Sidecar allein neu gestartet (`docker restart`), verliert `dev` sein Netz; dann hilft `devdock down` und `devdock`. Fehlt auf dem Host `/dev/net/tun` (Kernel-Modul `tun`), startet der Workspace nicht, bis `devdock tailscale off` ihn zurückstellt.

## Umgebungsvariablen

`cp .env.example .env` und ausfüllen. Alles aus `.env` landet als Umgebungsvariable im Container. `.env`, `gitconfig` und `.devdock/` sind gitignored.

Zwei Variablen auf dem Host verlegen die lokale Config aus dem Repo heraus:

- `DEVDOCK_CONFIG` ist das Verzeichnis für `.env`, `gitconfig` und das generierte `.devdock/host.gitconfig`. Ist sie gesetzt, liest devdock nichts davon mehr aus dem Repo, auch nicht als Rückfall. Das Verzeichnis muss existieren.
- `DEVDOCK_ENV` zeigt auf die Datei mit den Variablen für den Container und ersetzt damit `$DEVDOCK_CONFIG/.env` bzw. `./.env`. Die Datei muss existieren.

```bash
export DEVDOCK_CONFIG=~/.config/devdock
DEVDOCK_ENV=~/secrets/work.env devdock -w ~/work/project
```

Relative Pfade gelten ab dem aktuellen Verzeichnis.

`./devdock` reicht die gewählte `.env` außerdem als `--env-file` an Compose weiter. Ihre Variablen stehen damit auch beim Build bereit, was `DEVDOCK_NEOVIM_CONFIG` braucht. Gibt es die Datei nicht, liest Compose gar keine, auch nicht die `.env` im Repo.

### Neovim-Config

```bash
# .env
DEVDOCK_NEOVIM_CONFIG=https://github.com/you/nvim-config
```

`DEVDOCK_NEOVIM_CONFIG` ist das Git-Repo, das der Build nach `~/.config/nvim` klont, bevor er Plugins und Mason-Tools installiert. Ohne die Variable (oder leer) ist es [nvim-config-next](https://github.com/spearwolf/nvim-config-next). Geklont wird beim Build ohne SSH-Agent und ohne Token; das Repo muss also per HTTPS öffentlich erreichbar sein. Gesetzt in der Shell des Hosts, gewinnt die Variable gegenüber `.env`.

Wirksam wird ein neuer Wert mit `./devdock build`; Docker baut dabei erst ab dem Neovim-Layer neu. Im Home-Volume ändert das allein nichts, denn `devdock-entrypoint` kopiert nur, was dort ganz fehlt (siehe [Home-Volume](#home-volume)). Zum Wechseln im Container `rm -rf ~/.config/nvim ~/.local/share/nvim ~/.local/state/nvim`, dann `./devdock down` und `./devdock`. Weil alle Workspaces das Volume teilen, gilt die neue Config danach überall.

## Hinweise

- Beim ersten `git clone git@github.com:…` fragt ssh nach dem Host-Key, weil im Container keine `known_hosts` existiert. Ohne SSH-Agent geht Git über HTTPS und den gh-Credential-Helper (`git clone https://github.com/…`).
- `config/mise.toml` steht auf `latest`. `./devdock build` holt nur dann neue Versionen, wenn der Layer neu gebaut wird. `./devdock build --upgrade` erzwingt das ab dem mise-Layer; apt-Pakete und Basis-Setup bleiben im Cache. Danach baut Docker allerdings auch die späteren Layer neu (Playwright-Deps, Neovim-Plugins). `--no-cache` baut alles neu.
- `config/` ist read-only unter `/opt/devdock/config` gemountet. Von dort kopiert `devdock-entrypoint` die Starship-Config einmalig ins Home-Volume.
- `w` wechselt in den Workspace, `w src/lib` in ein Verzeichnis darin. Der Prompt zeigt den Workspace-Pfad als dessen Namen (`devdock/bin` statt `/home/…/devdock/bin`). Dafür steht in `directory.substitutions` der Starship-Config `'$DEVDOCK_WORKSPACE' = '$DEVDOCK_NAME'`. Starship selbst kennt keine Variablen; die Shell setzt beide in eine Kopie unter `$XDG_RUNTIME_DIR` ein und erneuert sie, sobald `~/.config/starship.toml` sich ändert.
