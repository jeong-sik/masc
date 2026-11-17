# A person's sign-in and the browser of the server machine

Date: 2026-11-17. Measurements of the official clients, and source checks of
the candidate. No account server ran for this record.

- Base: `d774939f03a5777f28c5ca8b3e1e01acdbe54cca`.
- Implementation: `7ede6ca9275b7605faf9340a60431ec180219a1f`.
- Issue: #52675.
- macOS 27.2 (Darwin 27.2.0, arm64): Claude Code 2.1.326, Codex CLI 0.169.0, Muse Code 1.4.20.
- Linux (arm64): the `node:22-slim` image with
  `@anthropic-ai/claude-code@2.1.326`.

## What the clients did

The server runs a client's sign-in over pipes, with the environment that
`Runtime_setup_login_client.environment` builds. Each probe gives the client a
like environment and a fresh configuration directory, waits 9 or 10 seconds
and stops it.

| Capture | Client and host | `BROWSER` unset | `BROWSER=/usr/bin/true` | `BROWSER=<recorder>` |
| --- | --- | --- | --- | --- |
| [macOS, Claude Code](capture-macos-claude-opener.txt) | `claude auth login` | starts `open` with a link whose `redirect_uri` is `http://localhost:<port>/callback` | starts neither | starts the recorder with a link of the same shape; `open` is not started |
| [Linux, Claude Code](capture-linux-claude-opener.txt) | same, no `DISPLAY` | starts no opener | starts neither | starts the recorder |
| [Linux with `DISPLAY=:0`](capture-linux-claude-opener-display.txt) | same | starts `xdg-open` with a link of the same shape | starts neither | not run |
| [macOS, device sign-ins](capture-macos-device-signins.txt) | `codex login --device-auth`, `muse login` | start neither | start neither | start neither |

In every row the client goes on printing its link and waiting. Claude Code
also goes on asking for the code.

[A made-up code](capture-macos-claude-paste.txt) written to the pipe of
`claude auth login` under `BROWSER=/usr/bin/true` was read: the client
answered that the code was not accepted and exited with status 1, and wrote no
credentials file.

`claude auth login --help` lists no option that keeps the browser closed
(`--claudeai`, `--console`, `--email`, `--sso`). The variables that
<https://code.claude.com/docs/en/env-vars> lists (read 2026-11-17) do not
include `BROWSER`.

## Method

- macOS probes run the client inside
  `sandbox-exec -p '(version 1)(allow default)(deny process-exec (literal "/usr/bin/open"))'`,
  so the probe opens no browser of the machine. The device probe also denies
  `lsopen`.
- A recorder named `open` (on Linux also `xdg-open` and ten other opener
  names) is first in the child's `PATH`. It records its operand count and
  operand. A second recorder is the `BROWSER` command of the control run.
- The probes print the host and the `redirect_uri` of a recorded link, never
  its other query values, and replace printed links and codes.
- Every probe works in a fresh temporary directory and removes it.

```sh
python3 -I claude_opener_probe.py 9
python3 -I claude_paste_probe.py
python3 -I device_opener_probe.py
docker run --rm -v "$PWD":/probe:ro node:22-slim bash -c \
  'npm install -g @anthropic-ai/claude-code@2.1.326 >/dev/null 2>&1 && node /probe/linux_claude_opener_probe.js'
docker run --rm -e PROBE_DISPLAY=:0 -v "$PWD":/probe:ro node:22-slim bash -c \
  'npm install -g @anthropic-ai/claude-code@2.1.326 >/dev/null 2>&1 && node /probe/linux_claude_opener_probe.js'
```

The device probe asks OpenAI and Meta for a device code each time it runs.
The paste probe makes Claude Code send one made-up code to its token service.

## Source checks of the candidate

No Dune build ran. The checks below read the candidate's sources.

