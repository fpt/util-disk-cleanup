# disk-cleanup

Disk cleanup tools for Windows, macOS, and Linux. Each tool scans common temp/cache/build locations, reports estimated reclaimable space, and optionally deletes files.

**Dry run is the default -- nothing is deleted unless you ask for it.**

## Tools

| Platform | Script | Status |
|----------|--------|--------|
| Windows | [`windows/Cleanup.ps1`](windows/Cleanup.ps1) | Available |
| macOS | [`macos/cleanup.sh`](macos/README.md) | Available |
| Linux | [`linux/`](linux/README.md) | Planned |

## macOS

See [macos/README.md](macos/README.md). Same model as Windows: `macos/cleanup.sh` is a dry run by default, `--execute` deletes, and `--categories` / `--exclude` / `--list` filter.

## windows/Cleanup.ps1

### Requirements

- PowerShell 5.1+
- Run as your normal user (no admin required for user-space targets)
- For `[admin]` targets (`wintemp`, `wupdate`, `delivery`), run as Administrator

### Usage

```powershell
# Dry-run (default) -- shows estimated reclaimable space, no deletions
.\windows\Cleanup.ps1

# Actually delete
.\windows\Cleanup.ps1 -Execute

# List available categories
.\windows\Cleanup.ps1 -List

# Only specific categories
.\windows\Cleanup.ps1 -Categories rust,pip,docker
.\windows\Cleanup.ps1 -Categories rust,pip -Execute

# Everything except a few
.\windows\Cleanup.ps1 -Exclude recycle,huggingface -Execute
```

If you get an execution-policy error:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File windows\Cleanup.ps1
```

### Categories

| Name | Target |
|------|--------|
| **System** | |
| `temp` | `%TEMP%`, `%LOCALAPPDATA%\Temp` |
| `wintemp` | `C:\Windows\Temp` (admin) |
| `wupdate` | `C:\Windows\SoftwareDistribution\Download` (admin; stops/restarts `wuauserv`) |
| `delivery` | `C:\Windows\SoftwareDistribution\DeliveryOptimization` (admin) |
| `thumbnails` | Explorer `thumbcache_*.db` / `iconcache_*.db` |
| `crashdumps` | `%LOCALAPPDATA%\CrashDumps`, Windows Error Reporting |
| `recycle` | Recycle Bin (all drives) |
| **Browsers** | |
| `chrome` | Chrome `Cache`, `Code Cache`, `GPUCache` (all profiles) |
| `edge` | Edge `Cache`, `Code Cache`, `GPUCache` (all profiles) |
| `firefox` | Firefox `cache2` (all profiles) |
| **Package caches** | |
| `npm` | `%LOCALAPPDATA%\npm-cache`, `%APPDATA%\npm-cache`, `~\.npm\_cacache` |
| `pip` | `%LOCALAPPDATA%\pip\Cache` |
| `uv` | `%LOCALAPPDATA%\uv\cache` |
| `cargo` | `~\.cargo\registry\cache` and `src` (index is kept) |
| `go` | Go module cache (via `go clean -modcache` if Go is on PATH) |
| `gradle` | `~\.gradle\caches` |
| `nuget` | `~\.nuget\packages` |
| `huggingface` | `~\.cache\huggingface\hub` (lists each model with size / last use) |
| **Build artifacts** | |
| `rust` | `target\` dirs next to a `Cargo.toml` under `-DocumentsRoot` |
| **Apps** | |
| `vscode` | VS Code cache dirs |
| **Docker** | |
| `docker` | `docker system prune -af` (images, containers, networks, build cache) |

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-Execute` (alias `-Run`) | (off) | Actually delete files; dry-run if omitted |
| `-Categories` | `all` | Comma-separated list of categories |
| `-Exclude` | (none) | Comma-separated list of categories to skip |
| `-List` | (off) | Print categories and exit |
| `-DocumentsRoot` | `$env:USERPROFILE\Documents` | Root to scan for build artifacts |

### Notes

- With `-Execute`, each target is re-measured after cleaning, so "freed" is what actually went away. Files that were in use or access-denied are reported as left over.
- **Docker**: daemon must be running; otherwise the category is skipped. Volumes are **not** pruned, since they may hold database or app state.
- **Rust**: only `target\` dirs whose parent has a `Cargo.toml` are removed, so Maven and other `target` folders are left alone.
- **Thumbnails**: restart Explorer after deleting thumbcache files.
- **Browsers**: close them first to avoid locked files.
- Package caches re-download on next use, so the first build afterward is slower.
- Nothing touches documents, Downloads, or installed programs.
