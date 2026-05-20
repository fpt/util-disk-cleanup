# win-cleanup

Disk cleanup tools for Windows. Scans common temp/cache/build locations, reports estimated reclaimable space, and optionally deletes files.

## Tools

| Script | Platform | Description |
|--------|----------|-------------|
| `windows/Cleanup.ps1` | Windows 11 | PowerShell cleanup tool |

## windows/Cleanup.ps1

### Requirements

- PowerShell 5.1+
- Run as your normal user (no admin required for user-space targets)
- For Windows system targets (C:\Windows\Temp, SoftwareDistribution), run as Administrator

### Usage

```powershell
# Dry-run (default) -- shows estimated reclaimable space, no deletions
.\windows\Cleanup.ps1

# Actually delete
.\windows\Cleanup.ps1 -Execute

# Only specific categories
.\windows\Cleanup.ps1 -Categories rust,pip,docker
.\windows\Cleanup.ps1 -Categories rust,pip -Execute
```

### Categories

| Name | Target |
|------|--------|
| `temp` | `%TEMP%` (user temp files) |
| `wintemp` | `C:\Windows\Temp` |
| `wupdate` | `C:\Windows\SoftwareDistribution\Download` |
| `rust` | `target/` dirs under DocumentsRoot |
| `pip` | `%LOCALAPPDATA%\pip\Cache` |
| `go` | `%USERPROFILE%\go\pkg\mod` (via `go clean -modcache`) |
| `gradle` | `%USERPROFILE%\.gradle\caches` |
| `npm` | `%LOCALAPPDATA%\npm-cache`, `%APPDATA%\npm-cache` |
| `cargo` | `%USERPROFILE%\.cargo\registry` |
| `chrome` | Chrome browser cache |
| `edge` | Edge browser cache |
| `docker` | Docker images/containers (via `docker system prune -af --volumes`) |
| `vscode` | VS Code cache dirs |
| `thumbnails` | Windows thumbnail cache |
| `recycle` | Recycle Bin |

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-Execute` | (off) | Actually delete files; dry-run if omitted |
| `-Categories` | `all` | Comma-separated list of categories |
| `-DocumentsRoot` | `$env:USERPROFILE\Documents` | Root to scan for build artifacts |

### Notes

- **Docker**: daemon must be running for pruning. Reports data dir size otherwise.
- **Go cache**: uses `go clean -modcache` to safely clear (Go must be on PATH).
- **Thumbnails**: Windows Explorer needs a restart after deleting thumbcache files.
- **Cargo registry**: only deletes downloaded source; Rust itself remains usable.
