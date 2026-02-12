# Codex DMG -> Windows

This repository provides a **Windows-only runner** that extracts the macOS Codex DMG and runs the Electron app on Windows. It unpacks `app.asar`, swaps mac-only native modules for Windows builds, and launches the app with a compatible Electron runtime. It **does not** ship OpenAI binaries or assets; you must supply your own DMG and install the Codex CLI.

## Requirements
- Windows 10/11
- Node.js
- 7-Zip (`7z` in PATH)
- If 7-Zip is not installed, the runner will try `winget` or download a portable copy
- Codex CLI installed (`npm i -g @openai/codex`)

## Quick Start
1. Place your DMG in the repo root (default name `Codex.dmg`).
2. Run:

```powershell
.\scripts\run.ps1
```

Or explicitly:

```powershell
.\scripts\run.ps1 -DmgPath .\Codex.dmg
```

Or use the shortcut launcher:

```cmd
run.cmd
```

## Account Switching (In App)
- The launcher now injects an in-app **Accounts** switcher (top-right in Codex).
- It uses the same homes as `codex-accounts` by default: `%USERPROFILE%\.codex-accounts\<account>`.
- Switching relaunches Codex with `CODEX_HOME` set to that account home and separate Electron data folders under it.
- On switch, it also syncs shared config from `%USERPROFILE%\.codex` (`config.toml` + `rules/`) into that account home, so MCP/rules updates follow your active account.

### Optional account flags
- `-Account <name>`: Start directly in a specific account profile.
- `-AccountsRoot <path>`: Override account homes root (default: `%USERPROFILE%\.codex-accounts`).
- `-SourceHome <path>`: Override shared source for config/rules sync (default: `%USERPROFILE%\.codex`).
- `-ListAccounts`: Print discovered accounts and exit.

The script will:
- Extract the DMG to `work/`
- Build a Windows-ready app directory
- Auto-detect `codex.exe`
- Launch Codex

## Notes
- This is not an official OpenAI project.
- Do not redistribute OpenAI app binaries or DMG files.
- The Electron version is read from the app's `package.json` to keep ABI compatibility.

## License
MIT (For the scripts only)
