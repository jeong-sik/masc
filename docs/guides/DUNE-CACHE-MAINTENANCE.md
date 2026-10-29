# Dune cache maintenance runbook

Why the MASC server never touches the dune cache, and what the operator
runs instead when it grows without bound.

## Why the server does not prune it

What MASC reclaims by itself shares one boundary: state under the
server's own base path (JSONL retention), or runtime objects whose owner
the server can establish. The dune cache fails both tests, so
pruning it from the server is deliberately out of scope:

- **No typed ownership.** The cache location is dune's and opam's
  decision (`~/.cache/dune` by default, overridable through dune and XDG
  configuration). A server that deleted "the cache" would be following a
  hardcoded path — the exact thing the constitution forbids
  (`forbidden#hardcoded_path`). MASC is not the only consumer of that
  directory, and this is not a single-user product.
- **No authority boundary.** The server process's filesystem authority is
  the base path. Reaching into a developer-tool cache would widen that
  silently, and doing it through yet another environment variable would
  add the sprawl the constitution calls out
  (`forbidden#env_var_sprawl`).
- **Wrong failure mode.** `dune cache trim` on a shared, cold, or
  partially-written cache can surface build failures an operator
  misreads as product bugs. A maintenance loop that can do that without
  an operator in the loop is a liability, not a feature.

Keeper dissolution removes its git worktrees through
[#42619](https://github.com/jeong-sik/masc/pull/42619). Apple microVM
volume names, however, contain the Keeper name without a workspace identity.
Automatic removal is skipped until ownership can be established; retained
volumes as well as the dune cache can consume disk space.

## The incident this addresses

2026-10 disk-pressure incident (host at 98%): the dune cache alone had
grown to **531 GB**. Volumes left by keepers dissolved before #42618
(18 volumes / 10.77 GB) were removed by hand. That historical cleanup does
not establish who owns a similarly named volume today.

Before deleting a `masc-keeper-work-<name>` or `masc-keeper-build-<name>`
volume, establish ownership across all workspaces that use that runtime,
including stopped Keepers, and preserve the volume if ownership is unclear.
A list of running guests or registered Keepers alone is insufficient.

## Operator procedure

### 1. Measure

```sh
du -sh ~/.cache/dune
```

If your dune or XDG layout differs, ask dune where it puts things:

```sh
dune cache trim --help >/dev/null   # confirms the CLI is available
echo "${XDG_CACHE_HOME:-$HOME/.cache}/dune"
```

### 2. Trim to a budget

`dune cache trim` evicts least-recently-used entries until the cache is
under the given size. Pick a budget you are willing to spend on cold
rebuilds — 50 GB is a reasonable ceiling for a machine that builds this
repo and its worktrees daily:

```sh
dune cache trim --size=50GB
```

Older dune versions that do not parse size suffixes take bytes:

```sh
dune cache trim --size=53687091200
```

To reset entirely (for example before re-measuring a leak), evict
everything:

```sh
dune cache clear
```

The next builds are cold — slower, then warm again. That cost is why
this is a scheduled budget, not a constant wipe.

### 3. Schedule it

macOS launchd, following the template style in
[`infrastructure/launchd`](../../infrastructure/launchd): a daily
`StartCalendarInterval` job that trims to the same budget.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!--
  Daily dune cache budget trim. Copy to
  ~/Library/LaunchAgents/com.<you>.dune-cache-trim.plist and replace the
  placeholders with absolute paths for your machine (launchd does not
  expand $HOME). Per-machine plists are gitignored; keep only templates
  in the repo.
-->
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.__YOU__.dune-cache-trim</string>

    <key>ProgramArguments</key>
    <array>
        <string>__OPAM_SWITCH_BIN__/dune</string>
        <string>cache</string>
        <string>trim</string>
        <string>--size=50GB</string>
    </array>

    <!-- 03:47 local: off the hour and half-hour so it does not collide
         with the repo's own 30-minute main-build observation window. -->
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>3</integer>
        <key>Minute</key>
        <integer>47</integer>
    </dict>

    <key>StandardOutPath</key>
    <string>__LOG_DIR__/dune-cache-trim.out.log</string>

    <key>StandardErrorPath</key>
    <string>__LOG_DIR__/dune-cache-trim.err.log</string>
</dict>
</plist>
```

Load and check it:

```sh
launchctl load ~/Library/LaunchAgents/com.<you>.dune-cache-trim.plist
launchctl list | grep dune-cache-trim
du -sh ~/.cache/dune   # after the first fire, well under the budget
```

`__OPAM_SWITCH_BIN__` is the `bin/` of the opam switch that owns the
builds whose cache you are trimming, e.g.
`/Users/<you>/.opam/5.5.1/bin`. Launch agents run with a minimal
environment, so spell the absolute path rather than relying on PATH.

On Linux, the equivalent is one line in the operator's crontab:

```cron
47 3 * * * /home/<you>/.opam/5.5.1/bin/dune cache trim --size=50GB >> /var/log/dune-cache-trim.log 2>&1
```

## Verify the budget holds

After a week, measure again:

```sh
du -sh ~/.cache/dune
```

The value should sit just under the budget. If it climbs back over
between trims, either lower the budget or shorten the interval — do not
reach for `dune cache clear` on a schedule; evicting a warm cache every
night costs more rebuild time than it buys disk.
