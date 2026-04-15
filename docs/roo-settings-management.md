# Roo Code settings — programmatic management

## Where Roo stores config

Inside VSCodium (`~/.config/VSCodium-second-opinion/User/globalStorage/`):

- `state.vscdb` — SQLite. Key `RooVeterinaryInc.roo-cline` holds non-sensitive global state (model catalogs, allowed commands, UI toggles). Readable as JSON.
- `state.vscdb` — Key `secret://…roo_cline_config_api_config` holds **the full provider profile** (base URL, model, all advanced flags, and the API key). **Encrypted** via VS Code's `secretStorage`, which delegates to libsecret / gnome-keyring on Linux. Not editable with plain SQLite writes.
- `User/globalStorage/rooveterinaryinc.roo-cline/settings/custom_modes.yaml` — plaintext YAML, safe to edit directly.
- `User/globalStorage/rooveterinaryinc.roo-cline/settings/mcp_settings.json` — plaintext JSON, safe to edit directly.

**Consequence:** provider profiles cannot be edited by tweaking files under `globalStorage/` alone, because the value is ciphertext. You can only read/write provider profiles via Roo itself.

## The supported programmatic path: `autoImportSettingsPath`

Roo Code exposes a VSCode setting, `roo-cline.autoImportSettingsPath`. Set it
to a path (absolute or `~/…`) to a Roo export JSON file. On every editor start,
Roo reads that file and merges its contents into the live config.

The JSON file format is exactly what Roo's **Settings → Export** produces.
It contains:

- All API provider profiles (base URL, model, advanced flags)
- Global settings (UI prefs, modes, context settings)
- **API keys in plaintext** — treat the file as a secret. `.gitignore` it.

Merge behavior on import: adds new profiles, updates existing ones by name,
does not delete profiles that exist in the live config but not the file.

### One-time bootstrap

1. Configure the provider manually in the Roo UI (Settings → Providers).
2. Save.
3. Settings → Export → save to `~/second-opinion-secrets/roo-settings.json`
   (outside the repo, since it contains the API key in plaintext).
4. Add to `~/.config/VSCodium-second-opinion/User/settings.json`:

   ```json
   {
     "roo-cline.autoImportSettingsPath": "~/second-opinion-secrets/roo-settings.json"
   }
   ```

5. From now on, edit `roo-settings.json` directly. Restart VSCodium to apply.

### For second-opinion specifically

Our local provider has no real API key (llama-server ignores it), so a
placeholder like `"local"` is fine. That means the export JSON is effectively
not secret — we could keep a *template* in the repo with the placeholder key
and the personal copy outside the repo. If the workflow only ever points at
local llama-server, the file can live in the repo.

Recommended layout:

- `configs/roo-settings.json` — committed, contains the non-secret local
  provider profile with `"apiKey": "local"` placeholder.
- `~/.config/VSCodium-second-opinion/User/settings.json` sets
  `"roo-cline.autoImportSettingsPath": "<repo>/configs/roo-settings.json"`.

If a profile that *does* need a real key is ever added, move the file out of
the repo and update the autoImport path.

## Custom modes — separate mechanism

`.roo/modes/*.yaml` in this repo are the source of truth. Copy/merge them into
`~/.config/VSCodium-second-opinion/User/globalStorage/rooveterinaryinc.roo-cline/settings/custom_modes.yaml`
via a script — they are not part of the settings export/import flow.

## MCP servers — separate mechanism

`mcp_settings.json` is plaintext and directly editable in the same
`settings/` folder. Not part of export/import.
