$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$patterns = @(
    'sk-[A-Za-z0-9_-]{16,}',
    'ghp_[A-Za-z0-9]{20,}',
    'github_pat_[A-Za-z0-9_]{20,}',
    'agt_codex_[A-Za-z0-9_-]{10,}',
    'C:\\Users\\[^<\\]+',
    '/home/[^<\/\s]+'
)
$excluded = @('.git', 'node_modules', 'logs')
$hits = @()

Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object {
    $relative = $_.FullName.Substring($root.Length).TrimStart('\')
    $isExcludedDirectory = [bool]($excluded | Where-Object { $relative -like "$_\*" })
    $isScanner = $relative -in @('scripts\check-secrets.ps1', 'tests\no-secrets.test.mjs')
    -not $isExcludedDirectory -and -not $isScanner
} | ForEach-Object {
    $content = Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue
    foreach ($pattern in $patterns) {
        if ($content -match $pattern) {
            $hits += "$($_.FullName): pattern $pattern"
        }
    }
}

if ($hits.Count -gt 0) {
    $hits | ForEach-Object { Write-Error $_ }
    exit 1
}
Write-Host 'No obvious secrets or personal absolute paths found.'
