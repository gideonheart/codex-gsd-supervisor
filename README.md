# codex-gsd-supervisor

Autonomous GSD supervisor stack for Codex TUI.

This project is standalone and can supervise any target project that has GSD planning files (`.planning/...`).

## Features

- Drives Codex TUI prompts and routes `$gsd-*` commands automatically
- Enforces `/clear` before dispatched `$gsd-*` commands
- Recovers from dead/missing watcher sessions
- Optional meta-supervisor loop with fresh-context analysis
- systemd user service installers for unattended operation

## Requirements

- `tmux`
- `codex` CLI
- Optional: `systemctl --user` for persistent services

## Quick Start

1. Start worker Codex session in your target project:

```bash
scripts/codex-tmux.sh -r /path/to/project -s codex-new -w codex
```

2. Prime worker behavior (optional but recommended):

```bash
scripts/tmux-prime-codex-worker.sh -t codex-new:codex
```

3. Start main supervisor daemon:

```bash
scripts/start-gsd-supervisor-daemon.sh -t codex-new:codex -r /path/to/project
```

4. Start meta-supervisor:

```bash
scripts/start-gsd-meta-supervisor.sh -t codex-new:codex -r /path/to/project
```

## Persistent Services

```bash
scripts/install-gsd-supervisor-service.sh -t codex-new:codex -r /path/to/project
scripts/install-gsd-meta-supervisor-service.sh -t codex-new:codex -r /path/to/project
```

## Docs

- [operations.md](docs/operations.md)
