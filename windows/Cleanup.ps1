#Requires -Version 5.1
<#
.SYNOPSIS
    Windows disk cleanup tool with dry-run and space estimation.

.DESCRIPTION
    Scans and optionally deletes temp files, caches, build artifacts, and Docker data.
    Runs in dry-run mode by default -- pass -Execute to actually delete.

.PARAMETER Execute
    Perform actual deletion. Without this flag, only a report is shown.

.PARAMETER Categories
    Comma-separated list of categories to process. Default: all.
    Available: temp, wintemp, wupdate, rust, pip, go, gradle, npm, cargo,
               chrome, edge, docker, vscode, thumbnails, recycle

.PARAMETER DocumentsRoot
    Root directory to scan for project build artifacts.
    Default: $env:USERPROFILE\Documents

.EXAMPLE
    .\Cleanup.ps1
    .\Cleanup.ps1 -Execute
    .\Cleanup.ps1 -Categories rust,pip,docker
    .\Cleanup.ps1 -Categories rust -Execute
#>
param(
    [switch]$Execute,
    [string]$Categories = "all",
    [string]$DocumentsRoot = "$env:USERPROFILE\Documents"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "SilentlyContinue"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Format-Size([long]$bytes) {
    if ($bytes -ge 1GB) { "{0:N2} GB" -f ($bytes / 1GB) }
    elseif ($bytes -ge 1MB) { "{0:N2} MB" -f ($bytes / 1MB) }
    elseif ($bytes -ge 1KB) { "{0:N2} KB" -f ($bytes / 1KB) }
    else { "$bytes B" }
}

function Get-DirSize([string]$path) {
    if (-not (Test-Path $path)) { return 0 }
    $sum = (Get-ChildItem $path -Recurse -Force -File -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return 0 }
    return [long]$sum
}

function Get-PatternSize([string]$root, [string]$pattern) {
    if (-not (Test-Path $root)) { return 0 }
    $total = 0
    Get-ChildItem $root -Recurse -Force -Directory -Filter $pattern -ErrorAction SilentlyContinue |
        ForEach-Object { $total += Get-DirSize $_.FullName }
    return $total
}

function Remove-DirContents([string]$path, [bool]$dryRun) {
    if (-not (Test-Path $path)) { return 0 }
    $freed = 0
    Get-ChildItem $path -Force -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $size = if ($_.PSIsContainer) { Get-DirSize $_.FullName } else { $_.Length }
            if (-not $dryRun) {
                Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                if (-not (Test-Path $_.FullName)) { $freed += $size }
            } else {
                $freed += $size
            }
        } catch {}
    }
    return $freed
}

function Remove-PatternDirs([string]$root, [string]$pattern, [bool]$dryRun) {
    if (-not (Test-Path $root)) { return 0 }
    $freed = 0
    Get-ChildItem $root -Recurse -Force -Directory -Filter $pattern -ErrorAction SilentlyContinue |
        ForEach-Object {
            $size = Get-DirSize $_.FullName
            if (-not $dryRun) {
                Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                if (-not (Test-Path $_.FullName)) { $freed += $size }
            } else {
                $freed += $size
            }
        }
    return $freed
}

function Write-Header([string]$text) {
    Write-Host ""
    Write-Host $text -ForegroundColor Cyan
    Write-Host ("-" * $text.Length) -ForegroundColor DarkCyan
}

function Write-Result([string]$label, [long]$bytes, [string]$note = "") {
    $size  = Format-Size $bytes
    $color = if ($bytes -gt 1GB) { "Yellow" } elseif ($bytes -gt 100MB) { "Green" } else { "Gray" }
    $extra = if ($note) { "  ($note)" } else { "" }
    Write-Host ("  {0,-42} {1,10}{2}" -f $label, $size, $extra) -ForegroundColor $color
}

# ---------------------------------------------------------------------------
# Category selection
# ---------------------------------------------------------------------------

$allCats = @("temp","wintemp","wupdate","rust","pip","go","gradle","npm","cargo",
             "chrome","edge","docker","vscode","thumbnails","recycle")
$selected = if ($Categories -eq "all") {
    $allCats
} else {
    $Categories -split "," | ForEach-Object { $_.Trim().ToLower() }
}

function Should-Run([string]$cat) { return $selected -contains $cat }

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------

$mode      = if ($Execute) { "EXECUTE  <-- files will be deleted!" } else { "DRY-RUN  (pass -Execute to delete)" }
$modeColor = if ($Execute) { "Red" } else { "DarkYellow" }

Write-Host ""
Write-Host "====================================" -ForegroundColor Cyan
Write-Host "    Windows Disk Cleanup Tool       " -ForegroundColor Cyan
Write-Host "====================================" -ForegroundColor Cyan
Write-Host ("Mode : ") -NoNewline
Write-Host $mode -ForegroundColor $modeColor
Write-Host ("Date : {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm"))
Write-Host ""

