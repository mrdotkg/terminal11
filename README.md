# Terminal 11 - turnkey, agent-native CLI environment for Windows

```irm https://raw.githubusercontent.com/YOUR_GH_USER/terminal11/main/install.ps1 | iex```

# What it does
   * Creates a NEW Windows Terminal profile ("Terminal 11") + a dedicated PowerShell
     profile script, and (optionally) makes it the default profile.
   * NEVER touches your own $PROFILE files or your existing Windows Terminal profiles.
     The only edit to Windows Terminal's settings.json is the single "defaultProfile"
     line (backed up first, reverted by uninstall). Profile + color scheme are added
     through a Windows Terminal "fragment" file, so your settings.json stays yours.
   * Pure PowerShell 7. No PowerShell modules. No background service.
   * Idempotent: safe to run again; it reuses your previous answers.

# Environment variables (use these because `irm | iex` cannot take parameters)
| Variable | Description |
| -------- | -------- |
|`T11_YES=1`              | unattended: no prompts, use saved config (or recommended defaults|
|`T11_DRYRUN=1`           | show the summary of what would change, then stop|
|`T11_ACTION=uninstall`   | remove Terminal 11 (reverts default profile, removes fragment)|
|`T11_URL=<url>`          | where this script lives (used for `t11 update`)|


- Installer syntax is kept Windows PowerShell 5.1 compatible on purpose, so that running it from the stock "powershell" window can bootstrap PowerShell 7 first.
- Installer source is plain ASCII; all fancy glyphs are built from [char] codes.
