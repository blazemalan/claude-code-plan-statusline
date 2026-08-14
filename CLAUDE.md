# CLAUDE.md — project memory for claude-code-plan-statusline

Claude Code statusline showing plan rate-limit usage. Two implementations, one behavior:
`statusline.sh` (bash) and `statusline.ps1` (PowerShell) must produce **byte-identical
output** for the same stdin JSON. That parity is the project's core promise and is
enforced by CI.

## Invariants — never violate

- **No network calls, no auth, no credential access.** This is the invariant that
  actually protects users, and it is absolute.
- **Stdin is the only data source — with exactly one opt-in exception.** The
  `model_weekly` segment reads `~/.claude.json` because Claude Code does not put
  per-model weekly windows on stdin (gotcha 9). It is OFF by default, so the
  copy-paste default stays literally stdin-only. Do not add a second exception
  without the same bar: off by default, silent on every failure, documented here
  and in the README, and a stated migration back to stdin.
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
bash tests/robustness.sh    # malformed/partial stdin, config quirks, PLAN_SL_NOW hook,
                            # model_weekly gating + every failure path + hostile fields
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
8. **Cache TTL is NOT a flat 5 minutes.** A cache-freshness countdown (`↯cached`/`↯cold`,
   PR #26) shipped on that assumption and was reverted: Claude Code on a Pro/Max
   subscription uses a **1-hour** prompt-cache TTL for the *main* conversation. 5 minutes
   applies only to API-key/Bedrock/Vertex/Foundry billing, to subagents, and when over
   the plan limit (drawing on billed credits). See `code.claude.com/docs/en/prompt-caching`
   (and Claude Code issue #46829 — the TTL has regressed before). Don't re-add a
   cache-lifetime indicator without deriving the right TTL from stdin or making it configurable.

9. **Per-model weekly windows are NOT on statusline stdin.** `/usage` shows
   "Current week (Fable)" and it is often the binding limit (21% scoped vs 13%
   all-models), but the statusline payload builder in Claude Code v2.1.231 copies
   only `five_hour` and `seven_day`. Verified two ways, and re-verify both before
   trusting any claim otherwise: (a) `strings` the `claude` binary — the builder
   reads `{...C.five_hour && {five_hour:...}, ...C.seven_day && {...}}` and the
   richer `model_scoped` array exists only on the SDK/`get_usage` path; (b) tee
   the live statusline's stdin to a file and look. The data lives in
   `~/.claude.json` → `cachedUsageUtilization.utilization.limits[]` where
   `kind == "weekly_scoped"`, with `scope.model.display_name`, `percent` (already
   0–100), and an **ISO-8601** `resets_at`. Note that file lags stdin (observed
   9% vs 11% on the 5h window) — render the number, never a freshness countdown
   (see gotcha 8). `seven_day_opus`/`seven_day_sonnet` in that file are null dead
   ends; read `limits[]`.
10. **`resets_at` on scoped windows is an ISO string, not an epoch** — the only
   such timestamp in the codebase. `iso_to_epoch`/`Iso-ToEpoch` do the civil-date
   math inline rather than calling `date`, because BSD date rejects the
   fractional seconds and offset colon GNU accepts. Mirror any change in both.
   **PowerShell 7's `ConvertFrom-Json` silently rehydrates ISO strings into local
   `[datetime]` objects; PS 5.1 leaves them strings.** Left alone, PS 7 fed the
   parser `08/15/2026 20:00:00`, the reset clause emptied, and only the parity
   cross-check caught it. `Load-ScopedWeekly` re-canonicalises to UTC ISO.
11. **Strip control characters from scoped fields BEFORE joining them.** Gotcha 4
   says the jq join uses `\x1f` because tab collapses; the sequel is that the
   *values* are server-supplied and can contain `\x1f`/`\x1e` themselves. A
   `display_name` carrying them made bash forge extra windows at attacker-chosen
   percentages — an injected `100%` even fired the pegged easter egg and dimmed
   the model name — while PowerShell, which keeps a real array and never
   re-splits, rendered one correct window. Content injection and a parity break
   in one bug. Fixed with `gsub("[[:cntrl:]]";"")` in the jq filter and
   `Strip-Controls` in the PS loader; `tests/scoped-injection.json` is the
   regression. Sanitising only the *label* is not enough — the split happens
   first. Any future field read from that file needs the same treatment.
12. **The config reader must accept a file with no trailing newline.** `while
   read` returns non-zero at EOF, so bash silently dropped the last line while
   PowerShell's `Get-Content` kept it — `theme=` on the last line rendered
   differently on macOS and Windows. Fixed with `|| [[ -n "$key" ]]`; keep it.
13. **Four PowerShell-vs-jq traps, all found by differential testing.** Any new
   field read from JSON needs all four checked:
   - **`-eq`/`-ne` are case-INSENSITIVE in PowerShell.** jq's `==` and bash's
     `case` are not. `kind: "WEEKLY_SCOPED"` and a `MODEL_WEEKLY=on` config key
     both worked on Windows only. Use `-ceq`/`-cne` for anything bash compares
     literally.
   - **`\d` in .NET matches every Unicode decimal digit**, bash's `[0-9]` does
     not. An Arabic-Indic year matched `Iso-ToEpoch`'s regex and then *threw on
     the cast, onto stderr* — which this script must never write to. Use `[0-9]`.
   - **Blind `.ToString()` diverges from jq's `tostring`.** jq keeps the JSON
     literal (`1e2` → `"1E+2"`) where .NET normalises (`"100"`); jq's `//`
     treats `false` as absent where a `$null` check does not; nested objects
     stringify differently again. Type-pin every field (string stays string,
     number gets `+ 0` so jq re-renders it .NET's way), then validate.
   - **A `catch` around the record loop loses every record**, where bash drops
     only the bad one. Guard per record.
   `tests/robustness.sh`'s `mw_field` cases pin all of these; the scratch
   differential harness that found them compared both implementations across ~29
   hostile shapes for parity, stderr silence, control bytes, and line length.
   Rebuild something like it before trusting a change to this loader.

## Test fixtures

`tests/fixtures/*.json` are **stdin** payloads — the cross-check globs the whole
directory, so nothing else may live there. The two `~/.claude.json` stand-ins for
`model_weekly` sit in `tests/` instead:

- `tests/scoped-claude-config.json` — the happy path plus edge cases in one file
  (a normal bucket, an ANSI-injecting + overlong label, a fractional percent with
  a null reset, and a fourth bucket the 3-record cap must drop).
- `tests/scoped-injection.json` — the gotcha-11 regression: `display_name`
  carrying the `\x1f`/`\x1e` delimiters bash re-splits on.

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
