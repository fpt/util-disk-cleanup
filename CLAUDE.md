# CLAUDE.md -- win-cleanup

## Project purpose

Disk cleanup tool for Windows. Single PowerShell script with dry-run and category filtering.

## Structure

```
win-cleanup/
  windows/
    Cleanup.ps1    # main tool
  README.md
  CLAUDE.md
```

## Key constraints

- **PowerShell 5.1 compatible**: no ternary operator, no `&&`/`||` pipeline chains, no `switch` as rvalue expression.
- **ASCII-only string literals**: the script file is read by PowerShell as Windows-1252 if no UTF-8 BOM is present. Multi-byte UTF-8 sequences (box-drawing chars, etc.) corrupt string literals because byte 0x94 is `"` in Windows-1252. Keep all string content ASCII.
- **No admin assumption**: user-space paths work without elevation; system paths (C:\Windows\Temp) silently skip files they can't delete.

## Testing

```powershell
# Dry-run (safe, no deletions)
powershell -ExecutionPolicy Bypass -File windows/Cleanup.ps1

# Specific categories
powershell -ExecutionPolicy Bypass -File windows/Cleanup.ps1 -Categories rust,pip
```

## Adding a new category

1. Add the name to `$allCats` array.
2. Add an `if (Should-Run "name") { ... }` block in the appropriate section.
3. Call `Remove-DirContents` or `Remove-PatternDirs` with `(-not $Execute)` as the bool arg.
4. Push a hashtable to `$results` with `Category` and `Freed` keys.
5. Update README.md category table.
