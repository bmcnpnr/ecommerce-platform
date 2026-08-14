$hasErrors = $false

Get-ChildItem -Path /workspace -Filter '*.ps1' | ForEach-Object {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $_.FullName,
        [ref]$tokens,
        [ref]$parseErrors
    ) | Out-Null

    if ($parseErrors.Count -eq 0) {
        Write-Host "PowerShell syntax OK: $($_.Name)"
    } else {
        $hasErrors = $true
        $parseErrors | ForEach-Object {
            Write-Error "$($_.Extent.File):$($_.Extent.StartLineNumber): $($_.Message)"
        }
    }
}

if ($hasErrors) {
    exit 1
}
