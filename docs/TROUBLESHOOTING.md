# Nessus Tool — Troubleshooting

Common failures and how to resolve them. For normal usage, see [USER_GUIDE.md](USER_GUIDE.md).

---

## Elevation / permissions

### Status strip shows NOT ELEVATED

**Cause:** Script started without Administrator rights.

**Fix:**
1. Close the tool.
2. Right-click `Launch_Nessus_Tool.bat` → **Run as administrator**.
3. Confirm the strip shows **ADMIN**.

### Access denied on netsh / msiexec / services

Same root cause as above, or UAC filtered token. Always use a full elevated session.

---

## Assign IP / Restore IP

### “No safe restore point has been saved”

**Cause:** Adapter never successfully captured a baseline (or baseline file write failed).

**Fix:**
1. Re-select the adapter in the list.
2. Confirm **Baseline Status** is green **LOCKED**.
3. If still red, check write permission on the tool folder and that `IP_Baselines.json` is not locked by another process.
4. Retry Apply.

### Baseline shows wrong “original” IP

**Cause:** Someone used **Recapture Baseline** after the adapter was already changed, or the first capture happened after a prior change.

**Fix:**
- Manually set the adapter back to the known-good config, then **Recapture Baseline**.
- Or import a known-good export from another machine/engagement if you have one.

### “IP appears in use” / availability check says IN USE

**Cause:** Another host answered ping, ARP showed a neighbor MAC, or this PC already has that address on another adapter.

**Fix:**
- Pick a different staging IP.
- Confirm you are on the correct Ethernet segment (cable to Manager/switch).
- If you are sure the address is yours (false positive / stale ARP), you can override the warning at apply time.
- Note: **LIKELY FREE** is not a guarantee — hosts that block ICMP and are quiet on ARP can still exist.

### Apply succeeds but Verify shows unexpected IP

**Cause:** DHCP delay, multiple addresses, or VPN/filter drivers.

**Fix:**
- Wait a few seconds → Refresh Interfaces / re-query.
- Check `Get-NetIPConfiguration` in an elevated PowerShell window.
- Confirm you selected the correct physical adapter (not a virtual leftover that slipped the filter).

### Restore did not bring back gateway/DNS

**Cause:** Baseline captured empty gateway/DNS (common on some DHCP/APIPA states).

**Fix:** Set gateway/DNS manually, or Recapture a complete baseline before future changes.

### Baselines list is empty after restart

**Cause:** Tool folder moved, or `IP_Baselines.json` deleted/corrupt.

**Fix:**
- Confirm you are launching from the same directory.
- Restore from an Export backup if available.
- Corrupt file: tool treats it as empty and logs a warning — replace from backup.

---

## AV Update

### `mpam-fe.exe not found`

**Fix:** Browse to the folder that contains the offline update package, or copy `mpam-fe.exe` next to the script.

### Status still shows old signature age

**Cause:** Update package outdated, Defender busy, or third-party AV owning signatures.

**Fix:**
- Refresh AV Status after a short wait.
- Confirm package date/size in Preflight.
- If third-party AV is active, Defender fields may not update meaningfully.

---

## Agent install / link

### No NessusAgent MSI found

**Fix:**
- Place a file matching `NessusAgent*.msi` in the Agent directory.
- Click **Auto-Detect Installer Files** and confirm the green MSI label.
- The tool picks the **newest LastWriteTime** match if multiple exist.

### msiexec non-zero exit

**Common causes:**
- Agent already installed
- Pending reboot
- MSI blocked / corrupt
- Insufficient rights

**Fix:** Check Agent Status / Programs and Features; reboot if prompted; re-download MSI; run elevated.

### `nessuscli.exe not found`

**Cause:** Install did not complete, custom install path, or wrong `NessusCliPath` in Settings.

**Fix:**
1. Verify install under `C:\Program Files\Tenable\Nessus Agent\`.
2. Update **Settings → nessuscli Path** if customized.
3. Re-run Install.

### Link aborted: no linking key

Enter the key in the masked field, or set `NESSUS_LINK_KEY` and restart the tool.

### Link command runs but agent not linked

**Check:**
1. **Check Agent Status** output (Link State / Last Conn).
2. Preflight **Test Agent Port** to scanner:port.
3. Scanner IP/port in Settings match the manager.
4. Linking key is valid and not expired / group-restricted.
5. Host firewall / ACL between agent and scanner.
6. System time roughly correct (use clock tool only if policy allows).

### Groups not applied

Ensure Groups is comma-separated without stray quotes, then unlink/re-link if the manager already accepted a prior link.

---

## Preflight / connectivity

### Ping WARN but TCP PASS

Often normal (ICMP filtered). Prefer the TCP port result for link readiness.

### Local agent service not running

Use **Check Local Agent Service Health** or **Restart Local Agent Service** on the Agent tab (elevated). Confirm the MSI install completed.

---

## Cleanup

### Directories “still there” after delete

Files locked by running services. Stop Tenable services first (or use Full Cleanup Wizard order), then delete again. Reboot if handles remain.

### Uninstall finds no product

Agent may already be removed, or was installed under a different display name. Check registry Uninstall keys manually or reinstall then uninstall via the tool.

### McAfee purge incomplete

Locked drivers/files often need a reboot. Re-run after reboot if remnants remain. Only use when authorized.

---

## Audit collection

### `Software Collection.ps1` / `System Collection.ps1` not found

These are companion scripts, not bundled in every package. Place them in the Agent directory (same folder as the tool or the browsed path).

### Collection finishes but folder empty

Check the companion script’s own output path/permissions; the tool only launches them and reports the expected `Software Collection\` folder.

---

## Config / log issues

### Settings not sticking

Click **Save Settings** (browsing alone only updates dirs). Confirm `Tool_Config.json` is writable.

### Cannot save log

Choose a writable path; avoid protected system folders without elevation.

### Tool_Config.json corrupt

Delete or rename it; the tool regenerates defaults on next start. Re-enter Settings values.

---

## Still stuck?

1. Save the log (**Save Log…**).
2. Note Preflight output.
3. Capture `Tool_Config.json` (redact anything sensitive) and whether `IP_Baselines.json` exists.
4. Record Windows build, elevation state, and MSI filename/version.
