# Assistente IT

Read `docs/STATO-PROGETTO.md`, `docs/Sviluppo-Moduli.md` and the documentation
for the module being changed before editing. Inspect the current `main` and
manifest; a previous chat or local copy may be behind the repository.

- Windows PowerShell 5.1, WinForms, STA. Preserve UTF-8 BOM and CRLF in existing
  PowerShell files; Italian strings in new PowerShell files also need a BOM.
- Authenticate only through the bottom Accesso button in the suite wrapper.
  Feature actions assert the existing delegated session. No certificate mode,
  incremental-consent dialogs, automatic module installation or app fallback.
- Keep read and write access separate in the manifest, UI and backend. Optional
  Entra groups can restrict each module further. Graph roles still govern the
  actual operation; do not prove a write permission with a destructive probe.
- GLPI 10.0.11, native APIs, no extra plugins. Use serial-first matching when
  Intune supplies a usable serial. Preserve ambiguity and source failures.
- Never overwrite existing GLPI notes. BitLocker archives append readable notes
  and verify readback. Never log recovery passwords or tokens, or use real keys
  in test data. Preserve the V1 archive reader.
- Reuse the Computer Explorer removal/BitLocker pipeline. Use exact selected
  Object IDs, fresh identity checks and explicit confirmations. No recursive AD
  deletion and no weakening of protected-object checks for deletion.
- For Ring assignments use Entra object IDs, all configured monitored groups,
  manual destination selection and a fresh membership check. Never silently
  skip an unreadable group or move/remove existing memberships.
- Do not operate on the company's live devices or GLPI data for verification.
  Use isolated fixtures, native Windows UI tests and installer/OTA checks.
- Follow `docs/Versionamento.md`. One product version in `assistente-it.json`;
  no version increments per commit. Coordinate changes to shared files between
  module branches and rebase/recheck after another module is merged.
- Update the runtime allowlist when adding runtime files. A passing source
  test alone does not prove a file is included in the installer.
- Before publishing an authorized release, wait for Windows and installer CI;
  then verify the public release, canonical update feed and downloaded hashes.
- Update module documentation and the handoff state with completed work,
  validation and any remaining environment-specific checks. Do not store secrets
  or technician/device personal data in handoff documents.
