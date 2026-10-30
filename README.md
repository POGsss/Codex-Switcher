# Codex Account Switcher

A portable PowerShell launcher for switching between saved Codex CLI ChatGPT accounts on Windows and macOS. The launcher folder can be moved or shared; account credentials stay in the current user's local profile.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7 on Windows; PowerShell 7 (`pwsh`) on macOS
- Codex CLI installed and available as `codex` on `PATH`
- ChatGPT sign-in for Codex CLI accounts whose usage limits you want to display

## Start it

On Windows, double-click `Run-CodexSwitcher.cmd` or run this from PowerShell:

```powershell
.\CodexSwitcher.ps1
```

On macOS, install PowerShell 7 using [Microsoft's installation instructions](https://learn.microsoft.com/en-us/powershell/scripting/install/install-powershell-on-macos), open Terminal in this folder, and run:

```powershell
pwsh -NoProfile -File ./CodexSwitcher.ps1
```

The first profile is your existing Codex home (`%USERPROFILE%\.codex` on Windows or `~/.codex` on macOS), shown as **Personal**. Use `/add-account` to create another profile; each added account requires a one-time browser sign-in. On first switch, the launcher installs a `codex` command shim in the user's data folder and adds it to the user's PATH. On macOS, it adds the shim path to `~/.zprofile` (zsh), `~/.bash_profile` (bash), or a Fish config file. Restart terminal applications once so they pick up the shim's PATH entry.

The menu shows each account's returned rate-limit windows as usage bars, including used percentage, remaining percentage, and reset time. A window is labeled monthly, weekly, or daily only when Codex reports that duration. Some accounts may return different windows or no data; those are shown as reported.

The switcher uses a Codex CLI-style message prompt. Enter an account number to switch without opening Codex. Type a regular message to open Codex with that message for the selected account. Available commands:

```text
/help
/accounts
/switch <number>
/open
/resume
/add-account
/refresh-usage
/rename-account <number> <new label>
/shared-convo [on|off]
/quit
```

## Shared conversation history

By default, conversation history, session rollouts, and CLI command history are **shared across accounts**. Each profile keeps its own saved sign-in; while shared mode is active, the selected profile's auth file is copied into the shared Codex home for the CLI and synced back afterward. The switcher menu displays the current status directly below the title banner:
- `Shared conversations: [ON]` (Green): all accounts share the same conversation history.
- `Shared conversations: [OFF]` (Yellow): each account keeps its own private conversation history.

Commands:
- `/shared-convo on`: Turn on shared conversations.
- `/shared-convo off`: Turn off shared conversations (isolated per account).
- `/shared-convo`: Toggle between on and off instantly without reloading or refetching account limits.

When sharing is on, switch accounts and continue working in the same conversations:
- Use `/resume` in the switcher menu to open the session picker with the selected account.
- Conversations created by any account remain visible in the session picker across all accounts.
- Existing conversations from previously isolated profiles are automatically imported into the shared conversation store.

Turning sharing off makes each account use its own Codex home again. Shared conversations remain in the shared store and become available again when sharing is turned back on.

## Move or share the folder

The switcher keeps its account list and profile credentials under:

```text
Windows: %LOCALAPPDATA%\CodexAccountSwitcher\
macOS:   ~/Library/Application Support/CodexAccountSwitcher/
```

This state is separate from the launcher folder, so moving the launcher on the same computer preserves your accounts. When moving from Windows to Mac, install Codex CLI and PowerShell 7 on the Mac, run the switcher, then use `/add-account` to sign in to each account. Account state is stored separately per operating system, and the switcher does not import Windows sign-ins or conversation history. Do not copy or share the `CodexAccountSwitcher` data folder: Codex auth files contain credentials and should be treated like passwords.

## Usage data and compatibility

Usage comes from the local Codex App Server's `account/rateLimits/read` request. The App Server interface is experimental and can change between Codex CLI releases. If usage cannot be read, the switcher still lets you open that profile and labels its usage as unavailable. CLI launches use `--no-daemon` with separate account homes. The launcher does not estimate a limit or store credentials in the launcher folder.

Per-profile sign-ins are stored under the switcher's user data directory. In shared conversation mode, the conversation store is the `shared` subfolder there; in isolated mode, each account uses its own Codex home, including `~/.codex` for the Personal profile on macOS. The shared home also contains a copy of the active profile's auth file, so do not share the switcher's data folder with another person or PC.
