# Nessus Agent Deployment & Scan Guide

Official operator procedure for deploying the Nessus Agent with **Nessus Tool v2.1**, running the vulnerability scan, collecting audits, and restoring the host.

**Audience:** Field operators / CAECAM compliance staff  
**Related docs:** [USER_GUIDE.md](USER_GUIDE.md) · [CONFIGURATION.md](CONFIGURATION.md) · [TROUBLESHOOTING.md](TROUBLESHOOTING.md)

---

## Contents

| Section | Topic |
|---------|-------|
| [01](#01--prepare-deployment-files--pre-requisites) | Prepare Deployment Files & Pre-Requisites |
| [01b](#01b--nessus-manager-configuration--plugin-update) | Nessus Manager Configuration & Plugin Update |
| [02](#02--set-up-physical--network-connection-assign-ip-tab) | Set Up Physical & Network Connection (Assign IP) |
| [03](#03--update-antivirus-signatures-av-update-tab) | Update Antivirus Signatures (AV Update) |
| [04](#04--install--link-nessus-agent-agent-install--link-tab) | Install & Link Nessus Agent |
| [05](#05--run-vulnerability-scan) | Run Vulnerability Scan |
| [06](#06--post-scan-diagnostics--software-removal-deep-cleanup-tab) | Post-Scan Diagnostics & Software Removal |
| [07](#07--system-audit-system-audit-tab) | System Audit |
| [08](#08--restore-original-network-configuration-restore-ip-tab) | Restore Original Network Configuration |
| [Appendix A](#appendix-a--v21-optional-enhancements) | v2.1 Optional Enhancements |
| [Appendix B](#appendix-b--data-delivery-checklist) | Data Delivery Checklist |

---

## 01 — Prepare Deployment Files & Pre-Requisites

Ensure all components are staged on a dedicated USB drive or mobile device:

| File | Purpose |
|------|---------|
| `Nessus_Tool.ps1` | Main operator console |
| `Launch_Nessus_Tool.bat` | Elevated launcher (recommended) |
| `mpam-fe.exe` | Latest Windows Defender signature update package |
| `NessusAgent*.msi` | Nessus Agent installer (any matching name; tool uses newest) |
| `Software Collection.ps1` | Installed-software audit script *(tool filename)* |
| `System Collection.ps1` | System-information audit script *(tool filename)* |

> **Filename note:** The tool looks for `Software Collection.ps1` and `System Collection.ps1` (with spaces). If your USB package uses `SoftwareCollection.ps1` / `SystemCollection.ps1`, rename them to match before running audits.

### Recommended first action on the target

1. Right-click **`Launch_Nessus_Tool.bat`** → **Run as administrator** (or run `Nessus_Tool.ps1` elevated).
2. Confirm the status strip shows **ADMIN**.
3. Open **Settings** and set Scanner / RHEL Host + link port if not already correct → **Save Settings**.
4. Open **Preflight** → **Run All Preflight Checks** (optional but recommended in v2.1).

---

## 01b — Nessus Manager Configuration & Plugin Update

Complete these steps on the **Nessus Manager** before field work (or verify they are already done).

### Verify plugin feed

1. On the Nessus Manager, open **Settings → About → Plugin Set**.
2. Confirm:
   - Latest plugin version
   - Recent update timestamp
   - Correct feed type (offline `tar.gz` feed fully updated)

### Plugin download

Download the latest offline plugin archive from the Tenable Plugins Portal:

- https://plugins.nessus.org/v2/offline.php

### Scan profile configuration (DISA STIG plugin families)

Ensure the scan policy includes these required **DISA STIG Plugin Families**:

- DISA Google Chrome Current Windows STIG v2r11
- DISA Microsoft Defender Antivirus STIG v2r8
- DISA Microsoft Dotnet Framework 4.0 STIG v2r7
- DISA Microsoft Edge STIG v2r5
- DISA Microsoft Office System 2016 STIG v2r5
- DISA Microsoft Windows 10 STIG v3r6
- DISA Microsoft Windows 11 STIG v2r7
- DISA Microsoft Windows Defender Firewall with Advanced Security STIG v2r2
- DISA STIG Adobe Acrobat Pro DC Continuous Track v2r1
- DISA STIG Adobe Acrobat Reader DC Continuous Track v2r1
- DISA STIG IE 11 v2r6
- DISA STIG Microsoft Excel 2016 v2r2
- DISA STIG Microsoft Office 365 ProPlus v3r4
- DISA STIG Microsoft Office Access 2016 v2r1
- DISA STIG Microsoft OneNote 2016 v2r1
- DISA STIG Microsoft Outlook 2016 v2r4
- DISA STIG Oracle JRE 8 Windows v2r1

> STIG revision numbers change over time. If the Manager shows a newer revision for a family, use the Manager’s current revision and note the delta in the engagement record.

---

## 02 — Set Up Physical & Network Connection (Assign IP Tab)

**2.1** Connect an Ethernet cable between the Nessus Manager and the Target Computer.

**2.2** Right-click and run `Nessus_Tool.ps1` (or `Launch_Nessus_Tool.bat`) **as Administrator** on the Target Computer.

**2.3** Open the **Assign IP** tab.

**2.4** Under **1. Select Interface**, highlight the adapter connected to the Ethernet cable.

- Confirm **Baseline Status** shows **LOCKED — saved to disk…**  
  (This is the restore point used later in Section 08.)

**2.5** Under **2. Assignment Profile**, select **Set Custom Manual Static IP**.

**2.6** Under **3. Custom Static Configuration Settings**, enter:

- Target IP Address  
- Subnet Mask  
- Default Gateway  
- Primary DNS Server  

**2.6b** Click **Check if Target IP is Free**. Confirm the status shows **LIKELY FREE** (not **IN USE**).  
This pings the address and checks ARP so you do not collide with another host.

**2.7** Click **Apply Network Profile Layout Changes** and confirm the prompt.  
(If availability check is enabled and the IP looks taken, you will get a conflict warning.)

**2.8** Confirm success in the rolling activity log on the right. If **Verify live IP after apply** is checked, confirm the live IP matches the intended address.

> **Do not** click **Recapture Baseline** after applying the staging IP unless you intentionally want the *current* (temporary) settings to become the new restore point.

---

## 03 — Update Antivirus Signatures (AV Update Tab)

**3.1** Open the **AV Update** tab.

**3.2** Review **Current System AV Status** (Active Antivirus, Product Version, Last Update Date, Signature Age).

**3.3** If the engine detects **McAfee**, pause this step and perform McAfee removal in [Section 06](#06--post-scan-diagnostics--software-removal-deep-cleanup-tab) before continuing.

**3.4** Confirm/browse to the folder containing `mpam-fe.exe`, then click **Run AV Update**.

**3.5** Verify **Last Update Date** / Signature Age updates to confirm a successful installation.

---

## 04 — Install & Link Nessus Agent (Agent Install + Link Tab)

**4.1** Open the **Agent Install + Link** tab.

**4.2** If the installer path is unclear, click **Auto-Detect Installer Files** to locate `NessusAgent*.msi` (and confirm `mpam-fe.exe`). The MSI label should turn green with the detected filename.

**4.3** In **Scanner IP**, enter the Host Manager’s static IP address. Set **Port** if not using the default `8834`.

**4.4** In **Linking Key**, enter the key from the Nessus Manager console  
*(or rely on env var `NESSUS_LINK_KEY` if preconfigured — the key is never saved in `Tool_Config.json`)*.

**4.5** Click **Install Nessus Agent** to run the MSI silently.

**4.6 Time Sync Check:** Ensure the target machine’s system time matches the Host Manager.  
If the clock is skewed by more than **5–10 minutes**, agents may fail to check in. Use **Change Target Computer Time** with `YYYY-MM-DD HH:MM` to synchronize *(Administrator required)*.

**4.7** Click **Link Agent** to establish communications with the manager.  
Optional: fill **Groups** (comma-separated) before linking.

**4.8 Verify Agent Status:** Click **Check Agent Status**. In the log, confirm the agent is linked / online (or equivalent healthy link state) and paired to the manager.

**4.9 Troubleshooting stops:**

| Symptom | Action |
|---------|--------|
| Tenable services stopped / frozen | **Check Agent Service Health (Remote)** on the Manager host |
| Agent stubbornly offline | **Auto-Fix Agent Problems (Remote)** to restart remote `nessusd` |
| Still failing | Run **Preflight** TCP port test; confirm key, IP, port, and time sync |

> **v2.1 shortcut:** After Preflight + Assign IP + key entry, you may use **One-Click: AV Update + Install + Link**, then still run **Check Agent Status** (step 4.8).

---

## 05 — Run Vulnerability Scan

**5.1** Access the Nessus Manager console.

**5.2** Configure the target scan using the pre-loaded **DISA STIG** profile (families listed in [Section 01b](#01b--nessus-manager-configuration--plugin-update)).

**5.3** Launch the scan against the target machine’s designated (staging) IP address.

**5.4** Monitor progress to completion, then download the report.

---

## 06 — Post-Scan Diagnostics & Software Removal (Deep Cleanup Tab)

> Prefer completing [Section 08 — Restore IP](#08--restore-original-network-configuration-restore-ip-tab) **before** or **after** cleanup depending on whether you still need the staging IP for file copy / confirmation. Typical order: finish audits (07) → restore IP (08) → cleanup agent (06), unless local procedure says otherwise.

**6.1** Click **Unlink Agent** to remove the target from the Nessus Manager.

**6.2** Click **Stop Tenable Services** to stop active background daemons.

**6.3** Click **Delete Tenable Directories** to remove lingering files under Program Files and ProgramData.

**6.4** Click **Remove Tenable Registry Keys** to remove Tenable registry hives.

**6.5 Legacy McAfee removals:** If the target has legacy McAfee packages:

1. Click **Uninstall MCAFEE (Files and Registry)**.
2. The tool purges processes, services, uninstallers, program folders, and registry keys.
3. Confirm status in the log terminal.

> **v2.1:** You may use **Uninstall Nessus Agent (MSI)** and/or **Full Cleanup Wizard** (double-confirmed) instead of running steps 6.1–6.4 separately.

---

## 07 — System Audit (System Audit Tab)

**7.1** Open the **System Audit** tab.

**7.2** Confirm **Target Computer Name** (defaults to the local host).

**7.3** Click **Collect Installed Software** to run `Software Collection.ps1`.

**7.4** Click **Capture System Information** to run `System Collection.ps1`.  
*(Or use **Run Both Audits**.)*

**7.5** Locate generated output under the tool’s source directory (Software Collection folder / script-defined paths). Use **Open Software Collection Folder** when available.

---

## 08 — Restore Original Network Configuration (Restore IP Tab)

**8.1** Open the **Restore IP** tab.

**8.2** Click **Refresh List** if needed. Select the saved restore point for the adapter you changed in Section 02.

**8.3** Review the detail panel (Original IP, Mask, Gateway, DNS, Captured At).

**8.4** Click **Revert Selected Adapter Back to This Baseline** and confirm.

**8.5** Inspect `Nessus_Deployment_History.csv` in the tool directory to verify the history records the transition from the temporary IP back to the baseline.

**8.6 Data Delivery:** Hand off the generated System and Software capture files, the scan report (if required), and the exported CSV history to **CAECAM staff** to finalize compliance documentation.

Optional: **Export Baselines…** before deleting restore points if you need an archive copy.

---

## Appendix A — v2.1 Optional Enhancements

These are available in the current tool and can be used without changing the core SOP:

| Enhancement | Where | When to use |
|-------------|-------|-------------|
| Preflight checks | Preflight tab | Before Section 02 / 04 |
| Settings persistence | Settings tab | Once per USB / engagement |
| One-click deploy | Agent tab | Instead of separate AV + Install + Link |
| Live IP verify | Assign IP | After Section 02 apply |
| Baseline export | Restore IP | Before wiping USB / host |
| Save Log | Right panel | Attach to engagement package |
| Full Cleanup Wizard | Deep Cleanup | Instead of manual 6.1–6.4 sequence |

---

## Appendix B — Data Delivery Checklist

Hand off to CAECAM:

- [ ] Vulnerability scan report (from Manager)
- [ ] Software collection output
- [ ] System collection output
- [ ] `Nessus_Deployment_History.csv`
- [ ] (Optional) Saved tool log (`.log`)
- [ ] (Optional) Exported `IP_Baselines.json` / baseline export
- [ ] Confirm target IP restored to original baseline
- [ ] Confirm agent unlinked / removed per local policy

---

## Quick reference — tab map

| SOP section | Tool tab |
|-------------|----------|
| 01 Prepare | *(USB staging)* + Preflight / Settings |
| 02 Network | Assign IP |
| 03 AV | AV Update |
| 04 Agent | Agent Install + Link |
| 05 Scan | Nessus Manager console |
| 06 Cleanup | Deep Cleanup |
| 07 Audit | System Audit |
| 08 Restore | Restore IP |
