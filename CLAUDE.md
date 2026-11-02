# CLAUDE.md -- disk-cleanup

## Project purpose

Disk cleanup tools for Windows, macOS, and Linux, one script per platform. Every tool is dry-run by default and supports category filtering.

## Structure

```
disk-cleanup/
  windows/
    Cleanup.ps1    # Windows tool (PowerShell)
  macos/           # planned (POSIX shell)
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
