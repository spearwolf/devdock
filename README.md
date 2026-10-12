# devdock

Dev-Container auf Basis von Ubuntu 26.04 LTS. Er nutzt den Docker-Daemon, den SSH-Agent und das Wayland-Display des Hosts.

## Inhalt

| Quelle | Tools |
| --- | --- |
| mise (global, `config/mise.toml`) | node 26, pnpm 12, go, rust, neovim, tree-sitter, delta, gh, lazygit, lazydocker, atuin, starship, zoxide, fzf, opencode, claude (Claude Code), uv, bun |
| apt | git, git-lfs, curl, jq, bat, mc, tmux, ripgrep, fd, build-essential, wl-clipboard |
| GitHub-Release (`.deb`) | AppImageLauncher (v3-Beta, `ail-cli`, `AppImageLauncher`) |
| eigener Installer | [Hermes Agent](https://github.com/NousResearch/hermes-agent) (`hermes`) |
| `docker:cli`-Image | docker, docker compose, docker buildx (nur CLI, der Daemon ist der des Hosts) |

Neovim startet mit [nvim-config-next](https://github.com/spearwolf/nvim-config-next). Die Plugins und Mason-Tools sind schon beim Build installiert. Für Playwright-Browser sind die Systembibliotheken vorinstalliert, die Browser selbst nicht (siehe unten).

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
./devdock destroy            # alle devdock-Container und das Image löschen (fragt nach)
```

`status` und `destroy` sehen alle Workspaces, nicht nur den aktuellen. `status` markiert Container, die nach einem `build` noch auf dem alten Image laufen; die aktualisiert ein `./devdock down` mit anschließendem Neustart. `destroy` muss vor dem Image alle Container entfernen, auch laufende, sonst verweigert Docker das Löschen. Die Volumes bleiben dabei stehen, `destroy --volumes` nimmt auch sie mit (also gh- und Claude-Login, Shell-History und Caches). `-y` überspringt die Rückfrage.

Wer `devdock` in den `PATH` verlinkt (`ln -s $PWD/devdock ~/.local/bin/`), kann es aus jedem Projekt heraus aufrufen.

Der Workspace liegt im Container unter **demselben Pfad** wie auf dem Host. Dadurch funktionieren Bind-Mounts, die man von drinnen an den Host-Daemon schickt (`docker run -v $PWD:/src …`). Für jeden Workspace gibt es einen eigenen Container. Das Image `devdock:latest` und die Volumes `devdock-atuin` (Shell-History), `devdock-cache` (`~/.cache`: pnpm-Store, Go-Cache, Playwright-Browser) `devdock-gh` (`~/.config/gh`: der gh-Login), `devdock-claude` (`~/.claude`: Login, Settings und Verlauf von Claude Code) `devdock-hermes` (`~/.hermes`: Hermes Agent komplett, siehe unten) und `devdock-applications` (`~/Applications`: AppImages) teilen sich alle.

## Was vom Host kommt

`./devdock` prüft beim Start, was vorhanden ist, und hängt dafür das passende Overlay an:

| Overlay | Bedingung | Wirkung |
| --- | --- | --- |
| `compose.yml` | immer | Workspace, Docker-Socket (GID per `group_add`), Host-Netz, `/etc/localtime` |
| `compose.ssh.yml` | `SSH_AUTH_SOCK` gesetzt | nur der Agent-Socket, kein `~/.ssh`, keine Keys |
| `compose.wayland.yml` | `WAYLAND_DISPLAY` gesetzt | Wayland-Socket, Toolkit-Variablen für Wayland |
| `compose.gpu.yml` | Wayland + `/dev/dri` vorhanden | Render-Nodes samt video/render-Gruppe |
| `compose.x11.yml` | lokales `DISPLAY` mit Socket und `XAUTHORITY` | X11-Socket von XWayland und der Cookie, beides read-only |
| `compose.tmux.yml` | `~/.config/tmux/tmux.conf` oder `~/.tmux.conf` | tmux-Config, read-only |
| `compose.gitconfig.yml` | `./gitconfig` oder Host-Git-Config vorhanden | globale Git-Config (siehe unten) |
| `compose.git-ignore.yml` | `~/.config/git/ignore` vorhanden | globale ignore-Liste, read-only |

Bei einem Start ohne Wayland, etwa per SSH auf einem Server, fallen die GUI-Overlays einfach weg. Wayland- und X11-Socket sowie der X11-Cookie gehören zur laufenden Host-Session: Nach einem neuen Login am Host den Container mit `./devdock down` neu starten.

Der Container-User heißt immer `devel` (Home: `/home/devel`), bekommt beim Build aber UID und GID des Host-Users. Ein Image gehört deshalb zu einem Host-User.

## Playwright mit Fenster

```bash
pnpm exec playwright install chromium   # Browser passend zur Projektversion, landet im cache-Volume
```

Headed Chromium (`headless: false`) erkennt Wayland selbst und braucht dafür kein Flag; getestet mit Chromium 156. Weil für AppImages auch X11 im Container ist, entscheidet `XDG_SESSION_TYPE=wayland` aus `compose.wayland.yml`: Fehlt die Variable, nimmt Chromium X11.

## Git und gh

Welche globale Git-Config der Container sieht, hängt davon ab, was im devdock-Verzeichnis liegt:

1. **`./gitconfig` existiert:** Sie wird read/write eingebunden und gehört allein dem Container. `git config --global` und `gh auth setup-git` schreiben direkt hinein.
2. **Sonst** nimmt devdock die globale Git-Config des Hosts, und zwar nur die übertragbaren Teile: user.name/email, Aliase, delta, pull/push/merge/diff-Einstellungen, `url.*.insteadOf`, den gh-Credential-Helper und Ähnliches. Signing (`commit.gpgsign`, `user.signingkey`, `gpg.*`), Includes, Host-Pfade und `core.editor` fliegen raus. Die gefilterte Fassung wird bei jedem Start neu nach `.devdock/host.gitconfig` geschrieben und read-only eingebunden.

Mit `./devdock gitconfig` wird die gefilterte Host-Fassung einmalig als `./gitconfig` angelegt. Ab dann gilt Fall 1.

Technisch wird das Verzeichnis eingebunden, nicht die Datei, und `GIT_CONFIG_GLOBAL` zeigt auf die Datei darin. git schreibt nämlich über eine Lock-Datei und benennt sie danach um, und ein `rename` auf einen Datei-Bind-Mount scheitert. Im ersten Fall ist deshalb das devdock-Verzeichnis im Container unter `/opt/devdock-git` beschreibbar.

`delta` ist installiert, damit `core.pager` und `interactive.diffFilter` funktionieren. `gh` liegt zusätzlich unter `/usr/bin/gh`, weil der Credential-Helper diesen festen Pfad aufruft. Die Anmeldung läuft entweder über `GH_TOKEN` in `.env` oder einmalig über `gh auth login` im Container (das Token landet dann im Volume `devdock-gh`).

Claude Code (`claude`) kommt ebenfalls über mise. Angemeldet wird einmalig mit `/login` im Container, alternativ per `ANTHROPIC_API_KEY` in `.env`. `CLAUDE_CONFIG_DIR` zeigt auf `~/.claude`, damit auch die `.claude.json` im Volume `devdock-claude` landet und nicht im flüchtigen Home. Der eingebaute Auto-Updater ist abgeschaltet (`DISABLE_AUTOUPDATER=1`), neue Versionen bringt `./devdock build --upgrade` wie bei allen mise-Tools.

## Hermes Agent

[Hermes Agent](https://hermes-agent.nousresearch.com) installiert sich mit dem offiziellen Installer beim Build (ohne den Computer-Use-Treiber, der im Container nichts steuern könnte). Hermes verwaltet sich selbst: Checkout, eigenes Python, Node, Chromium und ffmpeg liegen zusammen mit Config, `.env`, Sessions, Memories und Skills in `~/.hermes`. Das ganze Verzeichnis ist deshalb das Volume `devdock-hermes`.

Das Image befüllt das Volume nur, wenn es neu angelegt wird. Danach aktualisiert sich Hermes mit `hermes update` im Volume, ein Rebuild ändert an der installierten Version nichts. Eingerichtet wird einmalig mit `hermes setup` (Provider, API-Key), der Key landet in `~/.hermes/.env` im Volume. Das Messaging-Gateway lässt sich nicht als Dienst installieren (`hermes gateway install` braucht systemd), läuft aber mit `hermes gateway run` im Vordergrund, etwa in einem eigenen tmux-Fenster.

## AppImages

AppImages laufen im Container ohne FUSE: `APPIMAGE_EXTRACT_AND_RUN=1` lässt sie sich bei jedem Start nach `/tmp` entpacken, statt sich zu mounten. Dafür braucht der Container weder `/dev/fuse` noch `CAP_SYS_ADMIN`; große AppImages starten dadurch langsamer.

AppImageLauncher ist installiert, aber nur eingeschränkt nutzbar:

- Die automatische Übernahme beim Starten eines AppImages läuft über binfmt_misc im Host-Kernel und ist im Container nicht aktiv. Aufgerufen wird explizit: `AppImageLauncher foo.AppImage` oder `ail-cli integrate foo.AppImage`.
- Integrierte AppImages landen in `~/Applications`, dem Volume `devdock-applications`; sie bleiben also erhalten und sind in allen Workspaces da. Die Menüeinträge und Icons unter `~/.local/share` liegen dagegen nur im Container und sind nach `./devdock down` weg. Der Host sieht beides nicht.
- Das gebündelte Qt kann nur X11. Die Fenster erscheinen über das XWayland des Hosts, dafür sorgt `compose.x11.yml`.

## Umgebungsvariablen

`cp .env.example .env` und ausfüllen. Alles aus `.env` landet als Umgebungsvariable im Container. `.env`, `gitconfig` und `.devdock/` sind gitignored.

## Hinweise

- Beim ersten `git clone git@github.com:…` fragt ssh nach dem Host-Key, weil im Container keine `known_hosts` existiert. Ohne SSH-Agent geht Git über HTTPS und den gh-Credential-Helper (`git clone https://github.com/…`).
- `config/mise.toml` steht auf `latest`. `./devdock build` holt nur dann neue Versionen, wenn der Layer neu gebaut wird. `./devdock build --upgrade` erzwingt das ab dem mise-Layer; apt-Pakete und Basis-Setup bleiben im Cache. Danach baut Docker allerdings auch die späteren Layer neu (Playwright-Deps, Neovim-Plugins). `--no-cache` baut alles neu.
- `config/` ist read-only unter `/opt/devdock/config` gemountet, `~/.config/starship.toml` ist ein Symlink darauf. Änderungen an `config/starship.toml` greifen ohne Rebuild beim nächsten Prompt.
