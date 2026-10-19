# Codex Account Switcher

A portable PowerShell launcher for switching between saved Codex CLI ChatGPT accounts. The launcher folder can be moved or shared; account credentials stay in the current Windows user's local profile.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7
- Codex CLI installed and available as `codex` on `PATH`
- ChatGPT sign-in for Codex CLI accounts whose usage limits you want to display

## Start it

Double-click `Run-CodexAccountSwitcher.cmd` to open the menu in a PowerShell window, or open PowerShell in this folder and run:

```powershell
.\CodexAccountSwitcher.ps1
```

On first run, the switcher adds the current default Codex profile (`%USERPROFILE%\.codex`) to the list. Choose **A** to add another account. Each added account gets a separate Codex home and requires a one-time browser sign-in. Choose its number to open Codex in the folder from which you launched the switcher.

The menu refreshes usage for each profile when it opens. It displays the rate-limit windows returned by Codex, including used percentage, remaining percentage, and reset time. A window is labeled weekly or daily only when Codex reports that duration. Some accounts may return different windows or no data; those are shown as reported.

## Move or share the folder

The switcher keeps its account list and profile homes under:

```text
%LOCALAPPDATA%\CodexAccountSwitcher\
```

This state is separate from this folder, so moving the launcher on the same computer preserves your accounts. When you copy the launcher to another computer, install Codex CLI there and add/sign in to the accounts on that computer. Do not copy or share the `CodexAccountSwitcher` data folder: Codex auth files contain credentials and should be treated like passwords.

## Usage data and compatibility

Usage comes from the local Codex App Server's `account/rateLimits/read` request. The App Server interface is experimental and can change between Codex CLI releases. If usage cannot be read, the switcher still lets you open that profile and labels its usage as unavailable. It does not estimate a limit or store credentials in this launcher folder.

Profiles have separate Codex settings, sign-ins, and local conversation histories. The default profile points to `%USERPROFILE%\.codex`; added profiles use separate folders under the switcher's local app-data directory.
