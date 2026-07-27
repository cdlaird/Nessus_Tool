# Nessus_Tool
Z3hXelpwOEJWeXR0U1YwdGZmeEg6RWhhNVdPdy1aT0t6R0tKWlVwbzNxQQ==

$ProgressPreference = 'SilentlyContinue'; Invoke-WebRequest -Uri https://192.168.50 -OutFile elastic-agent.zip; Expand-Archive elastic-agent.zip -DestinationPath . ; cd elastic-agent; .\elastic-agent.exe install --url https://192.168.50.8:8220 --enrollment-token Z3hXelpwOEJWeXR0U1YwdGZmeEg6RWhhNVdPdy1aT0t6R0tKWlVwbzNxQQ== --insecure

.\elastic-agent.exe uninstall

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Automatically bypass self-signed certificate blocks for the download
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}

# Create Main Form Window
$form = New-Object System.Windows.Forms.Form
$form.Text = "Elastic Agent Deployer"
$form.Size = New-Object System.Drawing.Size(420, 280)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false

# Server IP Label & Input
$lblIP = New-Object System.Windows.Forms.Label
$lblIP.Text = "Security Onion Server IP:"
$lblIP.Location = New-Object System.Drawing.Point(20, 20)
$lblIP.Size = New-Object System.Drawing.Size(150, 20)
$form.Controls.Add($lblIP)

$txtIP = New-Object System.Windows.Forms.TextBox
$txtIP.Text = "192.168.50.8"
$txtIP.Location = New-Object System.Drawing.Point(180, 18)
$txtIP.Size = New-Object System.Drawing.Size(200, 20)
$form.Controls.Add($txtIP)

# Enrollment Token Label & Input
$lblToken = New-Object System.Windows.Forms.Label
$lblToken.Text = "Enrollment Token:"
$lblToken.Location = New-Object System.Drawing.Point(20, 60)
$lblToken.Size = New-Object System.Drawing.Size(150, 20)
$form.Controls.Add($lblToken)

$txtToken = New-Object System.Windows.Forms.TextBox
$txtToken.Text = "Z3hXelpwOEJWeXR0U1YwdGZmeEg6RWhhNVdPdy1aT0t6R0tKWlVwbzNxQQ=="
$txtToken.Location = New-Object System.Drawing.Point(180, 58)
$txtToken.Size = New-Object System.Drawing.Size(200, 20)
$form.Controls.Add($txtToken)

# Status Label
$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = "Ready to install."
$lblStatus.Location = New-Object System.Drawing.Point(20, 100)
$lblStatus.Size = New-Object System.Drawing.Size(360, 20)
$lblStatus.ForeColor = [System.Drawing.Color]::Blue
$form.Controls.Add($lblStatus)

# Progress Bar
$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(20, 130)
$progressBar.Size = New-Object System.Drawing.Size(360, 23)
$progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
$form.Controls.Add($progressBar)

# Action Button
$btnInstall = New-Object System.Windows.Forms.Button
$btnInstall.Text = "Install Agent"
$btnInstall.Location = New-Object System.Drawing.Point(140, 180)
$btnInstall.Size = New-Object System.Drawing.Size(120, 35)
$form.Controls.Add($btnInstall)

