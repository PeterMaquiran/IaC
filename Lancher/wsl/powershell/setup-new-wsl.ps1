param(
    [string]$SourceDistro = "Ubuntu-24.04",
    [Parameter(Mandatory = $true)]
    [string]$NewInstance,
    [Parameter(Mandatory = $true)]
    [string]$TargetUser,
    [Parameter(Mandatory = $true)]
    [string]$TargetPass,
    [string]$PubKeyFile = ".\id_ed25519.pub",
    [string]$WgConfFile = ".\wg0.conf"
)

$ErrorActionPreference = "Stop"

$WorkDir     = (Get-Location).Path
$PubKeyPath  = Join-Path $WorkDir $PubKeyFile
$WgConfPath  = Join-Path $WorkDir $WgConfFile
$TempTar     = Join-Path $env:TEMP "$SourceDistro-base.tar.gz"
$InstallDir  = Join-Path $env:LOCALAPPDATA "WSL\$NewInstance"

if (-not (Test-Path $PubKeyPath)) {
    throw "SSH public key file not found: $PubKeyPath"
}
if (-not (Test-Path $WgConfPath)) {
    throw "WireGuard config file not found: $WgConfPath"
}

$PubKey  = (Get-Content -Raw $PubKeyPath).Trim()
$WgConf  = (Get-Content -Raw $WgConfPath) -replace "`r`n", "`n"
$WgB64   = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($WgConf))
$UserB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($TargetUser))
$PassB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($TargetPass))
$KeyB64  = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($PubKey))

# 1. Export a rootfs snapshot from an existing distro and import a new instance
wsl --export $SourceDistro $TempTar
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
wsl --import $NewInstance $InstallDir $TempTar

# 2. Configure packages, sudo user + password, SSH key, and WireGuard inside the new instance
$LinuxSetupCmd = @"
set -euo pipefail
TARGET_USER=\$(printf '%s' '$UserB64' | base64 -d)
TARGET_PASS=\$(printf '%s' '$PassB64' | base64 -d)
PUBKEY=\$(printf '%s' '$KeyB64' | base64 -d)

sudo apt-get update -y
sudo apt-get install -y openssh-server wireguard wireguard-tools

if systemctl list-unit-files | grep -q '^ssh\.socket'; then
  sudo systemctl enable --now ssh.socket
else
  sudo systemctl enable --now ssh
fi

if ! id "\$TARGET_USER" >/dev/null 2>&1; then
  sudo useradd -m -s /bin/bash "\$TARGET_USER"
fi
echo "\$TARGET_USER:\$TARGET_PASS" | sudo chpasswd
sudo usermod -aG sudo "\$TARGET_USER"

sudo mkdir -p "/home/\$TARGET_USER/.ssh"
sudo chmod 700 "/home/\$TARGET_USER/.ssh"
if ! sudo grep -qxF "\$PUBKEY" "/home/\$TARGET_USER/.ssh/authorized_keys" 2>/dev/null; then
  echo "\$PUBKEY" | sudo tee -a "/home/\$TARGET_USER/.ssh/authorized_keys" >/dev/null
fi
sudo chmod 600 "/home/\$TARGET_USER/.ssh/authorized_keys"
sudo chown -R "\$TARGET_USER:\$TARGET_USER" "/home/\$TARGET_USER/.ssh"

printf '%s' '$WgB64' | base64 -d | sudo tee /etc/wireguard/wg0.conf >/dev/null
sudo chmod 600 /etc/wireguard/wg0.conf
sudo systemctl enable --now wg-quick@wg0
"@

$LinuxCmdB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(($LinuxSetupCmd -replace "`r`n", "`n")))
wsl -d $NewInstance -- bash -lc "echo '$LinuxCmdB64' | base64 -d | bash"

if (Test-Path $TempTar) {
    Remove-Item $TempTar -Force
}
