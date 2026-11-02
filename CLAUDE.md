# CLAUDE.md -- disk-cleanup

## Project purpose

Disk cleanup tools for Windows, macOS, and Linux, one script per platform. Every tool is dry-run by default and supports category filtering.

## Structure

```
disk-cleanup/
  windows/
    Cleanup.ps1    # Windows tool (PowerShell)
  macos/
    cleanup.sh     # macOS tool (bash 3.2)
  linux/           # planned (POSIX shell)
  README.md
  CLAUDE.md
```

## Core design rules (all platforms)

- **Dry run is the default.** Nothing is deleted unless the caller passes `-Execute` (Windows) / `--execute` (shell). Preserve this invariant in any change.
- **Targets are data-driven.** Each cleanup location is one target entry with a name, a measure step, and a clean step. Don't special-case logic in the main loop.
- **Measure and Clean must agree.** A target's Measure must size exactly what its Clean removes, so the reported total is honest. In execute mode, freed = before - after.
- Clear folder *contents*, not the folders themselves, unless a target has a reason to do otherwise.
- Locked / in-use / access-denied files are skipped silently; they never abort the run.

## Windows constraints

- **PowerShell 5.1 compatible**: no ternary operator, no `??` / `?.`, no `&&`/`||` pipeline chains, no `switch` as rvalue expression.
- **ASCII-only string literals**: the script file is read by PowerShell as Windows-1252 if no UTF-8 BOM is present. Multi-byte UTF-8 sequences (box-drawing chars, etc.) corrupt string literals because byte 0x94 is `"` in Windows-1252. Keep all string content ASCII.
- **No admin assumption**: user-space paths work without elevation. System paths are flagged `-Admin` and silently skip files they can't delete.

## Testing (Windows)

```powershell
# Dry-run (safe, no deletions)
powershell -NoProfile -ExecutionPolicy Bypass -File windows/Cleanup.ps1

# Specific categories
powershell -NoProfile -ExecutionPolicy Bypass -File windows/Cleanup.ps1 -Categories rust,pip
```

Test destructive paths (`-Execute`) with a narrow `-Categories` on a low-risk target. For example, run `rust` with `-DocumentsRoot` pointing at a throwaway dir. Don't do a full run.

## Adding a Windows category

1. Add an `Add-Target` call in the matching group section of `windows/Cleanup.ps1`:
   name, group, description, Measure scriptblock, Clean scriptblock.
   Optional: `-Detail` (per-item breakdown), `-Skip` (returns a reason string when the target is unavailable), `-Admin`.
2. Use the helpers: `Get-FolderSize` / `Clear-FolderContents` for folder contents, `Remove-Folders` for whole dirs.
3. Update the README.md category table.

## macOS constraints

- **Bash 3.2 compatible** (stock `/bin/bash`): no associative arrays, no `${var,,}`, no `mapfile`/`readarray`, no `&>>`. Don't rely on `set -u` with empty arrays.
- No `set -e`: clean steps swallow errors (`2>/dev/null`) so permission-denied files never abort the run.
- Steps run in `$(...)` subshells, so per-target state shared across steps (e.g. the Rust dir list) goes in a file under `$WORK`, not a variable.
- Report the free space of `/System/Volumes/Data`, not `/`. On APFS, `/` is the sealed system snapshot and shows the wrong numbers.

## Testing (macOS)

```bash
# Dry-run (safe, no deletions)
macos/cleanup.sh

# Specific categories
macos/cleanup.sh --categories rust,pip
```

Test `--execute` the same way: use a narrow `--categories` on a throwaway dir, e.g. `rust` with `--scan-roots <tmpdir>`, or `huggingface` with `HF_HOME=<tmpdir>`. Don't do a full run.

## Adding a macOS category

1. Add an `add_target <name> <group> <description> [path...]` call in the matching group section of `macos/cleanup.sh`. With paths, the target measures and clears the contents of those folders; nothing else is needed.
2. For anything else, define functions named after the target: `measure_<name>` (echo KB), `clean_<name>`, and optionally `detail_<name>` / `skip_<name>` (echo a reason when unavailable). Names must be valid function-name suffixes (lowercase, no dashes).
3. Use the helpers: `paths_kb` / `clear_contents` for folder contents, `remove_dirs` for whole dirs.
4. Update the category table in macos/README.md.