# Installation Execution Code
$btnInstall.Add_Click({
    $btnInstall.Enabled = $false
    $lblStatus.ForeColor = [System.Drawing.Color]::OrangeRed
    
    # 1. Download Phase
    $lblStatus.Text = "Connecting and downloading ZIP from Security Onion..."
    $progressBar.Value = 25
    $form.Refresh()
    
    $ZipPath = "$env:TEMP\elastic-agent.zip"
    $ExtractDir = "$env:TEMP\elastic-agent-install"
    
    try {
        Invoke-WebRequest -Uri "https://$($txtIP.Text)/downloads/elastic-agent.zip" -OutFile $ZipPath -ErrorAction Stop
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Download failed! Check server IP or your firewall settings.", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        $lblStatus.Text = "Failed."
        $btnInstall.Enabled = $true
        return
    }

    # 2. Extraction Phase
    $lblStatus.Text = "Extracting installation binaries..."
    $progressBar.Value = 60
    $form.Refresh()
    
    if (Test-Path $ExtractDir) { Remove-Item $ExtractDir -Recurse -Force }
    Expand-Archive -Path $ZipPath -DestinationPath $ExtractDir

    # 3. Execution Phase
    $lblStatus.Text = "Registering background Windows Service..."
    $progressBar.Value = 85
    $form.Refresh()
    
    $ExeFolder = Get-ChildItem -Path $ExtractDir -Directory | Select-Object -First 1
    Set-Location $ExeFolder.FullName
    
    # Run the silent deployment string
    $installArgs = @("install", "--url", "https://$($txtIP.Text):8220", "--enrollment-token", "$($txtToken.Text)", "--insecure", "--non-interactive")
    Start-Process -FilePath ".\elastic-agent.exe" -ArgumentList $installArgs -NoNewWindow -Wait

    # 4. Clean Up Phase
    $progressBar.Value = 100
    $lblStatus.ForeColor = [System.Drawing.Color]::Green
    $lblStatus.Text = "Installation finished successfully!"
    $form.Refresh()
    
    Remove-Item $ZipPath -Force
    [System.Windows.Forms.MessageBox]::Show("Elastic Agent has been deployed successfully as a background system service.", "Success", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    $form.Close()
})

Here is a comprehensive, professional blueprint you can copy and paste directly into your documentation. It is structured specifically for the next intern to cleanly understand the current hardware setup, the root bottleneck, and the exact steps to implement any of the three future expansion paths.
------------------------------
## Cybersecurity Lab Deployment & Handover Guide## 1. Current Architectural Baseline

* Hypervisor / Host Manager: Cockpit (Linux Host Server)
* SIEM Platform: Security Onion (Virtual Machine via KVM/Qemu)
* Management Interface (NIC 1): Built-in Server Interface (192.168.50.8)
* Sniffing Interface (NIC 2): Realtek RTL8153 Gigabit Ethernet Adapter (USB 3.0 Passthrough)
* Active Routing Hardware: ASUS ROG Rapture GT-AC5300 connected to an unmanaged downstream switch.

## The Network Bottleneck Explained (Why We See Only Broadcasts)
The sniffing adapter (bond0 / enp3s0u2) is currently plugged into a standard router LAN port. Because consumer routers and unmanaged switches operate via isolated MAC-address lookup tables, they prune unicast traffic.
The sniffer is treated as a standard endpoint; it only receives frames explicitly addressed to its own MAC address, alongside network broadcast/multicast chatter (e.g., Multicast DNS on 224.0.0.251:5353 or ff02::fb). It is physically blind to the transit payloads of wireless devices, phones, and neighboring workstations.
------------------------------
## 2. Next-Step Options for the Next Intern
To expand visibility to capture unmanaged devices (like smartphones, TVs, and guest hardware) or track deeper system analytics, the next intern can execute any of the following three pre-approved engineering paths.
## Option A: The Managed Switch Integration (SPAN / Port Mirroring)
This is the industry-standard method for replicating enterprise defense network environments. It avoids buying expensive test access points while completely offloading packet duplication from the home router.
## Physical Topology Change:

           +-------------------------+

           | ASUS ROG Gaming Router  |
           +------------+------------+
                        |
                        | Normal Ethernet Drop
                        v
           +------------+------------+

           |     NEW MANAGED SWITCH  |
           |                         |
           | Port 1: Router Feed     |
           | Port 2: SPAN Monitor    | ----> [Realtek USB Sniffing Card]
           | Port 3: Transit Feed    |
           +------------+------------+
                        |
                        | Trunk Link
                        v
           +------------+------------+

           | EXISTING UNMANAGED SW.  |
           +------------+-------+----+

                        |       |
                        v       v
                     [TVs]   [Consoles]


   1. Insert Hardware: Place a 5-port Gigabit Managed Switch (e.g., Netgear ProSafe, TP-Link Omada) directly between the ASUS Router and the existing unmanaged switch.
   2. Rewire Interconnects: Run a cable from the Router to Port 1 of the Managed Switch. Run a cable from Port 3 of the Managed Switch down to the input of the Unmanaged Switch.
   3. Wire the Sniffer: Connect the Security Onion Realtek USB adapter directly into Port 2 of the Managed Switch.

## Software Configuration steps:

   1. Identify the local IP address assigned to the Managed Switch and open it in a web browser.
   2. Navigate to Port Management ➔ Port Mirroring (or SPAN).
   3. Set Port 1 (or Port 1 and Port 3) as the Source / Mirrored Port (Session: Both TX and RX).
   4. Set Port 2 as the Destination / Mirrored-to Port.
   5. Save settings. Verify traffic injection via the Security Onion terminal using: sudo tcpdump -i bond0 -nn -c 20.

------------------------------
## Option B: The Physical Network TAP Deployment
Deploying a physical Network TAP (Test Access Point) provides the most reliable packet capture possible. It operates passively at Layer 1 (Physical Layer), meaning it cannot cause network loops, drop packets due to switch processor saturation, or leak configuration states.
## Physical Topology Change:

+---------------+                   +-----------------------+

|  ASUS Router  |                   | Existing Unmanaged Sw |
+-------+-------+                   +-----------+-----------+

        |                                       |
  [Network A]                             [Network B]

        |                                       |
        v                                       v
   +----+---------------------------------------+----+

   |               PHYSICAL HARDWARE TAP             |
   |                                                 |
   |               [Monitor / Aggregation Port]      |
   +--------------------+----------------------------+
                        |
                        | Inline Split-Stream
                        v
           [Realtek USB Sniffing Adapter]


   1. Sever the Link: Disconnect the single Ethernet link running between the ASUS Router and the unmanaged switch.
   2. Seat the TAP: Plug the cable coming from the Router into port Network A of the TAP. Run a new Ethernet patch cable from port Network B of the TAP into the unmanaged switch.
   3. Connect the Sniffer: Plug the Security Onion Realtek USB network adapter straight into the TAP’s Monitor / Aggregation port.

## Software Configuration Steps:

* Zero Software Needed: TAPs split the electrical/optical signals directly at the hardware layer. No firmware profiles, IP assignments, or switch interfaces are required. Run sudo tcpdump -i bond0 -nn -c 20 on Security Onion to immediately confirm full internet payload ingest.

------------------------------
## Option C: The Elastic Agent Endpoint Framework (EDR Deployment)
If the lab faces physical constraints where hardware modification or purchasing is prohibited, drop network-level sniffing and pivot to an Endpoint Detection and Response (EDR) framework. This watches traffic and system telemetry directly inside the endpoint operating systems before or after encryption occurs.
## Architectural Breakdown:

 [ Personal Test Workstation ]                      [ Security Onion VM ]
+------------------------------+               +----------------------------+

|  Elastic Agent Service       |               | Fleet Server Engine        |
|  - Tracks DNS Queries        |               | - Listens on Port 8220     |
|  - Tracks App Process Links  | ------------> | - Management: 192.168.50.8 |
|  - Ships lightweight logs    |   (HTTPS TLS) | - Master Token Database    |
+------------------------------+               +----------------------------+

## Pre-Configured Token Credentials (Extracted from so-elastic-fleet):

* Master Endpoint Enrollment Token:
Z3hXelpwOEJWeXR0U1YwdGZmeEg6RWhhNVdPdy1aT0t6R0tKWlVwbzNxQQ==
* Assigned Policy: Security Onion Endpoint Policy

## Automated Installation Script (For Windows Test Computers):
Instruct the intern to open PowerShell as an Administrator on the personal target computer, paste this script block, and press Enter:

# 1. Authorize local execution and bypass self-signed certificate constraints
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}
# 2. Assign environment variables
$ServerIP   = "192.168.50.8"
$Token      = "Z3hXelpwOEJWeXR0U1YwdGZmeEg6RWhhNVdPdy1aT0t6R0tKWlVwbzNxQQ=="
$ZipPath    = "$env:TEMP\elastic-agent.zip"
$ExtractDir = "$env:TEMP\elastic-agent-install"
# 3. Pull and expand the binary directory from Security Onion's local mirror
Write-Host "Downloading Elastic Agent from Security Onion..." -ForegroundColor Cyan
Invoke-WebRequest -Uri "https://$ServerIP/downloads/elastic-agent.zip" -OutFile $ZipPath

