# Actual installed Codex startup observations

Installed `codex-cli 0.162.1` was invoked directly for two bounded probes.
Both children terminated with exit code 1. Neither produced any JSON event.
This is failed startup evidence, not a successful model turn or streaming test.

## Ephemeral read-only exec

The fixture was a temporary directory containing only `probe.txt` with
`MASC synthetic streaming fixture: blue triangle`.

```sh
codex exec --json --ephemeral --ignore-user-config --skip-git-repo-check \
  -s read-only -C "$fixture_dir" -c 'approval_policy="never"' \
  'Read only probe.txt with one shell command. Do not inspect other files or contact services. Then reply exactly: blue triangle. This is a synthetic runtime event probe.'
```

Stdout was empty. Stderr ended with:

```text
Error: failed to initialize in-process app-server client: Operation not permitted (os error 1)
```

No final answer, tool event or reasoning event was observed. No request to bypass
the sandbox or elevate permissions was made. The initial PATH alias warning
also reported an operation permission failure.

## App-server stdio

`codex app-server --stdio` was started with pipes. The probe wrote this request:

```json
{"id":1,"method":"initialize","params":{"clientInfo":{"name":"masc-synthetic-probe","version":"0.1"},"capabilities":{"experimentalApi":true}}}
```

The child exited 1 without any JSON response. Stderr ended with:

```text
Error: Operation not permitted (os error 1)
```

The probe would send `initialized` and `permissionProfile/list` only after
response id 1. Neither later message was sent. No thread or model turn was
started. User configuration warnings were present on this path; the exec probe
above ignored user configuration and still failed. This does not identify which
initialization operation was denied or prove both failures have the same cause.

## Evidence boundary

These were real installed CLI processes, not fake process fixtures. They do not
exercise MASC's OCaml adapter, TUI, model streaming, tools, exposed reasoning,
provider delivery, account health, or successful IPC. Empty stdout does not
indicate a renderer defect: startup failed before any provider event was observed.
Private configuration and account contents are not included. Raw files remain
in temporary local probe directories. No full build, CI, approval, merge or
installation of the accumulated changes is established by these observations.
