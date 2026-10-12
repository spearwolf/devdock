# devdock

Dev-Container auf Basis von Ubuntu 26.04 LTS. Er nutzt den Docker-Daemon, den SSH-Agent und das Wayland-Display des Hosts.

## Inhalt

| Quelle | Tools |
| --- | --- |
| mise (global, `config/mise.toml`) | node 26, pnpm 12, go, rust, neovim, tree-sitter, delta, gh, lazygit, lazydocker, atuin, starship, zoxide, fzf, opencode, claude (Claude Code), uv, bun |
| apt | git, git-lfs, curl, jq, bat, mc, tmux, ripgrep, fd, build-essential, wl-clipboard |
| optional, per `install-*` im Container | [Hermes Agent](https://github.com/NousResearch/hermes-agent) (`hermes`, `install-hermes`), [OpenKnowledge](https://openknowledge.ai) (`ok`, `install-openknowledge`) |
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

Der Workspace liegt im Container unter **demselben Pfad** wie auf dem Host. Dadurch funktionieren Bind-Mounts, die man von drinnen an den Host-Daemon schickt (`docker run -v $PWD:/src …`). Für jeden Workspace gibt es einen eigenen Container. Das Image `devdock:latest` und die Volumes `devdock-atuin` (Shell-History), `devdock-cache` (`~/.cache`: pnpm-Store, Go-Cache, Playwright-Browser) `devdock-gh` (`~/.config/gh`: der gh-Login), `devdock-claude` (`~/.claude`: Login, Settings und Verlauf von Claude Code) und `devdock-addons` (`~/.addons`: optionale Tools samt Daten, siehe unten) teilen sich alle.

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

Bei einem Start ohne Wayland, etwa per SSH auf einem Server, fällt das GUI-Overlay einfach weg.

Der Container-User heißt immer `devel` (Home: `/home/devel`), bekommt beim Build aber UID und GID des Host-Users. Ein Image gehört deshalb zu einem Host-User.

## Playwright mit Fenster

```bash
pnpm exec playwright install chromium   # Browser passend zur Projektversion, landet im cache-Volume
```

Headed Chromium (`headless: false`) erkennt Wayland selbst und braucht dafür kein Flag; getestet mit Chromium 156. Im Container gibt es kein X11, ein Fallback darauf ist also ausgeschlossen.

## Git und gh

Welche globale Git-Config der Container sieht, hängt davon ab, was im devdock-Verzeichnis liegt:

1. **`./gitconfig` existiert:** Sie wird read/write eingebunden und gehört allein dem Container. `git config --global` und `gh auth setup-git` schreiben direkt hinein.
2. **Sonst** nimmt devdock die globale Git-Config des Hosts, und zwar nur die übertragbaren Teile: user.name/email, Aliase, delta, pull/push/merge/diff-Einstellungen, `url.*.insteadOf`, den gh-Credential-Helper und Ähnliches. Signing (`commit.gpgsign`, `user.signingkey`, `gpg.*`), Includes, Host-Pfade und `core.editor` fliegen raus. Die gefilterte Fassung wird bei jedem Start neu nach `.devdock/host.gitconfig` geschrieben und read-only eingebunden.

Mit `./devdock gitconfig` wird die gefilterte Host-Fassung einmalig als `./gitconfig` angelegt. Ab dann gilt Fall 1.

Technisch wird das Verzeichnis eingebunden, nicht die Datei, und `GIT_CONFIG_GLOBAL` zeigt auf die Datei darin. git schreibt nämlich über eine Lock-Datei und benennt sie danach um, und ein `rename` auf einen Datei-Bind-Mount scheitert. Im ersten Fall ist deshalb das devdock-Verzeichnis im Container unter `/opt/devdock-git` beschreibbar.

`delta` ist installiert, damit `core.pager` und `interactive.diffFilter` funktionieren. `gh` liegt zusätzlich unter `/usr/bin/gh`, weil der Credential-Helper diesen festen Pfad aufruft. Die Anmeldung läuft entweder über `GH_TOKEN` in `.env` oder einmalig über `gh auth login` im Container (das Token landet dann im Volume `devdock-gh`).

Claude Code (`claude`) kommt ebenfalls über mise. Angemeldet wird einmalig mit `/login` im Container, alternativ per `ANTHROPIC_API_KEY` in `.env`. `CLAUDE_CONFIG_DIR` zeigt auf `~/.claude`, damit auch die `.claude.json` im Volume `devdock-claude` landet und nicht im flüchtigen Home. Der eingebaute Auto-Updater ist abgeschaltet (`DISABLE_AUTOUPDATER=1`), neue Versionen bringt `./devdock build --upgrade` wie bei allen mise-Tools.

## Optionale Tools

Große oder selten gebrauchte Tools sind nicht im Image. Jedes hat ein `install-*`-Script, das es im Container ins Volume `devdock-addons` installiert. Weil alle Workspaces das Volume teilen, wird nur einmal installiert. Jedes Tool bekommt ein eigenes Unterverzeichnis in `~/.addons`, und die Pfade, die es selbst erwartet (`~/.hermes`, `~/.ok`), sind im Image als Symlinks dorthin angelegt. Die Befehle bringt das Image als Launcher mit; ohne Installation melden sie nur, welches `install-*` fehlt. Zurückgesetzt wird ein einzelnes Tool mit `rm -rf ~/.addons/<tool>`, `docker volume rm devdock-addons` nimmt alle mit.

### Hermes Agent

[Hermes Agent](https://hermes-agent.nousresearch.com) ist nicht im Image. Er braucht rund 3 GB und eine lange Installation, deshalb bleibt er optional: `install-hermes` im Container ruft den offiziellen Installer auf (ohne den Computer-Use-Treiber, der im Container nichts steuern könnte). Weitere Optionen reicht das Script an den Installer durch, etwa `install-hermes --skip-browser`. Hermes verwaltet sich selbst: Checkout, eigenes Python, Node, Chromium und ffmpeg liegen zusammen mit Config, `.env`, Sessions, Memories und Skills in `~/.hermes`. Das ganze Verzeichnis liegt deshalb im Volume (`~/.addons/hermes`).

Ist Hermes schon da, verweist `install-hermes` auf `hermes update`, das ihn im Volume aktualisiert; ein Rebuild ändert an der installierten Version nichts. Launcher gibt es für `hermes`, `hermes-acp` und `hermes-agent`. Eingerichtet wird einmalig mit `hermes setup` (Provider, API-Key), der Key landet in `~/.hermes/.env` im Volume. Das Messaging-Gateway lässt sich nicht als Dienst installieren (`hermes gateway install` braucht systemd), läuft aber mit `hermes gateway run` im Vordergrund, etwa in einem eigenen tmux-Fenster.

### OpenKnowledge

[OpenKnowledge](https://openknowledge.ai) ist ein Markdown-Editor für Wissensbasen, in dem Menschen und Agenten an denselben Dateien arbeiten. `install-openknowledge` installiert das npm-Paket `@inkeep/open-knowledge` mit eigenem Prefix nach `~/.addons/openknowledge/npm`; ein gewöhnliches `npm install -g` landete in der Node-Installation von mise und wäre mit dem Container weg. Erneut aufgerufen aktualisiert es, mit Argument auf eine bestimmte Version (`install-openknowledge 0.85.0`). Die globalen Daten (`~/.ok`: Config, Skills, Logs) liegen in `~/.addons/openknowledge/home`.

Der Launcher `ok` (auch `open-knowledge`) startet immer mit dem globalen Node aus `config/mise.toml`. Der `node`-Shim nähme sonst das Node, das ein Projekt im aktuellen Verzeichnis pinnt, und OpenKnowledge braucht mindestens Node 24.

Den MCP-Server startet die `.mcp.json`, die `ok init` ins Projekt schreibt. Ihr Script probiert nacheinander die macOS-App, das Linux-Paket unter `/opt/OpenKnowledge` und zuletzt `npx -y @inkeep/open-knowledge@latest`. Das Image legt dort, wo das Linux-Paket erwartet wird (`/opt/OpenKnowledge/resources/cli/bin/ok.sh`), einen Symlink auf den Launcher an. So nutzen Claude Code, Codex und OpenCode die mit `install-openknowledge` installierte Version, ohne die `.mcp.json` des Projekts anzufassen; auf macOS funktioniert sie unverändert. npx holte sonst bei jedem Start übers Netz die neueste Version, die von der des `ok`-Servers abweichen kann. Ist OpenKnowledge nicht installiert, bricht der MCP-Start mit dem Hinweis auf `install-openknowledge` ab, statt auf npx auszuweichen.

Die Web-App startet im Projekt mit `ok init` und `ok start --no-open-browser` (im Container gibt es keinen Browser, den `ok` öffnen könnte). Durch das Host-Netz ist sie direkt im Browser des Hosts erreichbar.

## Umgebungsvariablen

`cp .env.example .env` und ausfüllen. Alles aus `.env` landet als Umgebungsvariable im Container. `.env`, `gitconfig` und `.devdock/` sind gitignored.

## Hinweise

- Beim ersten `git clone git@github.com:…` fragt ssh nach dem Host-Key, weil im Container keine `known_hosts` existiert. Ohne SSH-Agent geht Git über HTTPS und den gh-Credential-Helper (`git clone https://github.com/…`).
- `config/mise.toml` steht auf `latest`. `./devdock build` holt nur dann neue Versionen, wenn der Layer neu gebaut wird. `./devdock build --upgrade` erzwingt das ab dem mise-Layer; apt-Pakete und Basis-Setup bleiben im Cache. Danach baut Docker allerdings auch die späteren Layer neu (Playwright-Deps, Neovim-Plugins). `--no-cache` baut alles neu.
- `config/` ist read-only unter `/opt/devdock/config` gemountet, `~/.config/starship.toml` ist ein Symlink darauf. Änderungen an `config/starship.toml` greifen ohne Rebuild beim nächsten Prompt.
