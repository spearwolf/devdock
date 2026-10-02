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
ENV PATH=/home/${USERNAME}/.local/share/mise/shims:${PNPM_HOME}:/home/${USERNAME}/.cargo/bin:/home/${USERNAME}/go/bin:/home/${USERNAME}/.bun/bin:/home/${USERNAME}/.local/bin:${PATH}

# Volumes werden beim ersten Anlegen mit Inhalt und Ownership dieser Pfade
# initialisiert — ohne sie gehörten atuin- und cache-Volume root.
RUN mkdir -p ~/.local/share/atuin ~/.cache ~/.config/gh

# Die Starship-Config kommt live aus dem gemounteten config/ des devdock-Repos
# (compose.yml). Gemountet wird das Verzeichnis, nicht die Datei: Editoren
# speichern per rename, und ein Datei-Bind-Mount sähe danach den alten Inode.
RUN ln -s /opt/devdock/config/starship.toml ~/.config/starship.toml

COPY --chown=${USER_UID}:${USER_GID} config/mise.toml /home/${USERNAME}/.config/mise/config.toml
RUN <<EOF
set -eux
mise install --yes
mise reshim
# Die Host-.gitconfig ruft "/usr/bin/gh auth git-credential" mit festem Pfad auf
sudo ln -s "$HOME/.local/share/mise/shims/gh" /usr/bin/gh
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

# Neovim-Config inkl. Plugins (vim.pack) und Mason-Tools vorinstallieren
RUN <<EOF
set -eux
git clone https://github.com/spearwolf/nvim-config-next ~/.config/nvim
nvim --headless '+qa'
nvim --headless -c 'MasonToolsInstallSync' -c 'qa'
EOF

CMD ["sleep", "infinity"]
