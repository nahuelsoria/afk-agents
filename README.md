# afk

Scaffold and manage unattended AFK agents from the command line: uptime monitors, LLM error triage, weekly digests. All cron + bash + Telegram + the Claude CLI. Zero dependencies, and the agents it generates are plain bash with no runtime dependencies of their own.

This is the authoring tool for the [AFK Agents Kit](https://misekit.gumroad.com/l/afk-agents-kit) patterns: instead of copying a template folder and wiring cron by hand, you run one command.

## Install

```bash
npm install -g afk-agents
```

Requires Node 18+ (to run the CLI) and, on the target box, bash, cron and curl. The Claude CLI is optional and only needed for the `worker` and `digest` agent types.

## Quickstart

```bash
afk init                                   # set up ~/agents with shared helpers + env.sh
# edit ~/agents/shared/env.sh: add your Telegram token and chat id
afk new monitor disk-watch --every 30m     # an alert-only check, every 30 minutes
afk new digest weekly --day sun --at 19:00 # a weekly LLM digest, Sundays at 19:00
afk list                                   # see everything and when it runs
```

```
$ afk new monitor disk-watch --every 30m
afk: created monitor "disk-watch"
  /home/you/agents/disk-watch/run.sh
  scheduled: */30 * * * *
  edit the CHECK block, then 'afk run disk-watch' to test

$ afk list
disk-watch  */30 * * * *  [08:00:12] ok (41%)
weekly      0 19 * * 0    (no runs yet)
```

## Commands

| Command | What it does |
|---|---|
| `afk init` | Create `AGENTS_HOME` with the shared notifier, logger and `env.sh` (never overwrites an existing `env.sh`) |
| `afk new <type> <name> [schedule]` | Create an agent. Types: `monitor`, `worker`, `digest` |
| `afk list` | Show every agent, its cron schedule and its last log line |
| `afk run <name>` | Run an agent once, right now (for testing) |
| `afk logs <name>` | Print today's log for an agent |
| `afk rm <name>` | Delete an agent's files and its cron line |

### Scheduling flags for `new`

| Flag | Result |
|---|---|
| `--every 30m` | `*/30 * * * *` |
| `--every 2h` | `0 */2 * * *` |
| `--at 09:00` | `0 9 * * *` (daily) |
| `--day sun --at 19:00` | `0 19 * * 0` (weekly) |
| `--schedule "0 2 * * *"` | used verbatim (raw 5-field cron) |

Omit them and the agent is created but not scheduled; add a schedule later by editing your crontab, or re-create it.

## The three agent types

- **monitor**: an alert-only check. Silence means OK; it messages you only when something is wrong, and it dedups so a persistent failure does not page you every run.
- **worker**: a queue worker that runs Claude headless with hard guardrails (read-only tools, a daily spend cap, a lock, a timeout). Drop `.job` files in its `queue/` dir.
- **digest**: a scheduled LLM summary that archives everything it generates to disk before sending it.

## How it works

- Agents live in `AGENTS_HOME` (default `~/agents`), one folder each, sharing the helpers in `shared/`.
- Scheduling edits your user crontab, tagging each line with `# afk:<name>` so `afk` can find, replace and remove it without touching your other cron jobs.
- Nothing runs as a daemon. Cron is the scheduler, Telegram is the surface.

## Configuration

- `AGENTS_HOME`: where agents live (default `~/agents`).
- `AFK_CRONTAB_CMD`: the crontab binary to use (default `crontab`); handy for testing.

## License

MIT
