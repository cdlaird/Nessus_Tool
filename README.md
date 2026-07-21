# Nessus Tool

WinForms PowerShell operator console for Nessus Agent deployments: IP staging with safe restore points, AV signature updates, agent install/link, cleanup, and system audits.

**Version:** 2.1.0

## Requirements

- Windows with PowerShell 5.1+
- Run **as Administrator** for IP changes, installs, service control, and cleanup
- Optional: OpenSSH client (`ssh`) for remote RHEL scanner health checks
- Optional companion scripts in the same folder: `Software Collection.ps1`, `System Collection.ps1`
- Place `NessusAgent*.msi` and `mpam-fe.exe` in the tool folder (or browse to them in the UI)

## Quick start

```powershell
# From an elevated PowerShell prompt:
cd <path-to-this-folder>
powershell.exe -ExecutionPolicy Bypass -File .\Nessus_Tool.ps1
```

Or right-click `Launch_Nessus_Tool.bat` → **Run as administrator**.

## Tabs

| Tab | Purpose |
|-----|---------|
| **Preflight** | Elevation, package presence, agent install, ICMP/TCP to scanner, SSH + remote `nessusd` |
| **Assign IP** | DHCP / APIPA / static profiles with disk-backed baselines (`IP_Baselines.json`) |
| **AV Update** | Run `mpam-fe.exe`; show Defender signature age |
| **Agent Install + Link** | Auto-detect newest MSI, link (port configurable), one-click deploy suite |
| **Deep Cleanup** | Unlink, stop services, MSI uninstall, dirs/reg purge, full wizard, McAfee purge |
| **System Audit** | Hand off to Software/System Collection scripts |
| **Restore IP** | List/export/import baselines; restore or delete restore points |
| **Settings** | Persist scanner host, SSH, port, `nessuscli` path to `Tool_Config.json` |

## Safety features

- IP baselines are written to disk on first adapter selection and **never silently overwritten** (use Recapture to replace)
- Apply IP is blocked until a baseline exists
- Destructive actions require confirmation; full cleanup uses a double confirm
- Linking key is **not** stored in config — use the masked field or env var `NESSUS_LINK_KEY`
- Logs are timestamped; Clear / Copy / Save from the right-hand panel

## Config files (created next to the script)

- `Tool_Config.json` — scanner host, SSH options, link port, directories
- `IP_Baselines.json` — per-adapter restore points
- `Nessus_Deployment_History.csv` — apply/restore history trail

## Recommended workflow

1. Preflight → fix any FAIL/WARN items  
2. Assign IP (baseline locks automatically)  
3. AV Update  
4. Install + Link (or One-Click suite)  
5. Check Agent Status  
6. When done: Restore IP → Cleanup as needed  