Write-Host "Extracting files..." -ForegroundColor Cyanif (Test-Path $ExtractDir) { Remove-Item $ExtractDir -Recurse -Force }
Expand-Archive -Path $ZipPath -DestinationPath $ExtractDir
# 4. Access folder path and trigger silent non-interactive installation
$ExeFolder = Get-ChildItem -Path $ExtractDir -Directory | Select-Object -First 1
cd $ExeFolder.FullName

Write-Host "Installing Elastic Agent as an automatic background service..." -ForegroundColor Cyan
.\elastic-agent.exe install --url "https://$ServerIP:8220" --enrollment-token $Token --insecure --non-interactive
# 5. Clean up temporary download artifacts
Write-Host "Cleaning up workspace installation files..." -ForegroundColor Green
Remove-Item $ZipPath -Force
Write-Host "Deployment Complete. Asset is now live in Fleet Management." -ForegroundColor Green

## Verification Steps for the Intern:

   1. Log into the Security Onion Console (SOC) at https://192.168.50.8.
   2. Click Fleet on the left menu. Verify the new asset shows up in the asset index list with a green Healthy / Online status indicator.
   3. Open the Hunt utility dashboard. Search for agent.ip : "TARGET_COMPUTER_IP" or filter by event.category : "network" to view real-time process metadata, application bindings, and DNS resolutions.

------------------------------
## Notes for Handover

* Firewall Restrictions: Security Onion locks its host firewall by default. If a new test machine cannot reach https://192.168.50.8, the intern must execute this command as root on the Security Onion server CLI to open the lane:
sudo so-firewall includehost analyst <NEW_TARGET_IP>
* Certificate Overrides: Because the lab uses self-signed infrastructure certificates, standard browsers (Chrome/Edge) might show a privacy error. Instruct the intern to bypass it using the hidden keyboard command: type thisisunsafe directly onto the error page background, or utilize Mozilla Firefox to easily create a permanent exception.

------------------------------
Would you like me to add any specific sections to this document, such as a troubleshooting checklist or an explanation of how Suricata/Zeek parse the data once the switch or TAP is hooked up?



# Display the GUI window
$form.ShowDialog() | Out-Null
