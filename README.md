# Nessus Tool

WinForms PowerShell operator console for Nessus Agent field deployments.

Stage network adapters safely, update antivirus signatures, install and link the Nessus Agent, collect audits, then restore IP settings and clean up.

**Version:** 2.1.0  
**Platform:** Windows (PowerShell 5.1+)  
**UI:** System.Windows.Forms

---

## Table of contents

- [What it does](#what-it-does)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Folder layout](#folder-layout)
- [Tabs overview](#tabs-overview)
- [Recommended workflow](#recommended-workflow)
- [Safety model](#safety-model)
- [Configuration files](#configuration-files)
- [Documentation](#documentation)
- [Troubleshooting (quick)](#troubleshooting-quick)

---

## What it does

| Capability | Description |
|------------|-------------|
| **IP staging** | Switch adapters to DHCP, APIPA, or custom static IPs with disk-backed restore points |
| **AV update** | Run offline `mpam-fe.exe` and show Windows Defender signature age |
| **Agent deploy** | Auto-detect newest `NessusAgent*.msi`, install, link to scanner, check status |
| **One-click suite** | AV → Install → Link in a single confirmed action |
| **Preflight** | Validate elevation, packages, connectivity, SSH, and remote `nessusd` before you start |
| **Cleanup** | Unlink, stop services, MSI uninstall, remove dirs/registry, optional McAfee purge |
| **Audit handoff** | Launch companion Software / System Collection scripts |
| **Restore** | List, export/import, and apply saved IP baselines from disk |

---

## Requirements

### Required

- Windows host with **PowerShell 5.1+**
- Run **as Administrator** for IP changes, installs, service control, and cleanup
- `Nessus_Tool.ps1` (this repo)

### Recommended packages (same folder or browsed paths)

| File | Purpose |
|------|---------|
| `NessusAgent*.msi` | Agent installer (newest match is used automatically) |
| `mpam-fe.exe` | Offline Windows Defender signature update |

### Optional

- **OpenSSH client** (`ssh.exe` on PATH) for remote RHEL scanner health / auto-fix
- Companion scripts in the tool folder:
  - `Software Collection.ps1`
  - `System Collection.ps1`
- Environment variable `NESSUS_LINK_KEY` to auto-fill the masked linking key

---

## Quick start

### Option A — Launcher (preferred)

1. Copy the tool folder to the target machine (include MSI / `mpam-fe.exe` if needed).
2. Right-click **`Launch_Nessus_Tool.bat`** → **Run as administrator**.
3. Open the **Preflight** tab and run checks before changing anything.

### Option B — PowerShell

```powershell
# Elevated PowerShell:
cd C:\Path\To\Nessus_Tool
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Nessus_Tool.ps1
```

### First-run checklist

1. Confirm the status strip says **ADMIN** (bottom of the window).
2. Open **Settings** → set scanner host / port / SSH user → **Save Settings**.
3. Place or browse to `NessusAgent*.msi` and `mpam-fe.exe`.
4. On **Agent Install + Link**, enter the linking key (or set `NESSUS_LINK_KEY`).
5. Run **Preflight**.

---

## Folder layout

```
Nessus_Tool/
├── Nessus_Tool.ps1              # Main application
├── Launch_Nessus_Tool.bat       # Elevated launcher
├── Tool_Config.example.json     # Sample settings (copy / edit as needed)
├── README.md
├── docs/                        # Full documentation
│   ├── USER_GUIDE.md
│   ├── CONFIGURATION.md
│   ├── TROUBLESHOOTING.md
│   └── CHANGELOG.md
│
├── Tool_Config.json             # Created at runtime (local settings)
├── IP_Baselines.json            # Created at runtime (IP restore points)
└── Nessus_Deployment_History.csv# Created at runtime (apply/restore history)
```

Runtime files (`Tool_Config.json`, `IP_Baselines.json`, history CSV, logs) are gitignored and stay on the operator machine.

---

## Tabs overview

| Tab | Purpose |
|-----|---------|
| **Preflight** | Elevation, packages, agent service, ICMP/TCP to scanner, SSH + remote `nessusd` |
| **Assign IP** | DHCP / APIPA / static with locked baselines (`IP_Baselines.json`) |
| **AV Update** | Run `mpam-fe.exe`; show product version and signature age |
| **Agent Install + Link** | Detect MSI, install, link, status, one-click deploy, remote service helpers |
| **Deep Cleanup** | Unlink, stop, uninstall, dirs/reg, full wizard, McAfee purge |
| **System Audit** | Hand off to Software / System Collection scripts |
| **Restore IP** | View / restore / delete / export / import baselines |
| **Settings** | Persist scanner, SSH, port, `nessuscli` path |

Right-hand panel: live log (Clear / Copy / Save), progress bar, Open Folder.

---

## Recommended workflow

### Deploy

1. **Preflight** → resolve FAIL / WARN items  
2. **Assign IP** → select adapter (baseline locks automatically) → apply profile  
3. **AV Update** → Run AV Update  
4. **Agent Install + Link** → Install + Link *(or One-Click suite)*  
5. **Check Agent Status** → confirm linked / syncing  

### Tear-down

1. **Restore IP** → revert selected baseline  
2. **Deep Cleanup** → unlink / uninstall / full wizard as needed  

See [docs/USER_GUIDE.md](docs/USER_GUIDE.md) for step-by-step detail per tab.

---

## Safety model

- **Baselines on disk:** First time you select an adapter, its live settings are written to `IP_Baselines.json` and **never silently overwritten**.
- **Recapture only on purpose:** Use **Recapture Baseline** (with confirmation) to replace a saved restore point.
- **Apply blocked without baseline:** IP changes refuse to run until a locked baseline exists.
- **Destructive confirms:** Cleanup, McAfee purge, clock change, and one-click deploy ask first; full cleanup uses a double confirm.
- **No key in config:** Linking keys are never written to `Tool_Config.json`. Use the masked field or `NESSUS_LINK_KEY`.
- **Elevation awareness:** Non-admin sessions are warned before privileged actions.

---

## Configuration files

| File | When created | Contents |
|------|--------------|----------|
| `Tool_Config.json` | First launch / Save Settings | Scanner host, SSH, port, dirs, `nessuscli` path |
| `IP_Baselines.json` | First adapter selection | Per-machine / per-adapter restore points |
| `Nessus_Deployment_History.csv` | After IP apply / restore | Timestamped history trail |

Example settings template: [`Tool_Config.example.json`](Tool_Config.example.json)  
Full field reference: [docs/CONFIGURATION.md](docs/CONFIGURATION.md)

---

## Documentation

| Document | Description |
|----------|-------------|
| [docs/USER_GUIDE.md](docs/USER_GUIDE.md) | Tab-by-tab operator guide and workflows |
| [docs/CONFIGURATION.md](docs/CONFIGURATION.md) | Config files, env vars, defaults |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Common failures and fixes |
| [docs/CHANGELOG.md](docs/CHANGELOG.md) | Version history / what’s new |

---

## Troubleshooting (quick)

| Symptom | Likely fix |
|---------|------------|
| Status strip says **NOT ELEVATED** | Relaunch with `Launch_Nessus_Tool.bat` as Administrator |
| No MSI found | Put `NessusAgent*.msi` in the Agent folder or Browse to it |
| Link fails | Check scanner IP/port in Settings; confirm linking key; run Preflight TCP test |
| Cannot apply IP | Select the adapter once so a baseline is captured and shows **LOCKED** |
| SSH checks fail | Install OpenSSH client; verify SSH key/password for the configured user |

More cases: [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)

---

## License / notes

Internal operations tooling. Use only on systems you are authorized to configure.  
Linking keys and scanner credentials are sensitive — do not commit real `Tool_Config.json` values or keys to source control.
