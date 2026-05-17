# launchd integration — RFC-0101 §2

This directory holds the macOS `launchd` integration for masc-mcp. It is
**opt-in**: the rest of the codebase keeps working without it (the existing
`scripts/start-masc-supervised.sh` continues to be the script-based path).

The plist exists only to satisfy RFC-0101 §2 — raise per-process
`NumberOfFiles` before `bin/main_eio.exe` starts so that
`Fd_accountant.fd_snapshot` (RFC-0101 §3.5) reports the raised cap.

## Files

| File | Purpose |
|------|---------|
| `com.masc.mcp.plist` | launchd job definition. Sets `SoftResourceLimits.NumberOfFiles=10240`, runs `masc-mcp-start.sh`. |
| `masc-mcp-start.sh` | Entry script. Defines `sb_raise_nofile_limit` (RFC-0101 §2), execs `bin/main_eio.exe`. |

## Editing for your machine

The plist hardcodes `/Users/USERNAME/...` placeholders. Before installing,
replace `USERNAME` with your actual macOS short username in
`com.masc.mcp.plist` (5 occurrences). Example:

```bash
USER_SHORT="$(id -un)"
sed -i '' "s|/Users/USERNAME|/Users/${USER_SHORT}|g" launchd/com.masc.mcp.plist
```

If your masc-mcp checkout lives somewhere other than
`~/me/workspace/yousleepwhen/masc-mcp`, also edit `WorkingDirectory`,
`ProgramArguments`, `StandardOutPath`, `StandardErrorPath`, and
`EnvironmentVariables.MASC_BASE_PATH`.

## Install

```bash
launchctl bootstrap gui/$(id -u) launchd/com.masc.mcp.plist
```

## Verify

```bash
# Job loaded and running.
launchctl print gui/$(id -u)/com.masc.mcp | head -20

# Check the resource-limit block specifically.
launchctl print gui/$(id -u)/com.masc.mcp | grep -i -E '(state|limits|files)'

# Inside the running process: should print 10240.
# (Find PID via `pgrep -f main_eio.exe` then `cat /proc/<pid>/limits` —
# on macOS, easiest cross-check is to grep the startup log:)
grep 'rlimit_nofile' logs/masc-mcp.out logs/masc-mcp.err 2>/dev/null | head -5

# Or in a manual smoke test from a shell:
./launchd/masc-mcp-start.sh --version  # observe `sb_raise_nofile_limit: raised ...` on stderr
```

Expected log line (RFC-0101 §3.5):

```
fd-accountant: rlimit_nofile soft=10240 hard=10240 (launchd raise: success)
```

(The `Fd_accountant.fd_snapshot` startup log is a future PR-5 deliverable in
RFC-0101 §4 migration plan; today the `sb_raise_nofile_limit` stderr log is
what you can grep.)

## Remove

```bash
launchctl bootout gui/$(id -u)/com.masc.mcp
```

## Open questions

1. **Hard cap value.** RFC-0101 §3.5 expects `hard=10240`. macOS allows
   raising the hard cap up to `kern.maxfilesperproc` (default ≈491520
   on M-series, 24576 on older Intel). The plist currently uses
   `HardResourceLimits.NumberOfFiles=10240` to match the RFC. Whether to
   bump to a higher hard cap (e.g. 65536) is **deferred** — the RFC has
   not specified the upper bound, and going above 10240 invites cross-
   class headroom estimation that RFC-0101 §3.2 has not yet sized.
2. **CLAUDE.md `<launchd>` default.** The Second Brain CLAUDE.md says
   "사용자 명시 요청이 없으면 launchd를 먼저 추천하지 않는다." This
   directory is opt-in and the existing script-based supervisor
   (`scripts/start-masc-supervised.sh`) remains the default operational
   path. Use this plist only when you explicitly want the
   nofile-raised, system-supervised variant.
3. **`KeepAlive=true` with crash-loop.** The plist's `KeepAlive=true`
   has no crash-loop circuit breaker, unlike
   `scripts/start-masc-supervised.sh` which has a sliding-window
   restart cap. If you mix launchd KeepAlive with a crash-loop bug,
   you'll see infinite respawns. Consider wrapping the
   `ProgramArguments` to call `scripts/start-masc-supervised.sh`
   instead of `bin/main_eio.exe` if you want both behaviors.

## Reference

- `docs/rfc/RFC-0101-fd-accountant-generic-pool.md` §2 (out-of-scope clause naming this script)
- `docs/rfc/RFC-0101-fd-accountant-generic-pool.md` §3.5 (startup nofile-limit log shape)
- Apple `launchd.plist(5)` man page for resource-limit semantics
