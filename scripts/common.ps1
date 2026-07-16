Set-StrictMode -Version Latest

function Get-BridgeRoot {
    return (Split-Path -Parent $PSScriptRoot)
}

function Get-BridgeConfigPath {
    $root = Get-BridgeRoot
    return (Join-Path $root 'config\bridge.local.json')
}

function Read-BridgeConfig {
    $path = Get-BridgeConfigPath
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Bridge configuration not found: $path. Run Install.cmd first."
    }
    return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Test-LocalPort {
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [string]$HostName = '127.0.0.1',
        [int]$TimeoutMs = 800
    )
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Wait-LocalPort {
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [int]$Seconds = 30,
        [string]$HostName = '127.0.0.1'
    )
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        if (Test-LocalPort -Port $Port -HostName $HostName) { return $true }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Start-HiddenPowerShell {
    param([Parameter(Mandatory = $true)][string]$ScriptPath)
    $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`""
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden | Out-Null
}

function Set-JsonProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Value
    )
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function ConvertTo-ShellSingleQuoted {
    param([Parameter(Mandatory = $true)][string]$Value)
    if ($Value.Contains("'")) {
        throw "Paths containing a single quote are not supported: $Value"
    }
    return "'$Value'"
}

function Get-WslHome {
    param([Parameter(Mandatory = $true)][string]$Distro)
    $home = (& wsl.exe -d $Distro -- bash -lc 'printf %s "$HOME"') 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($home)) {
        throw "Unable to resolve WSL home for distro '$Distro'."
    }
    return $home.Trim()
}

function Convert-WslPathToUnc {
    param(
        [Parameter(Mandatory = $true)][string]$Distro,
        [Parameter(Mandatory = $true)][string]$LinuxPath
    )
    $relative = $LinuxPath.TrimStart('/') -replace '/', '\'
    return "\\wsl.localhost\$Distro\$relative"
}
