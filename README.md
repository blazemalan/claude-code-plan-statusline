# claude-code-plan-statusline

A tiny [Claude Code](https://www.anthropic.com/claude-code) statusline that keeps your **actual plan rate-limit usage** at the bottom of the terminal — the same numbers `/usage` reports, without typing `/usage`. No network calls, no auth, no dollar-cost guesswork.

![statusline screenshot](screenshot.png)

- **Real plan usage, not dollar cost** — your 5-hour and weekly rate-limit windows and when they reset, read straight from Claude Code's own data.
- **Pro, Max, and Enterprise** — auto-detects your plan: rate-limit windows on Pro/Max, a session dashboard (cost · duration · tokens) on managed/Enterprise plans that have no windows.
- **Per-chat context gauge** — how full the current conversation's context window is, at a glance.
- **Four built-in themes** — switch instantly with no restart, or ask Claude Code to invent a new one.
- **No network, no auth** — reads only the JSON Claude Code already pipes in; never touches your credentials.
- **Portable** — macOS, Linux, and WSL; Bash 3.2+; one dependency (`jq`).

## Why plan usage, not dollar cost

Most Claude Code statusline plugins show **API-equivalent dollar cost** — your token counts multiplied by Anthropic's pay-per-use API rates. That's useful if you pay for the API, but on Pro or Max it's beside the point: the limit that actually bites is your plan's **rate-limit window**, not a dollar figure.

This statusline shows the window instead — how much of your rolling allowances you've spent and when they reset. It reads that straight from the JSON Claude Code already hands the statusline command, so unlike tools that poll an Anthropic OAuth endpoint with your stored credentials, it makes **no network calls and never reads your auth token**.

## What it shows

Reading the Pro/Max line left to right:

- **Model name** — whatever Claude Code is calling the active model (e.g. `Opus 4.8 (1M context)`), in the active theme's color.
- **`5h: 14% (→11:00am)`** — your 5-hour rolling plan window and when it resets (local time).
- **`week: 47% (→thu)`** — your 7-day rolling window. It shows a clock time when the reset is today and the lowercase weekday otherwise, so you can tell at a glance whether the limit comes back today or in a few days.
- **`○ 6% of 1M`** — context-window fill for *the current chat*. This is **not** a plan limit — it's how much of the model's working memory the conversation has consumed (6% of 1,000,000 tokens here). It only grows as the chat gets longer; starting a new chat clears it. The circle (`○ ◔ ◑ ◕ ●`) is a five-step visual of the same percentage.

All three percentages share one color scale: green → yellow → orange → red as they climb.

On Enterprise/managed plans the layout adapts automatically — see [Enterprise / managed plans](#enterprise--managed-plans).

## Install

### Let Claude Code install it (easiest)

Open any Claude Code session and paste:

> Please install the plan-statusline from https://github.com/blazemalan/claude-code-plan-statusline for me:
> 1. Download https://raw.githubusercontent.com/blazemalan/claude-code-plan-statusline/main/statusline.sh to `~/.claude/hooks/plan-statusline.sh` and make it executable.
> 2. Add a `statusLine` entry to `~/.claude/settings.json` that runs `bash ~/.claude/hooks/plan-statusline.sh`, preserving all existing keys.
> 3. Make sure `jq` is installed (`brew install jq` if not).

Claude Code does the file work and the settings edit, asking permission as it goes.

### Manual install

```bash
mkdir -p ~/.claude/hooks
curl -fsSL https://raw.githubusercontent.com/blazemalan/claude-code-plan-statusline/main/statusline.sh \
  -o ~/.claude/hooks/plan-statusline.sh
chmod +x ~/.claude/hooks/plan-statusline.sh
```

Then merge this into `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/hooks/plan-statusline.sh"
  }
}
```

Start a new Claude Code session and make a request — the statusline appears at the next refresh.

## Themes

Four themes ship in the box. Select one by creating `~/.claude/plan-statusline.conf`:

```
theme=hearth
```

No restart needed — the statusline re-reads the config on every refresh, so a new theme shows up within a few seconds.

| Theme     | Look                                                                                                                |
|-----------|---------------------------------------------------------------------------------------------------------------------|
| `default` | Basic ANSI colors, pipe separators, single context circle. Bold model name.                                         |
| `hearth`  | Warm amber, restrained. Bold-amber name; tier color stays silent until 70% (orange) / 90% (red); dim italic reset times. |
| `glow`    | Pink neon arcade. Bold-magenta name; mint→pink→magenta→red tier ramp; italic rose reset times.                      |
| `scrubs`  | Clinical teal vitals monitor. Bold bright-teal name; teal→bright→amber→red ramp; soft light-teal reset times.       |

The model name renders in each theme's solid color (at 100% plan usage it dims, part of the per-theme easter egg). If the config file is missing or names an unknown theme, the statusline falls back to `default`.

### Ask Claude Code to theme it

Once installed, you can change the look in plain English instead of editing files:

- *"switch my statusline to glow"* / *"go back to the default theme"*
- *"make me a new statusline theme — ocean blues, calm"*

Claude Code edits `~/.claude/plan-statusline.conf` (or adds a new render function to the script); the change appears within a few seconds, no restart required.

## Enterprise / managed plans

Managed and Enterprise deployments don't receive a `rate_limits` block — there are no rolling plan windows to show. Rather than render blank, the statusline detects this and falls back to a **session dashboard** built from the data those payloads do carry:

```
Opus 4.8 (1M context) │ $1.01 │ 2m16s │ +1/-0 │ 63k↑ 248↓ │ ○ 6% of 1M
```

Left to right: **session cost** (API-equivalent USD), **wall-clock duration**, **lines changed**, **tokens in ↑ / out ↓**, and the same context circle. Cost carries the green→red scale (green `<$2`, yellow `≥$2`, orange `≥$5`, red `≥$10` — tunable in `cost_tier_color`); the rest render dimmed. Detection is automatic and needs no config: rate limits present → the `5h`/`week` view; absent → the dashboard. One script serves both.

## How it works

Since Claude Code v2.1.80, the statusline command receives a JSON blob on stdin with the same data `/usage` shows, plus per-chat context stats:

```json
{
  "model": { "display_name": "Opus 4.8" },
  "rate_limits": {
    "five_hour": { "used_percentage": 83, "resets_at": 1746234000 },
    "seven_day": { "used_percentage": 52, "resets_at": 1746500400 }
  },
  "context_window": {
    "used_percentage": 6,
    "context_window_size": 1000000
  }
}
```

The script parses it with `jq`, picks the percentages and reset epochs, color-formats them, and prints. No network, no auth. One data-driven renderer feeds every theme.

The `rate_limits` field appears only for Pro/Max subscribers, and only after the first API response in a session — until then the statusline shows `usage data pending - make a request`. (Enterprise/managed plans never send it; see [above](#enterprise--managed-plans).)

## Requirements

- macOS, Linux, or WSL (handles both BSD `date -r` and GNU `date -d @`)
- Claude Code v2.1.80 or later
- `jq` (preinstalled on macOS; `brew install jq` otherwise)
- Bash 3.2+

## Development

The renderer is data-driven: each theme is just a set of variables consumed by a single `render_line`. The tests are plain Bash and need no framework:

```bash
bash tests/unit.sh        # sourceable helpers (formatting, circles, name rendering)
bash tests/dispatch.sh    # theme dispatch + render faithfulness across themes
bash tests/enterprise.sh  # Enterprise fallback + plan/enterprise mode exclusivity
```

## License

MIT
