#Requires -Version 5.1
<#
.SYNOPSIS
    Windows disk cleanup tool with dry-run and space estimation.

.DESCRIPTION
    Scans well-known temp, cache, and build-artifact locations, reports how much
    each would free, and optionally deletes them.

    DRY RUN IS THE DEFAULT. Nothing is deleted unless you pass -Execute.

.PARAMETER Execute
    Perform actual deletion. Without this flag, only a report is shown.
    Alias: -Run

.PARAMETER Categories
    Comma-separated list of categories to process. Default: all.
    Use -List to see the available names.

.PARAMETER Exclude
    Comma-separated list of categories to skip.

.PARAMETER List
    Print the available categories and exit.

.PARAMETER DocumentsRoot
    Root directory to scan for project build artifacts (Rust target/ dirs).
    Default: $env:USERPROFILE\Documents

.EXAMPLE
    .\Cleanup.ps1
    .\Cleanup.ps1 -Execute
    .\Cleanup.ps1 -Categories rust,pip,docker
    .\Cleanup.ps1 -Exclude recycle,huggingface -Execute
    .\Cleanup.ps1 -List
#>
[CmdletBinding()]
param(
    [Alias('Run')]
    [switch]$Execute,
    [string[]]$Categories = @('all'),
    [string[]]$Exclude,
    [switch]$List,
    [string]$DocumentsRoot = "$env:USERPROFILE\Documents"
)

# Locked / in-use files are skipped rather than aborting the run.
$ErrorActionPreference = 'SilentlyContinue'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Format-Size([long]$bytes) {
    if ($bytes -ge 1GB) { return ('{0:N2} GB' -f ($bytes / 1GB)) }
    if ($bytes -ge 1MB) { return ('{0:N2} MB' -f ($bytes / 1MB)) }
    if ($bytes -ge 1KB) { return ('{0:N2} KB' -f ($bytes / 1KB)) }
    return "$bytes B"
}

function Get-FolderSize([string[]]$paths) {
    $total = 0L
    foreach ($p in $paths) {
        if ($p -and (Test-Path -LiteralPath $p)) {
            $sum = (Get-ChildItem -LiteralPath $p -Recurse -Force -File |
                    Measure-Object -Property Length -Sum).Sum
            if ($sum) { $total += [long]$sum }
        }
    }
    return $total
}

function Get-FilesSize($files) {
    $sum = ($files | Measure-Object -Property Length -Sum).Sum
    if ($sum) { return [long]$sum }
    return 0L
}

