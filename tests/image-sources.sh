#!/usr/bin/env bash
# Prüft, dass image_sources in ./devdock genau die Repo-Dateien nennt, die das
# Dockerfile per COPY ins Image holt. Fehlt dort eine, merkt devdock nicht,
# wenn sich ihre Änderung noch nicht im Image befindet. Braucht kein docker.
set -euo pipefail

repo=$(readlink -f "$(dirname "${BASH_SOURCE[0]}")/..")
fails=0

pass() { echo "ok    $1"; }
fail() { echo "FAIL  $1"; fails=$((fails + 1)); }

# Quellen der COPY/ADD-Zeilen ohne --from: Fortsetzungszeilen zusammengefügt,
# Flags und das Ziel (letztes Wort) weg. Das Dockerfile selbst geht immer ein.
copied=$({
  echo Dockerfile
  awk '
    /\\$/ { sub(/\\$/, ""); buf = buf $0 " "; next }
    { line = buf $0; buf = ""; sub(/[ \t]+$/, "", line) }
    line ~ /^(COPY|ADD)[ \t]/ && line !~ /--from=/ {
      n = split(line, t, /[ \t]+/)
      for (i = 2; i < n; i++) if (t[i] !~ /^--/) print t[i]
    }' "$repo/Dockerfile"
} | sort -u)

listed=$(sed -n '/^image_sources=(/,/^)/p' "$repo/devdock" | sed '1d;$d' | tr -s ' ' '\n' | sed '/^$/d' | sort -u)

if [[ -z $copied || -z $listed ]]; then
  fail "COPY-Quellen und image_sources gefunden"
fi

while read -r f; do
  grep -qxF "$f" <<<"$listed" && pass "image_sources: $f" || fail "image_sources: $f fehlt (COPY im Dockerfile)"
done <<<"$copied"
while read -r f; do
  grep -qxF "$f" <<<"$copied" || fail "image_sources: $f kopiert das Dockerfile nicht"
  [[ -f $repo/$f ]] || fail "image_sources: $f ist keine Datei"
done <<<"$listed"

((fails == 0)) || { echo "$fails Fehler"; exit 1; }
