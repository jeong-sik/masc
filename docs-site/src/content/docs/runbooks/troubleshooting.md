---
title: Troubleshooting
description: Common first-run and runtime problems, and how to resolve them.
---

## `masc: command not found`

The binaries install to `~/.local/bin`, which is often not on a fresh machine's
`PATH`. Add it to your shell's startup file and reload:

```bash
# zsh (macOS default)
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
# bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc && source ~/.bashrc
```

See the [Quickstart](/getting-started/quickstart/) PATH step for details.

## The server exits at startup instead of staying in the foreground

The server prints why before it exits — read the last lines it wrote. A common
cause is a `runtime.toml` whose `[runtime].default` points at a `<provider>.<model>`
pair that is not fully defined (missing binding, or a dispatch limit the binding
does not declare). Fix the pair in `<base-path>/.masc/config/runtime.toml`, or
re-run the installer's wizard to pick a source that is ready. The
[Configuration Reference](/reference/config/) shows the required shape.

## Port 8935 is already in use

Another instance (or another program) holds the default port. Find and stop it:

```bash
lsof -i :8935
kill <PID>
```

Or start on a different port and point the TUI at the same one. The server's
default port comes from `MASC_HTTP_PORT`, or pass `masc --port` on the
command line:

```bash
masc --base-path ~/masc --port 8936
masc-tui --base-path ~/masc --port 8936
```

## `masc-tui` shows no Keepers or the wrong workspace

`masc-tui` reads the workspace from `--base-path` (default: `MASC_BASE_PATH`, or
the current directory). A second terminal starts in your home directory, so pass
the same base path you started the server with: `masc-tui --base-path ~/masc`.

## A Keeper will not start

A Keeper needs a command sandbox; MASC refuses to run one without an accepted
`sandbox_profile`. Install Docker, or on Apple Silicon the `container` CLI, then
set the profile — see [Keeper Sandbox](/runbooks/sandbox/). A Keeper whose work is
web search or `git push` also needs `network_mode = "inherit"`; the default,
`none`, gives the guest no network.

## Provider rate limits

If a provider returns a rate-limit error, MASC can fail over to other bindings
listed for that role, so the active Keeper turn is not dropped. Configure the
alternates as additional slots in the relevant lane (see the
[Configuration Reference](/reference/config/)).

## TUI shows "reconnecting..." or high server latency

If the TUI shows recurring `reconnecting...` banners or response times spike, the
Eio main domain event loop may be experiencing scheduler delays:

1. Inspect the server health payload:
   ```bash
   curl -s http://127.0.0.1:8935/health | jq '{scheduler: .scheduler, gc: .gc}'
   ```
   Check `.scheduler.stalls` (count of stalls >= 1s) and the percentiles
   (`p50_ms`, `p95_ms`, `p99_ms`, `max_ms`). These are the last minute's ring
   measurements; elevated values mean the main domain could not run a ready
   fiber on time (a fiber computing without yielding, a stop-the-world GC
   section, a blocking call on the scheduler thread).

2. Run the real-time scheduler lag probe:
   ```bash
   MASC_URL=http://127.0.0.1:8935 scripts/harness/perf/scheduler_lag_probe.sh
   ```
   This polls the lag ring alongside cumulative `Gc.quick_stat` metrics to measure
   allocation rates (MB/s) and collection cycles without walking the live heap.

## Diagnosing heap bloat (`heap-roots`)

When the server process footprint grows unexpectedly:

```bash
curl -s http://127.0.0.1:8935/api/v1/diagnostics/heap-roots | jq .
```

This diagnostic endpoint inventories live heap roots, identifying which modules,
event queues, or in-memory caches retain heap allocations.

