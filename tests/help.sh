#!/usr/bin/env bash
# Prüft, dass devdock --help ohne Docker funktioniert und mit dem Code im
# Gleichschritt bleibt: Jedes Kommando, jeder tailscale-Unterbefehl, jede
# Option und jede Host-Variable aus ./devdock muss in der Hilfe und in
# README.md vorkommen. Braucht kein docker.
set -euo pipefail

repo=$(readlink -f "$(dirname "${BASH_SOURCE[0]}")/..")
devdock=$repo/devdock
fails=0

pass() { echo "ok    $1"; }
fail() { echo "FAIL  $1"; fails=$((fails + 1)); }

# Ohne Docker-Socket und mit kaputtem Workspace: Die Hilfe darf an nichts davon hängen
for args in "-h" "--help" "help" "-w /nonexistent --help" "-w /nonexistent help"; do
  # shellcheck disable=SC2086
  if out=$(DOCKER_HOST=unix:///nonexistent "$devdock" $args 2>&1) && [[ $out == *"CHEAT SHEET"* ]]; then
    pass "devdock $args"
  else
    fail "devdock $args"
  fi
done

if DOCKER_HOST=unix:///nonexistent "$devdock" --hlep >/dev/null 2>&1; then
  fail "unbekannte Langoption scheitert"
else
  pass "unbekannte Langoption scheitert"
fi

help=$(DOCKER_HOST=unix:///nonexistent "$devdock" --help)
readme=$(<"$repo/README.md")

if [[ -z $(awk 'length > 79' <<<"$help") ]]; then
  pass "Hilfe passt in 80 Spalten"
else
  fail "Hilfe passt in 80 Spalten"
fi

# Die Dispatch-Zweige: case $cmd (zwei Leerzeichen) und tailscale_cmd (vier),
# plus die Kommandos, die schon vorher per $cmd == … abzweigen (gitconfig)
commands=$({
  grep -oE '^  [a-z]+\)' "$devdock" | tr -d ' )'
  grep -oE '\$cmd == [a-z]+' "$devdock" | cut -d' ' -f3 | grep -vx help
} | sort -u)
subcommands=$(sed -n '/^tailscale_cmd()/,/^}/p' "$devdock" | grep -oE '^    [a-z]+\)' | tr -d ' )')
options=$(grep -oE '^ +--?[a-z][a-z-]*( \| --?[a-z-]+)*\)' "$devdock" | grep -oE -- '--?[a-z][a-z-]*' | sort -u)
host_vars=$(grep -oE '\$\{DEVDOCK_[A-Z_]+:-\}' "$devdock" | grep -oE 'DEVDOCK_[A-Z_]+' | sort -u)

for c in $commands; do
  grep -qE "^  $c( |$)" <<<"$help" && pass "Hilfe: $c" || fail "Hilfe: Kommando $c fehlt"
  grep -qE "devdock $c\b" <<<"$readme" && pass "README: $c" || fail "README: devdock $c fehlt"
done
for c in $subcommands; do
  grep -qE "tailscale $c\b" <<<"$help" && pass "Hilfe: tailscale $c" || fail "Hilfe: tailscale $c fehlt"
  grep -qE "devdock tailscale $c\b" <<<"$readme" && pass "README: tailscale $c" || fail "README: devdock tailscale $c fehlt"
done
for o in $options; do
  grep -qF -- "$o" <<<"$help" && pass "Hilfe: $o" || fail "Hilfe: Option $o fehlt"
  grep -qF -- "$o" <<<"$readme" && pass "README: $o" || fail "README: Option $o fehlt"
done
for v in $host_vars; do
  grep -qw "$v" <<<"$help" && pass "Hilfe: $v" || fail "Hilfe: Variable $v fehlt"
  grep -qw "$v" <<<"$readme" && pass "README: $v" || fail "README: Variable $v fehlt"
done

((fails == 0)) || { echo "$fails Fehler"; exit 1; }
