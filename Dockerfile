# syntax=docker/dockerfile:1

# Statische docker-CLI samt compose- und buildx-Plugin. Der Daemon kommt vom Host.
FROM docker:cli AS docker-cli

FROM ubuntu:26.04

# Der User heißt devel, UID/GID werden beim Build an den Host-User angeglichen,
# damit Workspace, SSH-Agent- und Wayland-Socket ohne Rechte-Akrobatik funktionieren.
ARG USERNAME=devel
ARG USER_UID=1000
ARG USER_GID=1000

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

RUN <<EOF
set -eux
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl wget git git-lfs jq bat mc tmux openssh-client sudo less \
  build-essential pkg-config libssl-dev unzip zip xz-utils file procps iproute2 \
  ripgrep fd-find python3 python3-venv tzdata locales bash-completion \
  wl-clipboard wayland-utils fonts-dejavu-core fonts-noto-color-emoji
rm -rf /var/lib/apt/lists/*
# Ubuntu benennt bat und fd um
ln -s /usr/bin/batcat /usr/local/bin/bat
ln -s /usr/bin/fdfind /usr/local/bin/fd
git lfs install --system
EOF

COPY --from=docker-cli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker-cli /usr/local/libexec/docker/cli-plugins/ /usr/local/libexec/docker/cli-plugins/

RUN curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh

RUN <<EOF
set -eux
# ubuntu:26.04 bringt einen User "ubuntu" mit UID 1000 mit
userdel -r ubuntu 2>/dev/null || true
getent group "${USER_GID}" >/dev/null || groupadd -g "${USER_GID}" "${USERNAME}"
useradd -m -s /bin/bash -u "${USER_UID}" -g "${USER_GID}" "${USERNAME}"
echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${USERNAME}"
chmod 0440 "/etc/sudoers.d/${USERNAME}"
# XDG_RUNTIME_DIR: hier landet der Wayland-Socket des Hosts
install -d -m 0700 -o "${USER_UID}" -g "${USER_GID}" "/run/user/${USER_UID}"
EOF

USER ${USERNAME}
WORKDIR /home/${USERNAME}

ENV PNPM_HOME=/home/${USERNAME}/.local/share/pnpm
# Claude Code legt Login und Settings komplett in CLAUDE_CONFIG_DIR ab (auch die
# sonst in ~ liegende .claude.json), damit das Volume devdock-home alles fasst.
# Updates kommen über mise beim Rebuild, nicht vom eingebauten Updater.
ENV CLAUDE_CONFIG_DIR=/home/${USERNAME}/.claude \
    DISABLE_AUTOUPDATER=1
# Shims: erst die eigenen aus dem Volume (mise use -g, Projekt-Pins), dann die
# des Images (mise install --system).
ENV PATH=/home/${USERNAME}/.local/share/mise/shims:/usr/local/share/mise/shims:${PNPM_HOME}:/home/${USERNAME}/.cargo/bin:/home/${USERNAME}/go/bin:/home/${USERNAME}/.bun/bin:/home/${USERNAME}/.local/bin:${PATH}

# Das Volume devdock-cache übernimmt beim ersten Anlegen die Ownership dieses
# Pfads — ohne ihn gehörte es root. Die Unterverzeichnisse von devdock-home legt
# ./devdock an.
RUN mkdir -p ~/.cache

# Optionale Tools teilen sich das Volume devdock-addons (~/.addons), je eines pro
# Unterverzeichnis. Ihre gewohnten Pfade zeigen per Symlink dorthin. Ein neues
# Volume übernimmt die Unterverzeichnisse von hier, ein älteres nicht; deshalb
# legen die install-*-Scripts ihres zusätzlich selbst an.
RUN <<EOF
set -eux
mkdir -p ~/.addons/hermes ~/.addons/openknowledge/home ~/.addons/openknowledge/npm
ln -s .addons/hermes ~/.hermes
ln -s .addons/openknowledge/home ~/.ok
EOF

# Die Tools aus config/mise.toml gehören dem Image, nicht dem Home: mise
# installiert sie in seine System-Ebene (/etc/mise, /usr/local/share/mise),
# die das Volume über ~/.local nicht verdeckt. So bringt jeder Rebuild neue
# Versionen mit. Installiert wird als devel, damit rustup wie bisher nach
# ~/.rustup und ~/.cargo geht und nicht nach /root.
# Cache-Buster für "devdock build --upgrade": ein neuer Wert lässt den Cache ab
# hier verfallen, mise holt dann die aktuellen latest-Versionen.
ARG MISE_UPGRADE=
COPY config/mise.toml /etc/mise/config.toml
RUN <<EOF
set -eux
echo "mise upgrade: ${MISE_UPGRADE:-nein}"
sudo install -d -o "${USER_UID}" -g "${USER_GID}" /usr/local/share/mise
mise install --system --yes
# Die Host-.gitconfig ruft "/usr/bin/gh auth git-credential" mit festem Pfad auf
sudo ln -s /usr/local/share/mise/shims/gh /usr/bin/gh
EOF

COPY --chown=${USER_UID}:${USER_GID} config/bashrc /home/${USERNAME}/.bashrc.devdock
RUN <<EOF
set -eux
curl -fsSL -o ~/.bash-preexec.sh https://raw.githubusercontent.com/rcaloras/bash-preexec/master/bash-preexec.sh
echo 'source ~/.bashrc.devdock' >> ~/.bashrc
pnpm config set store-dir ~/.cache/pnpm-store --global
EOF

# Systembibliotheken für Playwright-Browser; die Browser selbst installiert das
# jeweilige Projekt passend zu seiner Playwright-Version (landen im cache-Volume).
RUN <<EOF
set -eux
npx -y playwright@latest install-deps chromium firefox
sudo rm -rf /var/lib/apt/lists/*
EOF

# Neovim-Config inkl. Plugins (vim.pack) und Mason-Tools vorinstallieren.
# Danach wandert alles, was der Build in ~/.config und ~/.local hinterlassen
# hat, in die Vorlage /opt/devdock/skel: Dort verdeckt das Volume devdock-home
# es nicht, und devdock-entrypoint kopiert fehlende Einträge ins Volume. Das mv
# steht im selben RUN wie Neovim, sonst läge dessen Inhalt (~360 MB) doppelt
# im Image; spätere Schritte dürfen in beide Pfade nichts mehr schreiben.
# NEOVIM_CONFIG: Git-Repo der Config, aus DEVDOCK_NEOVIM_CONFIG in der .env.
# Steht erst hier, damit ein anderer Wert nur ab diesem Layer neu baut.
ARG NEOVIM_CONFIG=
RUN <<EOF
set -eux
git clone "${NEOVIM_CONFIG:-https://github.com/spearwolf/nvim-config-next}" ~/.config/nvim
nvim --headless '+qa'
nvim --headless -c 'MasonToolsInstallSync' -c 'qa'
sudo install -d -o "${USER_UID}" -g "${USER_GID}" /opt/devdock/skel
mv ~/.config ~/.local /opt/devdock/skel/
EOF

# Optionale Tools installiert man im Container mit ihrem install-*-Script ins
# Volume devdock-addons; das Image bringt nur die Scripts und Launcher mit.
# Hermes Agent: Checkout, eigenes Python/Node/Chromium und Nutzerdaten in
# ~/.hermes, Updates über "hermes update". OpenKnowledge: npm-Paket samt ~/.ok;
# ok-autostart startet per "ok activate" eingetragene Projekte mit dem Container.
COPY bin/install-hermes bin/hermes bin/install-openknowledge bin/ok bin/ok-autostart \
  bin/devdock-net bin/devdock-entrypoint /usr/local/bin/
RUN <<EOF
set -eux
sudo ln -s hermes /usr/local/bin/hermes-acp
sudo ln -s hermes /usr/local/bin/hermes-agent
sudo ln -s ok /usr/local/bin/open-knowledge
# Die .mcp.json, die OpenKnowledge in Projekte schreibt, sucht das Linux-Paket
# hier; so startet der MCP-Server mit dem ok aus dem Volume statt per npx.
sudo mkdir -p /opt/OpenKnowledge/resources/cli/bin
sudo ln -s /usr/local/bin/ok /opt/OpenKnowledge/resources/cli/bin/ok.sh
EOF

# Der Entrypoint startet die eingetragenen OpenKnowledge-Server und hält sie
# beim Stoppen des Containers wieder an.
ENTRYPOINT ["devdock-entrypoint"]
CMD ["sleep", "infinity"]
