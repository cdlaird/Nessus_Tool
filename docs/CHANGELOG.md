# Nessus Tool — Changelog

## 2.2.0

### Added

- **IP availability check** on Assign IP (custom static / APIPA)
  - Button: **Check if Target IP is Free** (ICMP ping + ARP neighbor lookup)
  - Checkbox: **Check IP is free before apply** (warns on conflict; operator can override)
  - Detects addresses already bound on the local PC vs another host on the LAN
  - Status line: LIKELY FREE / IN USE / OK on this adapter

---

## 2.1.0

Initial documented release of the improved WinForms operator console (based on the prior internal script).

### Added

- **Preflight tab** — elevation, package detection, agent service, ICMP, TCP link-port probe, SSH + remote `nessusd`, free space
- **Settings tab** — persistent `Tool_Config.json` for scanner host, SSH, port, directories, `nessuscli` path
- **One-click deploy** — AV update → newest MSI install → link
- **MSI auto-detect** — `NessusAgent*.msi` by newest write time (no hardcoded version string)
- **Configurable agent link port**
- **Log toolbar** — Clear, Copy, Save, Open Folder; timestamped log lines
- **Baseline export / import (merge)** on Restore IP
- **Refresh Interfaces** on Assign IP
- **Live IP verification** after apply/restore
- **AV signature age** display with stale coloring
- **Admin elevation detection** + warnings before privileged actions
- **Confirmations** on destructive cleanup, McAfee purge, clock change, one-click deploy
- **Full Cleanup Wizard** with double confirmation
- **Uninstall Nessus Agent (MSI)** via registry product GUID
- **Run Both Audits** + open Software Collection folder
- **`Launch_Nessus_Tool.bat`** elevated launcher
- **`NESSUS_LINK_KEY`** optional env auto-fill for masked linking key
- Status strip (version, elevation, host, scanner, SSH target)
- Example config, README, and `docs/` operator documentation
- Official **Deployment & Scan Guide** (`docs/DEPLOYMENT_GUIDE.md`) aligned to the Word SOP (DISA STIG families, sections 01–08, CAECAM handoff)

### Safety retained / strengthened

- Disk-backed IP baselines (`IP_Baselines.json`) that are never silently overwritten
- Apply IP blocked until a locked baseline exists
- Linking key never stored in `Tool_Config.json`
- Link log lines redact the key value

### Changed (vs prior internal script)

- Hardcoded MSI filename removed in favor of glob + newest match
- Hardcoded linking-key prefill removed (masked empty / env only)
- Destructive cleanup actions now confirm before running
- UI no longer freezes on long `Start-Process -Wait` calls (responsive wait helpers)

---

## Unreleased

_Nothing yet._
