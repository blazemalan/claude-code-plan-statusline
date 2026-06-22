# CLAUDE.md — project memory for claude-code-plan-statusline

Claude Code statusline showing plan rate-limit usage. Two implementations, one behavior:
`statusline.sh` (bash) and `statusline.ps1` (PowerShell) must produce **byte-identical
output** for the same stdin JSON. That parity is the project's core promise and is
enforced by CI.

## Invariants — never violate

- **No network calls, no auth.** The script only reads the JSON piped to stdin.
- **Minimal deps.** bash version needs only `jq`; PowerShell version needs ZERO installs
  (Windows PowerShell 5.1 built-ins only — no ternary, no `??`, no `-AsHashtable`).
- **Single-file scripts**, copy-paste installable. No modules, no helper files.
- **statusline.sh stays bash 3.2 compatible** (macOS system bash).
- **Byte parity:** any behavior change to one script MUST be mirrored in the other, and
  `tests/crosscheck.sh` must pass. If you touch rendering, run the cross-check.
- Failure paths never write stderr and always exit 0 (a broken statusline must not break
  Claude Code's statusline pipeline).

## Tests (no frameworks; all must pass)

```bash
bash tests/unit.sh          # sourceable helpers
bash tests/dispatch.sh      # theme dispatch + render faithfulness
bash tests/enterprise.sh    # Enterprise fallback + mode exclusivity
bash tests/robustness.sh    # malformed/partial stdin, config quirks, PLAN_SL_NOW hook
pwsh tests/ps-tests.ps1     # PowerShell port (also runs under powershell 5.1)
bash tests/crosscheck.sh    # bash vs PowerShell byte-for-byte diff (needs pwsh + jq)
```

CI (`.github/workflows/test.yml`) runs all of this on ubuntu/macos/windows, including
ps-tests under real Windows PowerShell 5.1 and a BOM guard.

## Hard-won gotchas (each of these caused a real bug)

1. **Line endings:** `*.sh` must stay LF — CRLF checkouts broke bash with
   `\r: command not found`. Enforced by `.gitattributes` (`*.sh text eol=lf`,
   `*.ps1 text eol=crlf`). Don't fight it.
2. **statusline.ps1 must keep its UTF-8 BOM.** Without it, Windows PowerShell 5.1 reads
   the source as ANSI and garbles ● ◕ ◑ ◔ ○ │ ↑ ↓. CI checks the BOM bytes.
3. **PS 5.1 default encodings are landmines.** `Get-Content` without `-Encoding UTF8`
   reads UTF-8 files as the legacy codepage (this broke the test harness on Windows
   while passing everywhere else). Any PS code that reads the script's output must pass
   `-Encoding UTF8` explicitly; the script itself sets `[Console]::OutputEncoding` to
   BOM-less UTF-8 before writing.
4. **jq field join uses `\x1f` (unit separator), NOT @tsv** — tab is IFS whitespace, so
   bash `read` collapses empty fields and shifts everything left.
5. **`PLAN_SL_NOW` env var** pins "now" in both scripts (100% easter-egg flash + the
   week-reset today-vs-weekday check). It exists so tests and the cross-check are
   deterministic. Keep it working in both implementations.
6. **Locale:** `fmt_cost` pins `LC_ALL=C` *function-scoped* (an inline prefix on
   `printf` does NOT work on bash 3.2). Cross-check runs under `LC_ALL=C`.
7. **shellcheck** must pass per-file at `-S warning` (CI invokes it per-file because
   shellcheck 0.11 crashes when fed some of these files together).

## Adding a theme

Add `theme_<name>()` in BOTH scripts (same variables, same SGR strings), add the name to
the `case` dispatch in both, add it to `THEMES` in `tests/dispatch.sh` and the theme loop
in `tests/ps-tests.ps1`/`tests/crosscheck.sh`, then run the full suite. Every theme needs
the egg variables (EGG_MSG_A/B, EGG_COLOR_A/B, EGG_RESET_WORD) — the 100% state is part
of the theme contract.

## Output contract quick-reference

- Percentages truncate at the last `.` (bash `${pct%.*}`); `42.9` renders `42%`. A JSON
  `0` is present (renders `0%`); only absent/`null` fields are skipped.
- Plan mode (rate_limits present) and Enterprise dashboard (absent) are mutually
  exclusive; context segment renders in both.
- Malformed/empty stdin → `Claude │ usage data pending - make a request`, exit 0, silent
  stderr.
- One line, no trailing newline, UTF-8 (no BOM) bytes on stdout.
- `NO_COLOR` (any non-empty value) suppresses ALL ANSI in both scripts — glyphs
  and layout unchanged, just no color/style. Honored at every SGR emission point
  (paint, render_name, egg glyph, the missing-jq error). Part of the parity contract.
