# devdock

Dev-Container auf Basis von Ubuntu 26.04 LTS. Er nutzt den Docker-Daemon, den SSH-Agent und das Wayland-Display des Hosts.

## Inhalt

| Quelle | Tools |
| --- | --- |
| mise (global, `config/mise.toml`) | node 26, pnpm 12, go, rust, neovim, tree-sitter, delta, gh, lazygit, lazydocker, atuin, opencode |
| apt | git, git-lfs, curl, jq, bat, mc, tmux, ripgrep, fd, build-essential, wl-clipboard |
| `docker:cli`-Image | docker, docker compose, docker buildx (nur CLI, der Daemon ist der des Hosts) |

Neovim startet mit [nvim-config-next](https://github.com/spearwolf/nvim-config-next). Die Plugins und Mason-Tools sind schon beim Build installiert. Für Playwright-Browser sind die Systembibliotheken vorinstalliert, die Browser selbst nicht (siehe unten).

## Benutzung

```bash
./devdock build              # Image bauen (einmalig bzw. für Updates)
./devdock                    # Container fürs aktuelle Verzeichnis, Login-Shell
./devdock -w ~/code/foo tmux # tmux-Session im Workspace ~/code/foo
./devdock exec pnpm test     # einzelnes Kommando
./devdock down               # Container des Workspaces stoppen und entfernen
```

Wer `devdock` in den `PATH` verlinkt (`ln -s $PWD/devdock ~/.local/bin/`), kann es aus jedem Projekt heraus aufrufen.

Der Workspace liegt im Container unter **demselben Pfad** wie auf dem Host. Dadurch funktionieren Bind-Mounts, die man von drinnen an den Host-Daemon schickt (`docker run -v $PWD:/src …`). Für jeden Workspace gibt es einen eigenen Container. Das Image `devdock:latest` und die Volumes `devdock-atuin` (Shell-History), `devdock-cache` (`~/.cache`: pnpm-Store, Go-Cache, Playwright-Browser) und `devdock-gh` (`~/.config/gh`: der gh-Login) teilen sich alle.

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

Der Container-User bekommt beim Build Namen, UID und GID des Host-Users. Ein Image gehört deshalb zu einem Host-User.

## Playwright mit Fenster

```bash
pnpm exec playwright install chromium   # Browser passend zur Projektversion, landet im cache-Volume
```

Headed Chromium (`headless: false`) erkennt Wayland selbst und braucht dafür kein Flag; getestet mit Chromium 153. Im Container gibt es kein X11, ein Fallback darauf ist also ausgeschlossen.

## Git und gh

Welche globale Git-Config der Container sieht, hängt davon ab, was im devdock-Verzeichnis liegt:

1. **`./gitconfig` existiert:** Sie wird read/write eingebunden und gehört allein dem Container. `git config --global` und `gh auth setup-git` schreiben direkt hinein.
2. **Sonst** nimmt devdock die globale Git-Config des Hosts, und zwar nur die übertragbaren Teile: user.name/email, Aliase, delta, pull/push/merge/diff-Einstellungen, `url.*.insteadOf`, den gh-Credential-Helper und Ähnliches. Signing (`commit.gpgsign`, `user.signingkey`, `gpg.*`), Includes, Host-Pfade und `core.editor` fliegen raus. Die gefilterte Fassung wird bei jedem Start neu nach `.devdock/host.gitconfig` geschrieben und read-only eingebunden.

Mit `./devdock gitconfig` wird die gefilterte Host-Fassung einmalig als `./gitconfig` angelegt. Ab dann gilt Fall 1.

Technisch wird das Verzeichnis eingebunden, nicht die Datei, und `GIT_CONFIG_GLOBAL` zeigt auf die Datei darin. git schreibt nämlich über eine Lock-Datei und benennt sie danach um, und ein `rename` auf einen Datei-Bind-Mount scheitert. Im ersten Fall ist deshalb das devdock-Verzeichnis im Container unter `/opt/devdock-git` beschreibbar.

`delta` ist installiert, damit `core.pager` und `interactive.diffFilter` funktionieren. `gh` liegt zusätzlich unter `/usr/bin/gh`, weil der Credential-Helper diesen festen Pfad aufruft. Die Anmeldung läuft entweder über `GH_TOKEN` in `.env` oder einmalig über `gh auth login` im Container (das Token landet dann im Volume `devdock-gh`).

## Umgebungsvariablen

`cp .env.example .env` und ausfüllen. Alles aus `.env` landet als Umgebungsvariable im Container. `.env`, `gitconfig` und `.devdock/` sind gitignored.

## Hinweise

- Beim ersten `git clone git@github.com:…` fragt ssh nach dem Host-Key, weil im Container keine `known_hosts` existiert.
- `config/mise.toml` steht auf `latest`. `./devdock build` holt nur dann neue Versionen, wenn der Layer neu gebaut wird; erzwingen lässt sich das mit `./devdock build --no-cache`.
