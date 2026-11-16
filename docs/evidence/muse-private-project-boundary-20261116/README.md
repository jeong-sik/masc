# Muse private project boundary

Issue: [#52464](https://github.com/jeong-sik/masc/issues/52464).

## Observation and scope

On 2026-11-16, installed Muse Code 1.4.20 rejected a Keeper's `session/start`
with `session_mcp_base_unavailable`. Its empty workspace was nested inside an
unrelated Git project. With `--trust-workspace`, Muse read that project's
`.mcp.json`, which referenced an environment variable absent from the Muse
child. Muse itself does not need that unrelated credential.

The retained experiment uses the installed Muse **echo provider**, without an
account, model-service request or production Keeper. It reproduces the project
layout and the exact Git initialization command in the proposed source repair.
It does not run the modified OCaml helper or an installed, rebuilt MASC.

Source base: `cf1ee5320c424811484f71c9c004a6ff089259ce`.
Environment: macOS arm64, Git available, Python 3.14 (`uuid.uuid7`).

## Reproduce

Run from the repository root with a fresh output directory:

```sh
python3 docs/evidence/muse-private-project-boundary-20261116/reproduce.py \
  --muse /absolute/path/to/installed/muse-binary \
  --out artifacts/muse-private-project-boundary/new-run
```

Use the installed executable directly to avoid its launcher's automatic update.
The script creates its own account-free HOME, XDG roots, project files and
loopback MCP server below `--out`. It never supplies `UNRELATED_SECRET`.
Its initialization command is `git init --quiet --template= -- <private-parent>`,
with only PATH and explicit disabled user/system Git configuration in its
environment. No hooks/templates or ambient Git environment are imported.

## Results

The checked rerun is retained as `results-checked.json`, SHA-256
`51b58e9a3d27592962064f1e6c1777ac56b30731d9ad6435403df176dc7b1db2`.
It matches terminal events to each acknowledged turn and session ID, records
`params.terminal`, and requires `completed`. MCP requests are scoped to each
host, so the resumed host must independently complete its handshake.

The first run's original `results.json` bytes are also retained, SHA-256
`8c70eeee174b75c0666107519643a5cb59ac671f6b05c9bab427731a7f4e2dc5`.
That first script recorded only terminal method names and cumulative MCP
requests. Review of the original local wire confirmed all four actual terminal
values were `completed`; the checked rerun makes those checks reproducible
and retains the terminal values in its result.

| Case | Observed result |
| --- | --- |
| Empty workspace under unrelated project MCP configuration | `session/start` fails with -32603, reason `session_mcp_base_unavailable` |
| Same workspace after its parent becomes a real Git project | `session/start` succeeds; required MCP initialize, initialized and tools/list observed; two echo turns complete |
| New Muse host, same durable session and storage | `session/resume` succeeds with the same session ID; required MCP reconnects; two more echo turns complete |

Separate exploratory probes also confirmed that an empty `.git` directory does
not isolate discovery. A real initialized repository is required. The host
refuses `admitSessionMcpServers` even with experimentalApi enabled, reporting
`session_mcp_admission_unserved`, so that option cannot replace workspace trust
on this installation. Those exploratory probes remain local working output;
the two result files record only the reproducible before/after/resume experiment.

## Source checks and limits

- Changed OCaml files pass `ocamlc -stop-after parsing`; diff whitespace passes.
- Regression coverage was added for the Git discovery boundary, empty workspace,
  file preservation, redirected `.git` refusal and the readiness workspace.
- Independent source review found a missing direct test-library dependency and
  an overbroad cancellation-protected scope; both were corrected and reread.
- Local Dune builds, type checking, Alcotest and CI were not run, following the
  external coding-session execution protocol.
- MCP handshake and tool inventory are observed. No model-selected tool call or
  Meta model response is claimed by this offline experiment.
- The running MASC was not replaced, and original review requests were not replayed.

The project discovery rule is documented in the vendor's
[configuration guide](https://dev.meta.ai/docs/muse-code/configuration).