# Clears the *contents* of the given folders, leaving the folders themselves.
function Clear-FolderContents([string[]]$paths) {
    foreach ($p in $paths) {
        if ($p -and (Test-Path -LiteralPath $p)) {
            Get-ChildItem -LiteralPath $p -Force | ForEach-Object {
                Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# Removes the given folders entirely.
function Remove-Folders([string[]]$paths) {
    foreach ($p in $paths) {
        if ($p -and (Test-Path -LiteralPath $p)) {
            Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# Cache dirs for every profile (Default, Profile 1, ...) of a Chromium browser.
function Get-ChromiumCacheDirs([string]$userData) {
    if (-not (Test-Path -LiteralPath $userData)) { return @() }
    Get-ChildItem -LiteralPath $userData -Directory -Force |
        Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' } |
        ForEach-Object {
            foreach ($sub in @('Cache', 'Code Cache', 'GPUCache')) { Join-Path $_.FullName $sub }
        }
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------------------
# Target definitions
# ---------------------------------------------------------------------------
# Each target:
#   Name        category name used by -Categories / -Exclude
#   Group       section header in the report
#   Description shown next to the size
#   Measure     scriptblock returning bytes; must size exactly what Clean removes
#   Clean       scriptblock that performs deletion (only called with -Execute)
#   Detail      optional scriptblock printing an indented per-item breakdown
#   Skip        optional scriptblock returning a reason string if unavailable
#   Admin       true if elevation is needed to fully clean

$localAppData = $env:LOCALAPPDATA
$appData      = $env:APPDATA
$userProfile  = $env:USERPROFILE

$targets = [System.Collections.Generic.List[object]]::new()

function Add-Target {
    param(
        [string]$Name, [string]$Group, [string]$Description,
        [scriptblock]$Measure, [scriptblock]$Clean,
        [scriptblock]$Detail, [scriptblock]$Skip, [switch]$Admin
    )
    $targets.Add([pscustomobject]@{
        Name = $Name; Group = $Group; Description = $Description
        Measure = $Measure; Clean = $Clean; Detail = $Detail; Skip = $Skip
        Admin = [bool]$Admin
    })
}

# --- System ----------------------------------------------------------------

$userTemp = @($env:TEMP, "$localAppData\Temp") | Select-Object -Unique
Add-Target 'temp' 'System' 'User temp files (%TEMP%)' `
    { Get-FolderSize $userTemp } { Clear-FolderContents $userTemp }

$winTemp = @("$env:SystemRoot\Temp")
Add-Target 'wintemp' 'System' 'Windows temp files (C:\Windows\Temp)' -Admin `
    { Get-FolderSize $winTemp } { Clear-FolderContents $winTemp }

$wuCache = @("$env:SystemRoot\SoftwareDistribution\Download")
Add-Target 'wupdate' 'System' 'Windows Update download cache' -Admin `
    { Get-FolderSize $wuCache } `
    {
        Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
        Clear-FolderContents $wuCache
        Start-Service wuauserv -ErrorAction SilentlyContinue
    }

$doCache = @("$env:SystemRoot\SoftwareDistribution\DeliveryOptimization")
Add-Target 'delivery' 'System' 'Delivery Optimization cache' -Admin `
    { Get-FolderSize $doCache } { Clear-FolderContents $doCache }

$explorerDir = "$localAppData\Microsoft\Windows\Explorer"
function Get-ThumbFiles {
    Get-ChildItem -LiteralPath $explorerDir -Force -File |
        Where-Object { $_.Name -like 'thumbcache_*.db' -or $_.Name -like 'iconcache_*.db' }
}
Add-Target 'thumbnails' 'System' 'Explorer thumbnail/icon cache (restart Explorer after)' `
    { Get-FilesSize (Get-ThumbFiles) } `
    { Get-ThumbFiles | Remove-Item -Force -ErrorAction SilentlyContinue }

$crashDirs = @("$localAppData\CrashDumps", "$localAppData\Microsoft\Windows\WER")
Add-Target 'crashdumps' 'System' 'Crash dumps / Windows Error Reporting' `
    { Get-FolderSize $crashDirs } { Clear-FolderContents $crashDirs }

Add-Target 'recycle' 'System' 'Recycle Bin (all drives)' `
    {
        $bin = (New-Object -ComObject Shell.Application).Namespace(0xA)
        $sum = 0L
        foreach ($i in $bin.Items()) { $sum += [long]$i.Size }
        $sum
    } `
    { Clear-RecycleBin -Force -ErrorAction SilentlyContinue }

# --- Browsers --------------------------------------------------------------

$chromeCache = @(Get-ChromiumCacheDirs "$localAppData\Google\Chrome\User Data")
Add-Target 'chrome' 'Browsers' 'Chrome cache (all profiles)' `
    { Get-FolderSize $chromeCache } { Clear-FolderContents $chromeCache }

$edgeCache = @(Get-ChromiumCacheDirs "$localAppData\Microsoft\Edge\User Data")
Add-Target 'edge' 'Browsers' 'Edge cache (all profiles)' `
    { Get-FolderSize $edgeCache } { Clear-FolderContents $edgeCache }

$ffProfiles = "$localAppData\Mozilla\Firefox\Profiles"
$ffCache = @()
if (Test-Path -LiteralPath $ffProfiles) {
    $ffCache = @(Get-ChildItem -LiteralPath $ffProfiles -Directory -Force |
                 ForEach-Object { Join-Path $_.FullName 'cache2' })
}
Add-Target 'firefox' 'Browsers' 'Firefox cache (all profiles)' `
    { Get-FolderSize $ffCache } { Clear-FolderContents $ffCache }

# --- Package manager caches ------------------------------------------------

$npmCache = @("$localAppData\npm-cache", "$appData\npm-cache", "$userProfile\.npm\_cacache")
Add-Target 'npm' 'Package caches' 'npm cache' `
    { Get-FolderSize $npmCache } { Clear-FolderContents $npmCache }

$pipCache = @("$localAppData\pip\Cache")
Add-Target 'pip' 'Package caches' 'pip download cache' `
    { Get-FolderSize $pipCache } { Clear-FolderContents $pipCache }

$uvCache = @("$localAppData\uv\cache")
Add-Target 'uv' 'Package caches' 'uv (Python) package cache' `
    { Get-FolderSize $uvCache } { Clear-FolderContents $uvCache }

# Only downloaded crates and extracted sources; the registry index is kept.
$cargoCache = @("$userProfile\.cargo\registry\cache", "$userProfile\.cargo\registry\src")
Add-Target 'cargo' 'Package caches' 'Cargo registry cache + sources' `
    { Get-FolderSize $cargoCache } { Clear-FolderContents $cargoCache }

$goModCache = "$userProfile\go\pkg\mod"
if ($env:GOMODCACHE) { $goModCache = $env:GOMODCACHE }
elseif ($env:GOPATH) { $goModCache = Join-Path (($env:GOPATH -split ';')[0]) 'pkg\mod' }
Add-Target 'go' 'Package caches' 'Go module cache' `
    { Get-FolderSize @($goModCache) } `
    {
        if (Get-Command go -ErrorAction SilentlyContinue) {
            go clean -modcache 2>$null | Out-Null
        } else {
            Clear-FolderContents @($goModCache)
        }
    }

$gradleCache = @("$userProfile\.gradle\caches")
Add-Target 'gradle' 'Package caches' 'Gradle caches' `
    { Get-FolderSize $gradleCache } { Clear-FolderContents $gradleCache }

$nugetCache = @("$userProfile\.nuget\packages")
Add-Target 'nuget' 'Package caches' 'NuGet global packages' `
    { Get-FolderSize $nugetCache } { Clear-FolderContents $nugetCache }

$hfHub = "$userProfile\.cache\huggingface\hub"
Add-Target 'huggingface' 'Package caches' 'HuggingFace model cache (re-downloads on demand)' `
    { Get-FolderSize @($hfHub) } `
    { Clear-FolderContents @($hfHub) } `
    -Detail {
        if (-not (Test-Path -LiteralPath $hfHub)) { return }
        Get-ChildItem -LiteralPath $hfHub -Directory -Force |
            Where-Object { $_.Name -like 'models--*' } |
            ForEach-Object {
                $model = ($_.Name -replace '^models--', '') -replace '--', '/'
                [pscustomobject]@{ Size = (Get-FolderSize @($_.FullName)); Model = $model; Used = $_.LastWriteTime }
            } | Sort-Object Size -Descending | ForEach-Object {
                Write-Host ('      {0,10}  {1,-38} last used {2:yyyy-MM-dd}' -f `
                    (Format-Size $_.Size), $_.Model, $_.Used) -ForegroundColor DarkCyan
            }
    }

# --- Build artifacts -------------------------------------------------------

# Only target/ dirs next to a Cargo.toml, so Maven or other "target" dirs are
# left alone. Nested matches are dropped to avoid double counting.
$script:rustDirs = $null
function Get-RustTargetDirs {
    if ($null -ne $script:rustDirs) { return $script:rustDirs }
    $found = @()
    if (Test-Path -LiteralPath $DocumentsRoot) {
        $found = @(Get-ChildItem -LiteralPath $DocumentsRoot -Recurse -Force -Directory -Filter 'target' |
                   Where-Object { Test-Path -LiteralPath (Join-Path $_.Parent.FullName 'Cargo.toml') } |
                   ForEach-Object { $_.FullName } | Sort-Object)
    }
    $kept = @()
    foreach ($d in $found) {
        $nested = $false
        foreach ($k in $kept) { if ($d.StartsWith($k + '\')) { $nested = $true; break } }
        if (-not $nested) { $kept += $d }
    }
    $script:rustDirs = $kept
    return $kept
}
Add-Target 'rust' 'Build artifacts' "Rust target/ dirs under $DocumentsRoot" `
    { Get-FolderSize (Get-RustTargetDirs) } `
    { Remove-Folders (Get-RustTargetDirs); $script:rustDirs = $null } `
    -Detail {
        foreach ($d in (Get-RustTargetDirs)) {
            $s = Get-FolderSize @($d)
            if ($s -gt 0) {
                Write-Host ('      {0,10}  {1}' -f (Format-Size $s), $d) -ForegroundColor DarkCyan
            }
        }
    }

# --- Apps ------------------------------------------------------------------

$vscodeCache = @(
    "$appData\Code\Cache",
    "$appData\Code\CachedData",
    "$appData\Code\CachedExtensionVSIXs",
    "$appData\Code\Code Cache",
    "$appData\Code\GPUCache"
)
Add-Target 'vscode' 'Apps' 'VS Code cache' `
    { Get-FolderSize $vscodeCache } { Clear-FolderContents $vscodeCache }

# --- Docker ----------------------------------------------------------------

function Test-DockerRunning {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $false }
    docker info --format '{{.ServerVersion}}' 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# Parses docker's human-readable sizes ("1.234GB (45%)"); docker uses SI units.
function ConvertFrom-DockerSize([string]$text) {
    if ($text -notmatch '^\s*([\d.]+)\s*(B|kB|KB|MB|GB|TB)') { return 0L }
    $n = [double]$Matches[1]
    $mult = 1
    switch ($Matches[2]) {
        'kB' { $mult = 1e3 }
        'KB' { $mult = 1e3 }
        'MB' { $mult = 1e6 }
        'GB' { $mult = 1e9 }
        'TB' { $mult = 1e12 }
    }
    return [long]($n * $mult)
}

# Volumes are excluded: they may hold database or app state, not just cache.
Add-Target 'docker' 'Docker' 'Unused images, containers, networks, build cache' `
    {
        $sum = 0L
        docker system df --format '{{.Type}}|{{.Reclaimable}}' 2>$null | ForEach-Object {
            $parts = $_ -split '\|', 2
            if ($parts.Count -eq 2 -and $parts[0] -ne 'Local Volumes') {
                $sum += ConvertFrom-DockerSize $parts[1]
            }
        }
        $sum
    } `
    { docker system prune -af 2>$null | Out-Null } `
    -Skip {
        if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return 'docker not installed' }
        if (-not (Test-DockerRunning)) { return 'daemon not running; start Docker Desktop' }
    }

# ---------------------------------------------------------------------------
# List mode
# ---------------------------------------------------------------------------

if ($List) {
    Write-Host ""
    Write-Host "Available categories:"
    $group = ''
    foreach ($t in $targets) {
        if ($t.Group -ne $group) {
            $group = $t.Group
            Write-Host ""
            Write-Host "  $group" -ForegroundColor Cyan
        }
        $admin = ''
        if ($t.Admin) { $admin = '  [admin]' }
        Write-Host ('    {0,-14} {1}{2}' -f $t.Name, $t.Description, $admin)
    }
    Write-Host ""
    return
}

# ---------------------------------------------------------------------------
# Category selection
# ---------------------------------------------------------------------------

# Normalize so both -Categories a,b (real array) and a single "a,b" string
# (as passed by powershell.exe -File) work the same way.
function Split-Names([string[]]$names) {
    $names | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToLower() } |
        Where-Object { $_ }
}

$allNames = @($targets | ForEach-Object { $_.Name })
$inc = @(Split-Names $Categories)
$exc = @(Split-Names $Exclude)

$unknown = @(($inc + $exc) | Where-Object { $_ -ne 'all' -and $allNames -notcontains $_ })
if ($unknown.Count -gt 0) {
    Write-Warning ("Unknown categories: {0}. Use -List to see available names." -f ($unknown -join ', '))
}

$selected = @($targets | Where-Object {
    ($inc -contains 'all' -or $inc -contains $_.Name) -and ($exc -notcontains $_.Name)
})

if ($selected.Count -eq 0) {
    Write-Warning "No categories selected. Use -List to see available names."
    return
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------

$isAdmin   = Test-IsAdmin
$mode      = if ($Execute) { "EXECUTE  <-- files will be deleted!" } else { "DRY-RUN  (pass -Execute to delete)" }
$modeColor = if ($Execute) { "Red" } else { "DarkYellow" }

Write-Host ""
Write-Host "====================================" -ForegroundColor Cyan
Write-Host "    Windows Disk Cleanup Tool       " -ForegroundColor Cyan
Write-Host "====================================" -ForegroundColor Cyan
Write-Host "Mode : " -NoNewline
Write-Host $mode -ForegroundColor $modeColor
Write-Host ("Date : {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm"))
if (-not $isAdmin -and @($selected | Where-Object { $_.Admin }).Count -gt 0) {
    Write-Host "Note : not elevated; [admin] categories may be partially cleaned" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

$results    = [System.Collections.Generic.List[object]]::new()
$totalBytes = 0L
$group      = ''

foreach ($t in $selected) {
    if ($t.Group -ne $group) {
        $group = $t.Group
        Write-Host ""
        Write-Host $group -ForegroundColor Cyan
        Write-Host ("-" * $group.Length) -ForegroundColor DarkCyan
    }

    $admin = ''
    if ($t.Admin -and -not $isAdmin) { $admin = ' [admin]' }

    if ($t.Skip) {
        $reason = & $t.Skip
        if ($reason) {
            Write-Host ('  {0,-14} {1,10}   {2}{3}  (skipped: {4})' -f $t.Name, '-', $t.Description, $admin, $reason) `
                -ForegroundColor DarkGray
            continue
        }
    }

    $size  = [long](& $t.Measure)
    $color = if ($size -gt 1GB) { "Yellow" } elseif ($size -gt 100MB) { "Green" } elseif ($size -gt 0) { "White" } else { "DarkGray" }
    Write-Host ('  {0,-14} {1,10}   {2}{3}' -f $t.Name, (Format-Size $size), $t.Description, $admin) -ForegroundColor $color

    if ($size -le 0) { continue }
    if ($t.Detail) { & $t.Detail }

    $freed = $size
    if ($Execute) {
        try {
            & $t.Clean
            $after = [long](& $t.Measure)
            $freed = [math]::Max(0L, $size - $after)
            $note  = ''
            if ($after -gt 0) { $note = ' ({0} left: in use or access denied)' -f (Format-Size $after) }
            Write-Host ('  {0,-14} {1,10}   freed{2}' -f '', (Format-Size $freed), $note) -ForegroundColor Green
        } catch {
            $freed = 0L
            Write-Host ('  {0,-14} FAILED: {1}' -f '', $_.Exception.Message) -ForegroundColor Red
        }
    }

    $results.Add([pscustomobject]@{ Name = $t.Name; Bytes = $freed })
    $totalBytes += $freed
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "====================================" -ForegroundColor Cyan
Write-Host "              Summary               " -ForegroundColor Cyan
Write-Host "====================================" -ForegroundColor Cyan

foreach ($r in ($results | Sort-Object Bytes -Descending)) {
    if ($r.Bytes -gt 0) {
        $color = if ($r.Bytes -gt 1GB) { "Yellow" } elseif ($r.Bytes -gt 100MB) { "Green" } else { "Gray" }
        Write-Host ('  {0,-28} {1,10}' -f $r.Name, (Format-Size $r.Bytes)) -ForegroundColor $color
    }
}

Write-Host ""
$totalLabel = if ($Execute) { "Total freed" } else { "Estimated reclaimable" }
Write-Host ('  {0,-28} {1,10}' -f $totalLabel, (Format-Size $totalBytes)) -ForegroundColor White
Write-Host ""

if (-not $Execute -and $totalBytes -gt 0) {
    Write-Host "  Run with -Execute to free this space." -ForegroundColor DarkYellow
    Write-Host ""
}
