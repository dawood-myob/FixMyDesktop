# FixMyDesktop

Switching between home and office monitors scrambles your desktop icons. **FixMyDesktop** puts them back in a tidy,
predictable layout with one double-click, or automatically every time your displays change.

- No install, no admin rights: just PowerShell (built into Windows) and a small C# helper compiled on the fly.
- Picks the **largest screen as it appears** (after display scaling, so a 1920×1200 laptop at 150% counts as 1280×800)
  when you have several, or the only screen if there is one. Ties go to the primary screen.
- Works with **mixed DPI scaling** (e.g. laptop at 150% + ultrawide at 100%).
- Every run saves a backup, so `-Restore` undoes it.

## The layout

```
┌───────────────────────────────────────────────────────────────┐
│ FOLDERS                                  SCRIPTS & TOOLS      │
│ (square-ish block,                       (.bat .cmd, plain    │
│  natural name order)                      console shortcuts)  │
│                                                               │
│                                                               │
│                                                               │
│                                                  APPS         │
│ SYSTEM ICONS   OTHER FILES                       (icon-rich   │
│ ♻ Recycle Bin  grouped by type                    shortcuts)  │
└───────────────────────────────────────────────────────────────┘
```

| Area | What goes there |
|---|---|
| Top-left | Folders and shortcuts to folders, natural order (`WOR-9` sorts before `WOR-10`) |
| Top-right | Scripts (`.bat .cmd .ps1 .vbs .wsf .sh .py`), shortcuts that launch them, and "plain" tool shortcuts (see below) |
| Bottom-right | App shortcuts with real icons (`.lnk .url .exe .appref-ms`) |
| Bottom-left | Recycle Bin in the corner, with This PC / Network etc. stacked above it |
| Bottom, next to Recycle Bin | Everything else, grouped by type (Images, Documents, Archives, ...) |

**Block shape:** each area is sized from its icon count. It is as close to a square as possible (13 icons → 4×4),
or a full rectangle when one fits (12 → 4×3, 6 → 3×2). Very large blocks are limited to a share of the screen height.

### Which shortcuts count as "plain tools"?

Shortcuts to home-built console or dev tools (e.g. `MyTool.exe - Shortcut`) look like command shortcuts, not apps, so they
join the scripts. A shortcut is a *plain tool* when its target is an `.exe` that either

- has **no embedded icon** (Windows shows its default generic icon), and the shortcut doesn't set its own icon, or
- is a command shell: `cmd.exe`, `powershell.exe`, `pwsh.exe`, `wsl.exe`, `bash.exe`, `wt.exe`.

Anything with a proper icon (Chrome, Postman, Node.js, ...) stays in the Apps block. Turn this off with
`"plainToolsGoWithScripts": false`.

## Quick start

1. Clone or download this repo.
2. Double-click **`Arrange-Desktop.cmd`**.

That's it. Run it whenever the desktop looks disturbed.

### Commands

Run these from a terminal in the repo folder (the `.cmd` launcher passes them on):

| Command | Effect |
|---|---|
| `Arrange-Desktop.cmd` | Arrange the desktop now |
| `Arrange-Desktop.cmd -DryRun` | Print the plan (icon → area → x/y), move nothing |
| `Arrange-Desktop.cmd -Restore` | Put icons back where they were before the last run |
| `Arrange-Desktop.cmd -Screen Primary` | Use the primary screen instead of the largest (or `-Screen 2` for monitor #2) |
| `Arrange-Desktop.cmd -Watch` | Stay running; re-arrange a few seconds after each display change or unlock |
| `Arrange-Desktop.cmd -InstallStartup` | Start `-Watch` hidden at every sign-in, so you never have to click anything |
| `Arrange-Desktop.cmd -UninstallStartup` | Remove the sign-in entry |

`-Watch` and `-InstallStartup` also accept `-SettleSeconds <n>` (default 5), the delay that lets Windows finish its own
rearranging before FixMyDesktop applies the layout.

> The launcher runs PowerShell with `-ExecutionPolicy Bypass` for that one process only, so scripts don't have to be
> enabled system-wide. If your organisation locks PowerShell down with Group Policy, see *Troubleshooting*.

## Configuration

Edit [`config.json`](config.json):

| Setting | Meaning |
|---|---|
| `folderColumns`, `scriptColumns`, `appColumns`, `otherColumns` | `0` = automatic square/rectangle shape. A number forces that many columns |
| `shortcutsToFoldersGoWithFolders` | `true`: a shortcut pointing at a folder is placed with the folders |
| `plainToolsGoWithScripts` | `true`: icon-less exe shortcuts and command shells are placed with the scripts |
| `commandShellNames` | Executables always treated as command shortcuts |
| `scriptExtensions` | Extensions treated as scripts |
| `appExtensions` | Extensions treated as apps |
| `otherGroups` | Named groups for remaining files, in display order. Unlisted extensions get their own group (e.g. `.iso files`) |

## Safety

- Only icon **positions** change. No files are moved, renamed or deleted.
- Before each arrange, previous positions are saved to `%LOCALAPPDATA%\FixMyDesktop\last-layout.json`
  (it holds the state before the most recent run).
- "Auto arrange icons" is switched off if it was on, because Windows can't place icons freely otherwise.
  "Align icons to grid" is paused while icons are placed (Explorer's grid starts at the top-left of the whole
  multi-monitor desktop, which would leave gaps at the chosen screen's edges) and switched back on afterwards.

## How it works

Desktop icons live in a `SysListView32` control owned by `explorer.exe`. `lib/DesktopNative.cs` uses the standard
list-view messages to read icon names and positions (through a small buffer allocated in Explorer's memory)
and to move each icon (`LVM_SETITEMPOSITION`).

1. Find the desktop list view (under `Progman`, or a `WorkerW` window when a wallpaper engine is in use).
2. Read each icon's display name, then match it to the real file on the user and public Desktop folders to learn its type.
   Shortcut targets are resolved so a shortcut to a `.bat` file counts as a script.
3. Pick the monitor and compute the icon cell size for **that** monitor's DPI (Explorer reports spacing at the system
   DPI, which is wrong for a monitor with a different scale).
4. Assign every icon a grid cell, move it, then read positions back. Windows nudges an icon away when another is dropped
   on its cell, so any stragglers are re-placed (up to 10 passes).

## Project layout

```
Arrange-Desktop.cmd     double-click launcher
Arrange-Desktop.ps1     classification, layout and CLI
config.json             tunable settings
lib/DesktopNative.cs    Win32 interop (desktop list view, monitors, icon counts, display-change watcher)
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| "running scripts is disabled" | Use `Arrange-Desktop.cmd` rather than the `.ps1` directly. If Group Policy enforces a policy, ask IT to allow it, or run the commands in the `.ps1` from an allowed host |
| "Run this from 64-bit PowerShell" | Launch via the `.cmd` (it picks 64-bit), or open *Windows PowerShell* (not the x86 one) |
| Icons are slightly off after switching screens | Run it again, or use `-Watch` / `-InstallStartup` |
| An icon is in the wrong area | Run `-DryRun` to see its category. Check its extension against `config.json`; shortcuts are classified by their target and icon |
| Wanted the old layout back | `Arrange-Desktop.cmd -Restore` |

## Requirements

Windows 10/11 with Windows PowerShell 5.1 (included). PowerShell 7 works too, but use the 64-bit build.
