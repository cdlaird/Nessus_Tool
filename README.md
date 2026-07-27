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

# Display the GUI window
$form.ShowDialog() | Out-Null
