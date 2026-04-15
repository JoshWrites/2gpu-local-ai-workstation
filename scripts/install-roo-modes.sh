#!/usr/bin/env bash
set -euo pipefail

# Merge the repo's .roo/modes/*.yaml into the isolated VSCodium's
# custom_modes.yaml. Idempotent: replaces any existing mode with the
# same slug; leaves other modes untouched.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${HOME}/.config/VSCodium-second-opinion/User/globalStorage/rooveterinaryinc.roo-cline/settings/custom_modes.yaml"
VENV_PY="${REPO_DIR}/.venv/bin/python"

if [[ ! -x "$VENV_PY" ]]; then
  echo "Repo venv missing at ${VENV_PY}. Run the bootstrap first." >&2
  exit 1
fi

# Install PyYAML if not present in the venv.
"$VENV_PY" -c "import yaml" 2>/dev/null || "${REPO_DIR}/.venv/bin/pip" install --quiet pyyaml

"$VENV_PY" - <<PY
import yaml, pathlib, sys

repo_modes_dir = pathlib.Path("${REPO_DIR}/.roo/modes")
target = pathlib.Path("${TARGET}")

if not target.exists():
    print(f"Target missing: {target} — launch the isolated VSCodium once first.", file=sys.stderr)
    sys.exit(1)

with target.open() as f:
    doc = yaml.safe_load(f) or {}
modes = doc.get("customModes", []) or []
by_slug = {m["slug"]: m for m in modes}

incoming = []
for path in sorted(repo_modes_dir.glob("*.yaml")):
    with path.open() as f:
        m = yaml.safe_load(f)
    if not isinstance(m, dict) or "slug" not in m:
        print(f"Skipping malformed {path}", file=sys.stderr)
        continue
    incoming.append(m)

for m in incoming:
    by_slug[m["slug"]] = m

doc["customModes"] = list(by_slug.values())
with target.open("w") as f:
    yaml.safe_dump(doc, f, sort_keys=False)

print(f"Installed {len(incoming)} mode(s) into {target}")
for m in incoming:
    print(f"  - {m['slug']}: {m.get('name', '')}")
PY
