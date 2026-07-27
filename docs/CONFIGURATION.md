# Nessus Tool — Configuration Reference

All runtime files live next to `Nessus_Tool.ps1` unless you Browse to another folder in the UI.

---

## Contents

1. [Tool_Config.json](#tool_configjson)
2. [IP_Baselines.json](#ip_baselinesjson)
3. [Nessus_Deployment_History.csv](#nessus_deployment_historycsv)
4. [Environment variables](#environment-variables)
5. [Built-in defaults](#built-in-defaults)
6. [Security notes](#security-notes)

---

## Tool_Config.json

Created automatically on first launch (or when you click **Save Settings**).

### Example

See also [`../Tool_Config.example.json`](../Tool_Config.example.json):

```json
{
  "RHELTargetHost": "192.168.50.7",
  "AgentLinkPort": 8834,
  "AVDir": "C:\\Tools\\Nessus_Tool",
  "AgentDir": "C:\\Tools\\Nessus_Tool",
  "NessusCliPath": "C:\\Program Files\\Tenable\\Nessus Agent\\nessuscli.exe",
  "LinkingKey": "",
  "LastGroups": "Windows,Field"
}
```

### Fields

| Field | Type | Description |
|-------|------|-------------|
| `RHELTargetHost` | string | Scanner / Nessus Manager host used for agent link + Preflight ping/TCP |
| `AgentLinkPort` | number | TCP port for agent link (typically `8834`) |
| `AVDir` | string | Directory containing `mpam-fe.exe` |
| `AgentDir` | string | Directory containing `NessusAgent*.msi` and companion audit scripts |
| `NessusCliPath` | string | Full path to `nessuscli.exe` |
| `LinkingKey` | string | Nessus agent linking key (masked in UI; auto-fills Agent tab) |
| `LastGroups` | string | Last Groups field value (optional convenience) |

### How it is loaded

1. On startup, `Import-ToolConfig` reads the file if present.
2. Missing/corrupt file → defaults are written and used.
3. **Settings → Save Settings** overwrites the file.
4. Browsing AV/Agent folders also updates and saves directory fields.

### What is never stored in git / shared source

- Live Nessus **linking keys** should live only in local `Tool_Config.json` on the USB (gitignored), not in committed scripts
- Optional fallback: environment variable `NESSUS_LINK_KEY`

Treat `Tool_Config.json` as sensitive once a linking key is saved.

---

## IP_Baselines.json

Disk-backed restore points for network adapters.

### When written

- First time an adapter is selected on **Assign IP** (if no record exists yet)
- When you click **Recapture Baseline** (overwrites that adapter’s record after confirm)
- Import / merge on **Restore IP**

### Record shape

```json
[
  {
    "ComputerName": "WORKSTATION01",
    "InterfaceAlias": "Ethernet",
    "OriginalIP": "10.10.1.50",
    "OriginalMask": "255.255.255.0",
    "OriginalGateway": "10.10.1.1",
    "OriginalDNS": "10.10.1.10",
    "OriginalDHCP": false,
    "CapturedAt": "2026-07-21 14:32:05"
  }
]
```

### Safety rules

| Rule | Behavior |
|------|----------|
| Key | `ComputerName` + `InterfaceAlias` |
| Silent overwrite | **Never** on normal selection |
| Intentional overwrite | Recapture Baseline only |
| Apply without record | Blocked |
| After restore | Optional prompt to delete the record |

### Export / import

- **Export** copies the current JSON as-is.
- **Import / Merge** replaces same-key records and keeps others.

---

## Nessus_Deployment_History.csv

Append-only audit trail written after successful IP apply or restore actions.

| Column | Description |
|--------|-------------|
| `Timestamp` | Local time `yyyy-MM-dd HH:mm:ss` |
| `ComputerName` | Host name |
| `SelectedAdapter` | Interface alias |
| `OriginalIP` | Baseline IP, or `RESTORE ACTION` for restores |
| `OriginalMask` | Baseline mask, or `RESTORE ACTION` |
| `AssignedTempIP` | New IP / DHCP label / restored target IP |

Useful for engagement notes and change control.

---

## Environment variables

| Variable | Purpose |
|----------|---------|
| `NESSUS_LINK_KEY` | If set, pre-fills the masked Linking Key field at startup |

Example (current user):

```powershell
[Environment]::SetEnvironmentVariable(
  "NESSUS_LINK_KEY",
  "<your-linking-key>",
  "User"
)
```

Restart the tool after setting it. Prefer a protected user/machine scope over embedding keys in scripts.

---

## Built-in defaults

Used when no config file exists yet:

| Setting | Default |
|---------|---------|
| Scanner host | `192.168.50.7` |
| Link port | `8834` |
| AV / Agent dirs | Folder containing `Nessus_Tool.ps1` |
| nessuscli | `C:\Program Files\Tenable\Nessus Agent\nessuscli.exe` |
| APIPA profile | `169.254.0.10` / `255.255.255.0` / GW `169.254.0.1` |

Override defaults via **Settings** or by editing `Tool_Config.json`.

---

## Security notes

1. Treat `Tool_Config.json` as environment-specific — do not commit production hosts if the repo is shared widely.
2. Never put linking keys in JSON, CSV, README, or screenshots of the log (the UI already redacts `--key=` in log lines for link commands).
3. `IP_Baselines.json` may contain internal addressing — handle like other network documentation.
4. Runtime artifacts are listed in `.gitignore`:

```
Tool_Config.json
IP_Baselines.json
Nessus_Deployment_History.csv
*.log
Software Collection/
```

5. Manager/scanner administration is done in the Nessus Manager UI — the tool only talks to it via normal agent link / ICMP / TCP checks.
