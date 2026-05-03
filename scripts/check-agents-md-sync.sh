#!/usr/bin/env bash
# check-agents-md-sync.sh — compare AGENTS.md across the canonical repo
# copy, levine's deployed copy, and anny's deployed copy. Per
# docs/remote-user-setup.md A4, anny's must be a COPY (not a symlink)
# because opencode does not follow symlinks for global agent rules.

set -uo pipefail

CANONICAL="/home/levine/Documents/Repos/2gpu-local-ai-workstation/configs/opencode/AGENTS.md"
LEVINE="/home/levine/.config/opencode/AGENTS.md"
ANNY="/home/anny/.config/opencode/AGENTS.md"

hdr() { printf "\n\e[1m== %s ==\e[0m\n" "$*"; }
ok()  { printf "  \e[32m✓\e[0m %s\n" "$*"; }
bad() { printf "  \e[31m✗\e[0m %s\n" "$*"; }

show_one() {
  local label="$1" path="$2" need_sudo="$3"
  echo "  $label: $path"
  if [[ "$need_sudo" == "yes" ]]; then
    if ! sudo test -e "$path"; then echo "    MISSING"; return; fi
    sudo ls -la "$path" | sed 's/^/    /'
    sudo file "$path" | sed 's/^/    /'
    echo "    md5: $(sudo md5sum "$path" | awk '{print $1}')"
    echo "    size: $(sudo wc -c < "$path") bytes, $(sudo wc -l < "$path") lines"
  else
    if [[ ! -e "$path" ]]; then echo "    MISSING"; return; fi
    ls -la "$path" | sed 's/^/    /'
    file "$path" | sed 's/^/    /'
    echo "    md5: $(md5sum "$path" | awk '{print $1}')"
    echo "    size: $(wc -c < "$path") bytes, $(wc -l < "$path") lines"
  fi
}

hdr "Three copies of AGENTS.md"
show_one "canonical" "$CANONICAL" no
show_one "levine"    "$LEVINE"    no
show_one "anny"      "$ANNY"      yes

# Compare hashes
hdr "Hash comparison"
canonical_hash=$(md5sum "$CANONICAL" 2>/dev/null | awk '{print $1}')
levine_hash=$(md5sum "$LEVINE"       2>/dev/null | awk '{print $1}')
anny_hash=$(sudo md5sum "$ANNY"      2>/dev/null | awk '{print $1}')

if [[ "$canonical_hash" == "$levine_hash" ]]; then
  ok "canonical == levine"
else
  bad "canonical != levine (canonical=$canonical_hash levine=$levine_hash)"
fi

if [[ "$canonical_hash" == "$anny_hash" ]]; then
  ok "canonical == anny"
else
  bad "canonical != anny (canonical=$canonical_hash anny=$anny_hash)"
fi

# If anny diverges, show the diff
if [[ "$canonical_hash" != "$anny_hash" ]]; then
  hdr "Diff: canonical vs anny (first 60 lines)"
  sudo diff "$CANONICAL" "$ANNY" 2>&1 | head -60
fi

# Sanity: anny's should be a real file, not a symlink (per docs A4)
hdr "anny's copy: is it a real file (not a symlink)?"
if sudo test -L "$ANNY"; then
  bad "anny's AGENTS.md IS a symlink — opencode doesn't follow it. Replace with a copy."
  sudo readlink "$ANNY"
else
  ok "anny's AGENTS.md is a regular file"
fi