- Type check with `ocamlc.opt` 5.5.2, replaying the compiler arguments and
  the ppx action that an earlier build of `467cfe8e8373` recorded, against
  the `.cmi` files of that build. The nine changed files do not differ
  between that commit and the base. 17 units passed: the changed interfaces
  and implementations, the eight interfaces that import
  `Runtime_setup_login_client`, `bin/masc_cli_account_login.ml`, the test
  support module and the two test files.
  - Control: the nine unchanged interfaces compiled this way have the
    interface digests of that build.
  - Negative control: four broken copies failed for their own reason (a
    `match` without `Host_browser`, a `browser_of` without `Operator`, and
    the two call sites without `~browser`).
- `lib/core/executable_path.ml` compiled alone with `ocamlfind ocamlopt
  -package unix` and ran: a relative or empty entry of `PATH` gives no
  absolute path, an absolute entry gives the file, a file without the
  execute bit is passed over, and the two older lookups answer as before
  (7 checks). On the macOS host `absolute_on_path "true"` is
  `/usr/bin/true`.

## Test run

Dispatched after this record was first written, and read once on 2026-11-17.

```sh
gh workflow run test.yml --ref fix/person-login-opens-no-host-browser \
  -f suite=test_runtime_setup_login_client,test_lsp_process_manager -f minimal=true
```

- Workflow `Test`, run 44014905280, head `1a1c79ad166d`. Conclusion: failure.
- `test_lsp_process_manager`: 14 cases ran and passed, the new
  `absolute lookup passes over relative PATH entries` among them.
- `test_runtime_setup_login_client`: 8 cases ran and 7 passed, the new
  `a remote sign-in is handed no browser of this machine` among them.
  `Antigravity reauthentication has no prior login` failed at
  `Accounts.create`, before the call this change touches (issue #52681).

## The follow-up: no home for a refused sign-in

Candidate of #52699, base `8e78ac5f9e10`. A login is made only with the
browser that was decided for its sign-in: `prepare` and `selected_native`
take it, and `environment` reads it from the login. No Dune build ran.

- Type check as above, against the `.cmi` files of a build of the base. 13
  units passed: the two changed interfaces and their implementations, the
  five interfaces that import them, `bin/masc_cli_account_login.ml`, the
  test support module and the two test files.
  - Negative control: a copy whose `start` prepares the login without the
    browser does not compile. `Client.prepare ~runtime_root ...` is a
    partial application there.
- Test run 44021901913 of an earlier head of the follow-up, `cf3ce550acce`,
  read once on 2026-11-17. In that head `start` asked for the browser before
  `prepare`, which did not take it yet. Conclusion: failure.
  - `test_server_preview_keeper_turn`: 1 case ran and passed.
  - `test_runtime_setup_login_client`: 9 cases ran and 8 passed, among them
    `a remote sign-in is handed no browser of this machine` and
    `the browser command comes from PATH or the sign-in is refused`. The
    failure is the Antigravity case of issue #52681.
- Test run 44028569591 of head `97b302ce03de`, where `prepare` takes the
  browser, read once on 2026-11-17, with the same two suites. Conclusion:
  failure, for the same case.
  - `test_server_preview_keeper_turn`: 1 case ran and passed.
  - `test_runtime_setup_login_client`: 9 cases ran and 8 passed, the two
    named above among them. The failure is the Antigravity case of issue
    #52681.

## Unverified

- A person's sign-in through the route on a machine without `true`. That it
  is refused with no directory made follows from the types and from reading
  `start`; no test posts that sign-in.
- What Claude Code does when the command `BROWSER` names cannot be run, such
  as a file removed after the lookup or a path with a space in it. The rows
  above ran a command that exists.
- The filter that drops a `BROWSER` binding of the client's own environment
  is reached by no client today: the three environment projections pass no
  `BROWSER`. The test that sets `BROWSER` in the process and finds the
  command once holds by the projections alone.
- A sign-in that ends with an approved code pasted into the console of an
  account server. It needs a person's approval at the vendor.
- An opener that asks LaunchServices without starting a process. The sandbox
  denied it, and a probe cannot tell an attempt from none. Claude Code's
  opener on macOS is the `open` command (first row).
- Windows hosts, and other versions of the three clients.
