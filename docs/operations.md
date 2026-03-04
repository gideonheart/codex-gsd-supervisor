# codex-gsd-supervisor Operations

`codex-gsd-supervisor` runs three cooperative roles:

- Worker Codex TUI (your project session, for example `codex-new:codex`)
- Main supervisor (`gsd-supervisor`) that drives prompts and dispatches `$gsd-*`
- Meta supervisor (`gsd-meta-supervisor`) that does fresh-context analysis and enqueues high-leverage `$gsd-*` follow-ups

All runtime artifacts live in the target project:

- `.planning/supervisor/autoresponder.log`
- `.planning/supervisor/daemon.log`
- `.planning/supervisor/meta-supervisor.log`
- `.planning/supervisor/meta-daemon.log`
- `.planning/supervisor/queue.txt`

## Start (tmux only)

```bash
# default: Codex UI pair (recommended for visible Codex sessions)
scripts/codex-duet-link.sh -r /path/to/project start
# alternate executor loop (no Codex TUI)
scripts/codex-duet-link.sh -r /path/to/project start --agent
scripts/codex-duet-link.sh -r /path/to/project start --fresh
scripts/start-gsd-supervisor-daemon.sh -t codex-new:codex -r /path/to/project
scripts/start-gsd-meta-supervisor.sh -t codex-new:codex -r /path/to/project
```

Attach the two Codex roles:

```bash
tmux attach -t codex-new-developer
tmux attach -t codex-new-driver
```

Clean known legacy sessions for this project if you only want the two pair roles:

```bash
tmux kill-session -t codex-$(basename /path/to/project)-controller 2>/dev/null || true
tmux kill-session -t codex-$(basename /path/to/project)-worker 2>/dev/null || true
```

## Start (systemd user services)

```bash
scripts/install-gsd-supervisor-service.sh -t codex-new:codex -r /path/to/project
scripts/install-gsd-meta-supervisor-service.sh -t codex-new:codex -r /path/to/project
```

## Monitor

```bash
tmux attach -t codex-new
tmux attach -t gsd-supervisor
tmux attach -t gsd-meta-supervisor

journalctl --user -u gsd-supervisor-watchdog.service -f
journalctl --user -u gsd-meta-supervisor.service -f
```

## Queue Commands Manually

```bash
scripts/supervisor-queue.sh -r /path/to/project append '$gsd-plan-phase 5 --gaps'
scripts/supervisor-queue.sh -r /path/to/project show
```

## Pause/Resume Automation

Automation pauses only when `.planning/supervisor/disabled` contains an explicit non-comment value:

- `1`
- `true`
- `on`
- `pause`

To resume automation, empty the file or remove these values.
