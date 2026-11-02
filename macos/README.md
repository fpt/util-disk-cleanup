# macOS cleanup

`cleanup.sh` scans common cache and build-artifact locations, reports how much
space each would free, and optionally deletes them.

**Dry run is the default -- nothing is deleted unless you pass `--execute`.**

## Requirements

- macOS (uses `~/Library` paths and `/System/Volumes/Data`)
- Bash 3.2+ (works with the stock `/bin/bash`)
- Optional: `brew`, `go`, `docker`. If a target's tool is missing, the target is reported as skipped.
- For `trash`, your terminal needs Full Disk Access. Without it, the target is skipped.

## Usage

```bash
# Dry-run (default) -- shows estimated reclaimable space, no deletions
macos/cleanup.sh

# Actually delete
macos/cleanup.sh --execute

# List available categories
macos/cleanup.sh --list

# Only specific categories
macos/cleanup.sh --categories rust,pip,docker
macos/cleanup.sh --categories rust,pip --execute

# Everything except a few
macos/cleanup.sh --exclude trash,huggingface --execute

# Scan other roots for Rust target/ dirs (space-separated; also via SCAN_ROOTS)
macos/cleanup.sh --categories rust --scan-roots "~/src ~/work"
```

## Options

| Option | Default | Description |
|--------|---------|-------------|
| `--execute` (alias `--run`) | (off) | Actually delete files; dry-run if omitted |
| `--categories` | `all` | Comma-separated list of categories |
| `--exclude` | (none) | Comma-separated list of categories to skip |
| `--list` | (off) | Print categories and exit |
| `--scan-roots` | `~/Documents ~/src ~/projects ~/work ~/dev` | Roots scanned for Rust build artifacts (or set `SCAN_ROOTS`) |

## Categories

| Name | Target |
|------|--------|
| **System** | |
| `trash` | `~/.Trash` (a real delete) |
| **Browsers** | |
| `chrome` | `~/Library/Caches/Google` |
| `edge` | `~/Library/Caches/Microsoft Edge` |
| `firefox` | `~/Library/Caches/Firefox` |
| **Package caches** | |
| `homebrew` | `$(brew --cache)` |
| `npm` | `~/.npm/_cacache` |
| `yarn` | `~/Library/Caches/Yarn` |
| `pip` | `~/Library/Caches/pip` |
| `uv` | `$UV_CACHE_DIR` or `~/.cache/uv` |
| `cargo` | `~/.cargo/registry/cache` and `src` (index is kept) |
| `go` | `$(go env GOMODCACHE)` via `go clean -modcache` |
| `gobuild` | `$(go env GOCACHE)` |
| `goimports` | `~/Library/Caches/goimports` |
| `gradle` | `~/.gradle/caches` |
| `cocoapods` | `~/Library/Caches/CocoaPods` |
| `swiftpm` | `~/Library/Caches/org.swift.swiftpm` |
| **Model caches** | |
| `huggingface` | `$HF_HOME/hub` or `~/.cache/huggingface/hub` (lists each model with size / last use) |
| `whisper` | `~/.cache/whisper` |
| `torch` | `$TORCH_HOME` or `~/.cache/torch` |
| **Build artifacts** | |
| `rust` | `target/` dirs next to a `Cargo.toml` under `--scan-roots` |
| `xcode` | `~/Library/Developer/Xcode/DerivedData` |
| **Apps** | |
| `vscode` | VS Code cache dirs in `~/Library/Application Support/Code`, plus its ShipIt updater cache |
| `claude` | Claude Desktop ShipIt updater cache, `~/Library/Caches/claude-cli-nodejs` |
| `electron` | `~/Library/Caches/electron` |
| `playwright` | `~/Library/Caches/ms-playwright-go` |
| `arduino` | `~/Library/Arduino15/staging`, `~/Library/Caches/arduino` |
| **Docker** | |
| `docker` | `docker system prune -af` (images, containers, networks, build cache) |

## Reported but never deleted

Some directories are large and technically regenerable, but wiping them breaks a
working toolchain until it is re-downloaded. If one of these is over 512 MB, it is
listed under "review these yourself":

| Path | How to trim it |
|------|----------------|
| `~/Library/Arduino15/packages` | Re-install boards via Board Manager |
| `~/Library/Android/sdk` | Re-install via SDK Manager; breaks existing AVDs |
| `~/Library/Developer/CoreSimulator/Devices` | `xcrun simctl delete unavailable` |
| `~/.rustup` | `rustup toolchain uninstall <old>` |
| `~/temp` | Your own files |

## Notes

- With `--execute`, each target is re-measured after cleaning, so "freed" is what actually went away. Files that couldn't be deleted (permission denied) are reported as left over.
- The disk line reads `/System/Volumes/Data`, not `/`. On APFS, `df /` reports the sealed system snapshot and badly understates real usage.
- **Docker**: the daemon must be running, otherwise the category is skipped. Volumes are **not** pruned because they may hold database or app state. Freed space may not show on the host until Docker Desktop trims `Docker.raw`.
- **HuggingFace**: the whole hub is cleared. To drop only some models, use the per-model listing and `rm -rf ~/.cache/huggingface/hub/models--<org>--<name>`.
- **Rust**: only `target/` dirs whose parent has a `Cargo.toml` are removed, so Maven and other `target` folders are left alone.
- Package caches re-download on next use, so the first build afterward is slower.
- Nothing touches documents, Downloads, or installed apps.