$totalFreed = [long]0
$results    = [System.Collections.Generic.List[hashtable]]::new()

# ---------------------------------------------------------------------------
# System Temp
# ---------------------------------------------------------------------------

Write-Header "System Temp Files"

if (Should-Run "temp") {
    $p    = $env:TEMP
    $size = Get-DirSize $p
    $freed = Remove-DirContents $p (-not $Execute)
    Write-Result "User TEMP" $size
    $results.Add(@{ Category = "User TEMP"; Freed = $freed })
    $totalFreed += $freed
}

if (Should-Run "wintemp") {
    $p    = "C:\Windows\Temp"
    $size = Get-DirSize $p
    $freed = Remove-DirContents $p (-not $Execute)
    Write-Result "Windows TEMP" $size
    $results.Add(@{ Category = "Windows TEMP"; Freed = $freed })
    $totalFreed += $freed
}

if (Should-Run "wupdate") {
    $p    = "C:\Windows\SoftwareDistribution\Download"
    $size = Get-DirSize $p
    $freed = Remove-DirContents $p (-not $Execute)
    Write-Result "Windows Update Download Cache" $size
    $results.Add(@{ Category = "Windows Update Cache"; Freed = $freed })
    $totalFreed += $freed
}

# ---------------------------------------------------------------------------
# Build Artifacts
# ---------------------------------------------------------------------------

Write-Header "Build Artifacts"

if (Should-Run "rust") {
    $size  = Get-PatternSize $DocumentsRoot "target"
    $freed = Remove-PatternDirs $DocumentsRoot "target" (-not $Execute)
    Write-Result "Rust target/ dirs (scratch)" $size
    $results.Add(@{ Category = "Rust target/ dirs"; Freed = $freed })
    $totalFreed += $freed
}

# ---------------------------------------------------------------------------
# Package Manager Caches
# ---------------------------------------------------------------------------

Write-Header "Package Manager Caches"

if (Should-Run "pip") {
    $p    = "$env:LOCALAPPDATA\pip\Cache"
    $size = Get-DirSize $p
    $freed = Remove-DirContents $p (-not $Execute)
    Write-Result "pip cache" $size
    $results.Add(@{ Category = "pip cache"; Freed = $freed })
    $totalFreed += $freed
}

if (Should-Run "go") {
    $p    = "$env:USERPROFILE\go\pkg\mod"
    $size = Get-DirSize $p
    if ($Execute) { go clean -modcache 2>$null }
    Write-Result "Go module cache" $size "cleared via 'go clean -modcache'"
    $results.Add(@{ Category = "Go module cache"; Freed = $size })
    $totalFreed += $size
}

if (Should-Run "gradle") {
    $p    = "$env:USERPROFILE\.gradle\caches"
    $size = Get-DirSize $p
    $freed = Remove-DirContents $p (-not $Execute)
    Write-Result "Gradle caches" $size
    $results.Add(@{ Category = "Gradle caches"; Freed = $freed })
    $totalFreed += $freed
}

if (Should-Run "npm") {
    $totalSize = [long]0
    $freed     = [long]0
    foreach ($p in @("$env:LOCALAPPDATA\npm-cache", "$env:APPDATA\npm-cache")) {
        $totalSize += Get-DirSize $p
        $freed     += Remove-DirContents $p (-not $Execute)
    }
    Write-Result "npm cache" $totalSize
    $results.Add(@{ Category = "npm cache"; Freed = $freed })
    $totalFreed += $freed
}

if (Should-Run "cargo") {
    $p    = "$env:USERPROFILE\.cargo\registry"
    $size = Get-DirSize $p
    $freed = Remove-DirContents $p (-not $Execute)
    Write-Result "Cargo registry" $size
    $results.Add(@{ Category = "Cargo registry"; Freed = $freed })
    $totalFreed += $freed
}

# ---------------------------------------------------------------------------
# Browser Caches
# ---------------------------------------------------------------------------

Write-Header "Browser Caches"

if (Should-Run "chrome") {
    $totalSize = [long]0
    $freed     = [long]0
    foreach ($p in @(
        "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache",
        "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Code Cache"
    )) {
        $totalSize += Get-DirSize $p
        $freed     += Remove-DirContents $p (-not $Execute)
    }
    Write-Result "Chrome cache" $totalSize
    $results.Add(@{ Category = "Chrome cache"; Freed = $freed })
    $totalFreed += $freed
}

if (Should-Run "edge") {
    $totalSize = [long]0
    $freed     = [long]0
    foreach ($p in @(
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache",
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Code Cache"
    )) {
        $totalSize += Get-DirSize $p
        $freed     += Remove-DirContents $p (-not $Execute)
    }
    Write-Result "Edge cache" $totalSize
    $results.Add(@{ Category = "Edge cache"; Freed = $freed })
    $totalFreed += $freed
}

