# PowerShell twin of init-secrets.sh: creates ecommerce-platform/.env with
# freshly generated secrets, or adds the keys it is missing. Existing values are
# never changed. .env is git-ignored (S-4).
#
#   .\init-secrets.ps1           # create or complete .env
#   .\init-secrets.ps1 -Print    # also print the admin and Grafana logins
param([switch]$Print)
$ErrorActionPreference = 'Stop'

$EnvFile = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '.env'

# Alphanumeric only: the values end up in URLs (Eureka) and shell commands.
function New-RandomAlnum([int]$Length) {
    $alphabet = [char[]]'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
    $bytes = New-Object byte[] ($Length * 2)
    $out = ''
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    while ($out.Length -lt $Length) {
        $rng.GetBytes($bytes)
        # 248 = 4 * 62: discarding higher bytes keeps every character equally likely
        foreach ($b in $bytes) { if ($b -lt 248 -and $out.Length -lt $Length) { $out += $alphabet[$b % 62] } }
    }
    $out
}

if (-not (Test-Path $EnvFile)) { New-Item -ItemType File $EnvFile | Out-Null }
$existing = Get-Content $EnvFile

function Add-Secret([string]$Key, [string]$Value) {
    if (-not ($existing | Where-Object { $_ -like "$Key=*" })) {
        # .env is read by docker compose and bash: no BOM, LF line endings
        [System.IO.File]::AppendAllText($EnvFile, "$Key=$Value`n", (New-Object System.Text.UTF8Encoding $false))
        Write-Host "  generated $Key"
    }
}

Write-Host "Secrets in ${EnvFile}:"
# HS512 needs at least 64 bytes; the gateway and user-service refuse anything shorter.
Add-Secret 'JWT_SECRET' (New-RandomAlnum 86)
Add-Secret 'ADMIN_USERNAME' 'admin'
Add-Secret 'ADMIN_PASSWORD' (New-RandomAlnum 24)
Add-Secret 'EUREKA_USERNAME' 'eureka'
Add-Secret 'EUREKA_PASSWORD' (New-RandomAlnum 32)
Add-Secret 'GRAFANA_ADMIN_USER' 'admin'
Add-Secret 'GRAFANA_ADMIN_PASSWORD' (New-RandomAlnum 24)
Write-Host '  done (existing values kept)'

if ($Print) {
    $vals = @{}
    Get-Content $EnvFile | ForEach-Object { if ($_ -match '^([A-Z_]+)=(.*)$') { $vals[$Matches[1]] = $Matches[2] } }
    Write-Host ''
    Write-Host "Shop admin : $($vals.ADMIN_USERNAME) / $($vals.ADMIN_PASSWORD)"
    Write-Host "Grafana    : $($vals.GRAFANA_ADMIN_USER) / $($vals.GRAFANA_ADMIN_PASSWORD)"
    Write-Host "Eureka     : $($vals.EUREKA_USERNAME) / $($vals.EUREKA_PASSWORD)"
}
