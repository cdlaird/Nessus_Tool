# Nessus Tool — User Guide

Operator UI reference for **Nessus Tool v2.1**.

For the official field procedure (USB prep → scan → cleanup → CAECAM handoff), use:

**[DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md) — Nessus Agent Deployment & Scan Guide**

For setup and overview, see the [main README](../README.md).

---

## Contents

1. [Launching the tool](#1-launching-the-tool)
2. [UI layout](#2-ui-layout)
3. [Preflight](#3-preflight)
4. [Assign IP](#4-assign-ip)
5. [AV Update](#5-av-update)
6. [Agent Install + Link](#6-agent-install--link)
7. [Deep Cleanup](#7-deep-cleanup)
8. [System Audit](#8-system-audit)
9. [Restore IP](#9-restore-ip)
10. [Settings](#10-settings)
11. [End-to-end workflows](#11-end-to-end-workflows)

---

## 1. Launching the tool

### Preferred

Right-click `Launch_Nessus_Tool.bat` → **Run as administrator**.

If the session is not already elevated, the launcher requests UAC elevation and restarts the script.

### Manual

```powershell
# Run from an elevated PowerShell window
cd C:\Path\To\Nessus_Tool
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Nessus_Tool.ps1
```

### Confirm elevation

At the bottom of the window, the status strip should show **ADMIN** in green.  
If it shows **NOT ELEVATED**, most network/install/cleanup actions will warn or fail.

---

## 2. UI layout

```
┌─────────────────────────────┬──────────────────────┐
│  Tabs (Preflight … Settings)│  Live Log            │
│                             │  Clear / Copy / Save │
│                             │  Open Folder         │
│                             ├──────────────────────┤
│                             │  Progress bar        │
├─────────────────────────────┴──────────────────────┤
│  Status strip: version | ADMIN | host | scanner    │
└────────────────────────────────────────────────────┘
```

- **Log** is timestamped and read-only in the UI.
- **Save Log…** writes a `.log` / `.txt` file for evidence packs.
- **Open Folder** opens the tool’s working directory in Explorer.

---

## 3. Preflight

Use this **before** changing IPs or installing.

### Buttons

| Button | Action |
|--------|--------|
| **Run All Preflight Checks** | Full battery of local + remote checks |
| **Ping Scanner Only** | ICMP to configured scanner host |
| **Test Agent Port** | TCP connect to scanner link port (default 8834) |

### What a full preflight reports

| Result | Meaning |
|--------|---------|
| `[PASS]` | Check succeeded |
| `[WARN]` | Non-fatal; investigate before deploy |
| `[FAIL]` | Likely blocker (especially elevation) |
| `[INFO]` | Context only |

Checks include: elevation, tool path, `mpam-fe.exe`, newest `NessusAgent*.msi`, agent install/service, baseline count, ping, TCP port, SSH login, remote `nessusd` state, free disk space.

---

## 4. Assign IP

Safely change adapter addressing while preserving a restore point on disk.

### Steps

1. Select an interface in the list.
2. Confirm **Baseline Status** shows **LOCKED — saved to disk…**
3. Choose a profile:
   - **DHCP**
   - **APIPA** (`169.254.0.10` / `255.255.255.0`)
   - **Custom static** (IP, mask, gateway, DNS)
4. (Recommended) Leave **Verify live IP after apply** and **Check IP is free before apply** checked.
5. For custom static: click **Check if Target IP is Free** (ping + ARP). Status shows **LIKELY FREE** or **IN USE**.
6. Click **Apply Network Profile Layout Changes** and confirm.  
   If the address looks taken, the tool warns and asks before continuing.

### Important baseline rules

| Behavior | Detail |
|----------|--------|
| First select | Captures live settings → writes `IP_Baselines.json` immediately |
| Re-select same adapter | Reloads the **existing** baseline — does **not** overwrite |
| Recapture Baseline | Only deliberate overwrite path (confirmation required) |
| Apply without baseline | **Blocked** |

### Other controls

- **Refresh Interfaces** — re-query adapters after cable/NIC changes.
- Gateway **Leave** event pre-fills DNS only if DNS is still empty (won’t clobber a manual DNS).

---

## 5. AV Update

### Steps

1. Confirm/browse the folder containing `mpam-fe.exe`.
2. Optionally click **Refresh AV Status**.
3. Click **Run AV Update**.

### Status panel

| Field | Source |
|-------|--------|
| Active AntiVirus | Defender or SecurityCenter2 product name |
| Product Version | Defender `AMProductVersion` when available |
| Last Update Date | Signature last-updated timestamp |
| Signature Age | Days/hours; color shifts if stale (>2d orange, >7d red) |

If Defender is unavailable, the tool falls back to third-party WMI AV metadata when present.

---

## 6. Agent Install + Link

### Fields

| Field | Notes |
|-------|-------|
| Agent directory | Folder searched for `NessusAgent*.msi` |
| Scanner IP | Manager / scanner host |
| Port | Link port (default **8834**) |
| Linking Key | Masked; required for link / one-click |
| Groups | Optional comma-separated Nessus groups |

### Buttons

| Button | Action |
|--------|--------|
| **Auto-Detect Installer Files** | Log whether MSI and `mpam-fe.exe` exist; update MSI label |
| **Install Nessus Agent** | Silent MSI install of newest matching package |
| **Link Agent** | `nessuscli agent link` + ensure service running |
| **Check Agent Status** | Parse `nessuscli agent status` into the log |
| **One-Click: AV Update + Install + Link** | Confirmed 3-step suite |
| **Change Target Computer Time** | Sets **local** OS clock (confirmed) |
| **Auto-Fix Agent Problems (Remote)** | SSH `systemctl restart nessusd` |
| **Check Agent Service Health (Remote)** | SSH `systemctl is-active nessusd` (+ start if inactive) |

### Linking key options

1. Type into the masked field each run, **or**
2. Set user/machine env var:

```powershell
[Environment]::SetEnvironmentVariable("NESSUS_LINK_KEY", "your-key-here", "User")
```

The key is **never** written to `Tool_Config.json`.

### One-click deploy order

1. Run `mpam-fe.exe -q` (skipped with warning if missing)
2. Install newest `NessusAgent*.msi`
3. Link using key / host / port / groups
4. Start agent service if needed

Always finish with **Check Agent Status**.

---

## 7. Deep Cleanup

All destructive actions ask for confirmation. Prefer **Restore IP** before wiping the agent if you still need network rollback.

| Button | Effect |
|--------|--------|
| **Unlink Agent** | `nessuscli agent unlink` |
| **Stop Tenable Services** | Force-stop `*nessus*` / `*tenable*` services |
| **Uninstall Nessus Agent (MSI)** | `msiexec /x` via uninstall registry GUID |
| **Delete Tenable Directories** | Removes Program Files / ProgramData Tenable trees |
| **Remove Tenable Registry Keys** | Removes HKLM Tenable keys |
| **Full Cleanup Wizard** | Unlink → Stop → Uninstall → Dirs → Reg (double confirm) |
| **Uninstall MCAFEE…** | Aggressive McAfee process/service/uninstaller/dir/reg purge |

> Full cleanup permanently removes the agent from the host. Use only when authorized and finished with the engagement.

---

## 8. System Audit

Requires companion scripts in the Agent directory:

- `Software Collection.ps1` (expects `CollectComputer`)
- `System Collection.ps1`

| Button | Action |
|--------|--------|
| **Collect Installed Software** | Runs Software Collection for the target name |
| **Capture System Information** | Runs System Collection |
| **Run Both Audits** | Sequential both |
| **Open Software Collection Folder** | Opens `Software Collection\` under the tool dir |

Target defaults to the local computer name. UI controls disable while a collection runs so you don’t double-click.

---

## 9. Restore IP

Lists **every** saved baseline from `IP_Baselines.json` (not just the last selected adapter).

### Steps

1. **Refresh List** if you just captured a baseline on another tab.
2. Select a row → review detail panel (IP, mask, GW, DNS, captured time, DHCP/STATIC).
3. **Revert Selected Adapter Back to This Baseline** → confirm.
4. Optionally clear that restore point after success.

### Extra tools

| Button | Action |
|--------|--------|
| **Export Baselines…** | Copy `IP_Baselines.json` to a chosen path |
| **Import / Merge Baselines…** | Merge records from another JSON (same adapter keys replace) |
| **Delete Selected Restore Point** | Remove baseline without changing the live adapter |

---

## 10. Settings

Persists operator defaults to `Tool_Config.json`.

| Setting | Used by |
|---------|---------|
| Scanner / RHEL Host | Link, Preflight, remote SSH helpers |
| SSH User / Options | Remote health / auto-fix |
| Agent Link Port | Link + Preflight TCP test |
| nessuscli Path | Install/link/status/cleanup paths |

**Save Settings** updates the status strip and Agent tab host/port fields.  
**Open Config File** opens the JSON in Notepad.

AV / Agent directories are also remembered when you Browse on those tabs.

---

## 11. End-to-end workflows

### A. Standard agent deploy

1. Launch elevated → **Settings** → save scanner/port  
2. **Preflight** → fix FAIL/WARN  
3. **Assign IP** → lock baseline → apply staging profile  
4. **AV Update**  
5. **Install** → **Link** → **Check Agent Status**  
6. (Optional) **System Audit**  

### B. Fast path

1. Preflight  
2. Assign IP  
3. Enter linking key  
4. **One-Click: AV Update + Install + Link**  
5. Check Agent Status  

### C. Engagement complete

1. **Restore IP** for each changed adapter  
2. Confirm live IP looks correct  
3. **Deep Cleanup** (unlink / uninstall / full wizard as policy requires)  
4. Save log from the right panel for records  

---

## Related docs

- [CONFIGURATION.md](CONFIGURATION.md) — files, env vars, defaults  
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — common failures  
- [CHANGELOG.md](CHANGELOG.md) — version history  