# ---------------------------------------------------------------------------
# App Caches
# ---------------------------------------------------------------------------

Write-Header "App Caches"

if (Should-Run "vscode") {
    $totalSize = [long]0
    $freed     = [long]0
    foreach ($p in @(
        "$env:APPDATA\Code\Cache",
        "$env:APPDATA\Code\CachedData",
        "$env:APPDATA\Code\CachedExtensionVSIXs"
    )) {
        $totalSize += Get-DirSize $p
        $freed     += Remove-DirContents $p (-not $Execute)
    }
    Write-Result "VS Code cache" $totalSize
    $results.Add(@{ Category = "VS Code cache"; Freed = $freed })
    $totalFreed += $freed
}

if (Should-Run "thumbnails") {
    $p          = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer"
    $thumbFiles = Get-ChildItem $p -Force -Filter "thumbcache_*.db" -ErrorAction SilentlyContinue
    $size       = [long](($thumbFiles | Measure-Object -Property Length -Sum).Sum)
    if ($Execute) { $thumbFiles | Remove-Item -Force -ErrorAction SilentlyContinue }
    Write-Result "Thumbnail cache" $size "Explorer must be restarted"
    $results.Add(@{ Category = "Thumbnail cache"; Freed = $size })
    $totalFreed += $size
}

if (Should-Run "recycle") {
    try {
        $shell = New-Object -ComObject Shell.Application
        $rb    = $shell.Namespace(0xA)
        $size  = [long](($rb.Items() | ForEach-Object { $_.Size } | Measure-Object -Sum).Sum)
        if ($Execute) { Clear-RecycleBin -Force -ErrorAction SilentlyContinue }
        Write-Result "Recycle Bin" $size
        $results.Add(@{ Category = "Recycle Bin"; Freed = $size })
        $totalFreed += $size
    } catch {}
}

# ---------------------------------------------------------------------------
# Docker
# ---------------------------------------------------------------------------

Write-Header "Docker"

if (Should-Run "docker") {
    $dockerPath = "$env:LOCALAPPDATA\Docker"
    $dockerSize = Get-DirSize $dockerPath

    $dockerRunning = $false
    try {
        docker system df 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $dockerRunning = $true }
    } catch {}

    if ($dockerRunning) {
        $reclaimable = [long]0
        try {
            $dfLines = docker system df 2>$null
            $matches = [regex]::Matches(($dfLines -join "`n"), "(\d+(?:\.\d+)?)(kB|MB|GB|B)\s+reclaimable")
            foreach ($m in $matches) {
                $num  = [double]$m.Groups[1].Value
                $unit = $m.Groups[2].Value
                if     ($unit -eq "GB") { $reclaimable += [long]($num * 1GB) }
                elseif ($unit -eq "MB") { $reclaimable += [long]($num * 1MB) }
                elseif ($unit -eq "kB") { $reclaimable += [long]($num * 1KB) }
                else                    { $reclaimable += [long]$num }
            }
        } catch {}

        Write-Result "Docker data dir (total)" $dockerSize
        Write-Result "  reclaimable via prune" $reclaimable "docker system prune -af --volumes"

        if ($Execute) {
            Write-Host "  Running: docker system prune -af --volumes" -ForegroundColor DarkYellow
            docker system prune -af --volumes
        }
        $results.Add(@{ Category = "Docker (reclaimable)"; Freed = $reclaimable })
        $totalFreed += $reclaimable
    } else {
        Write-Result "Docker data dir (daemon not running)" $dockerSize "start Docker Desktop to prune"
        $results.Add(@{ Category = "Docker (daemon offline)"; Freed = 0 })
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "====================================" -ForegroundColor Cyan
Write-Host "              Summary               " -ForegroundColor Cyan
Write-Host "====================================" -ForegroundColor Cyan

foreach ($r in $results) {
    if ($r.Freed -gt 0) {
        $color = if ($r.Freed -gt 1GB) { "Yellow" } elseif ($r.Freed -gt 100MB) { "Green" } else { "Gray" }
        Write-Host ("  {0,-42} {1,10}" -f $r.Category, (Format-Size $r.Freed)) -ForegroundColor $color
    }
}

Write-Host ""
$totalLabel = if ($Execute) { "Total freed" } else { "Estimated reclaimable" }
Write-Host ("  {0,-42} {1,10}" -f $totalLabel, (Format-Size $totalFreed)) -ForegroundColor White
Write-Host ""

if (-not $Execute) {
    Write-Host "  Run with -Execute to free this space." -ForegroundColor DarkYellow
    Write-Host ""
}
