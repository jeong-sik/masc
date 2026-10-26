# Remote SSH Keeper file workflow

The baseline used an installed runtime copied into a private test directory,
not a build of the bootstrap/selection PRs. Its embedded commit was
`8e534a757f13350d8a34fbd98bc828bc3578e153`; SHA-256 was
`64d302d5c627f4ac9b49de20361b3cbf7c94e46557f11c1fe788e8665a9ca89d`.
The Linux endpoint was a loopback-published sshd container with a dedicated
Ed25519 identity and pinned host key verified against the container console.
The preexisting ARM64 shim had SHA-256
`ad79352d398d00eb48eebdf0bc29faacd3b4de633349e377ed81d560dc379183`;
its probe advertised protocol 3.0.0 and `observe`, without a release stamp.
This does not identify the shim as a build of the candidate source.

An actual Keeper received a scripted loopback model's tool calls: Execute,
Write, Read, Edit, Grep, Execute; after server shutdown/restart and explicit
manual Keeper start, Read and Execute. Eight canonical tool-call ledger rows
recorded completed `remote_ssh` calls. The two server health snapshots identified
the same binary commit/hash and different runtime instances. The canonical
checkpoint contained the final answer after each turn. The remote endpoint's
independent reread matched the marker, hostname, final bytes and SHA-256;
those bytes also survived server shutdown. Kept artifacts are the receipt,
tool results, and endpoint readbacks, with no admin token or private key bytes.

The source reviewer found that the initial harness accepted any one-line Grep
match. The captured actual result was `matches:["1:after"]`, via `remote_ssh`;
the revised harness checks the complete expected result and route. A successful
fixture response is not evidence of model judgement or sustained autonomous use.

Two failures were retained as findings:

- The fixture's intermediate `keeper-a` directory was root-owned, despite its
  nested GitHub config directory being owned by `masc`. Explicit workspace
  ownership fixes file writes. The bootstrap PR's exact no-follow provisioning
  component also corrected that directory over real SSH; this is component
  evidence, not an execution of the compiled bootstrap CLI.
- An output base under `/tmp/mssh-keeper-proof-d` failed during Keeper creation:
  OpenSSH's temporary ControlMaster socket exceeded the host Unix socket path
  limit. A shorter `/tmp/s8` base exercised the remaining tools. This remains a
  product defect whose exact-source correction and regression run are recorded below.

The Keeper currently sees a logical host-shaped workspace path while the
endpoint process runs under `/srv/masc/playground/<keeper>`. Both values are in
the receipt. These results do not settle nested absolute-path behavior,
redirects, async remote commands, explicit checkout materialization, GitHub
authentication/cancellation, UI behavior, candidate installation or long-running
Keeper continuity. Those requirements remain in the readiness plan.

Reproduce against an already provisioned empty Keeper workspace:

```sh
python3 scripts/remote-ssh-keeper-proof.py \
  --binary /path/to/pinned/masc --expected-commit FULL_SOURCE_SHA \
  --output-dir /path/to/new/private-output --keeper ssh-proof-unique \
  --host ENDPOINT --port 22 --user masc-exec \
  --remote-root /srv/masc/playground \
  --identity /path/to/dedicated/key --known-hosts /path/to/pinned/hosts
```

The script uses the production operator CLI and actual Keeper loop, not an
injected runner. It does not build, bootstrap, or delete endpoint workspaces.
Its output includes a private `.workspace` with an isolated admin token; do not
publish that directory. A nonzero exit and `result:FAIL` preserve failure
evidence. Keep the output on the host when investigating the socket-path failure.

## Exact-source candidate: long paths and pin recovery

On October 25, the candidate at
`a3173b973ab93a6b64fd301bca105a67a7529d00` completed the workflow under
`/private/tmp/mssh-keeper-proof-candidate-long-base-a317/.workspace`, a longer
base than the one that had failed with ControlMaster. Candidate executable
SHA-256: `d27fb1565ca8eb220cd751edb83ab193cb43932d8b9ec50fa9ae25067b38a669`.
The artifact came from manual runtime build
[40103050048](https://github.com/jeong-sik/masc/actions/runs/40103050048),
artifact ID `12564165545`. Its checksum manifest passed before execution;
the embedded commit and both health snapshots matched that candidate.
Targeted consumer CI
[40103048786](https://github.com/jeong-sik/masc/actions/runs/40103048786)
also passed at the same head. These are focused checks and a manual runtime
artifact, not a published release or a production installation.

Four actual Keeper turns produced nine successful calls and one expected
transport refusal. The test copied the operator pin file into its own private
workspace, emptied that copy, attempted an Execute, restored the original
bytes in `finally`, and verified recovery. The refused command's sentinel file
did not exist on the endpoint. Independent readback, server shutdown, explicit
manual Keeper restart and resumed reads all passed. The original operator pin
file remained unchanged. Endpoint observations moved from `payload_finished`
to a fresh `lane_failed/transport_failed`, then to a fresh `payload_finished`.

The refusal is a completed tool response with `payload.ok=false`, typed
`transport_unavailable` evidence, and SSH host-key rejection diagnostics. Its
wire envelope and canonical ledger are `ok/completed`; those fields do not mean
the payload command succeeded. The revised harness checks that actual producer
contract rather than treating every generic error as pin refusal. Its reviewed
and exercised SHA-256 was
`52ecdd8c3cf670f4b3d95aeae7eff67b1dc4b82f8390ed6897bfc7aa35d0898c`.

The `candidate-*` receipts are the actual candidate run. The earlier
`negative-control-receipt.json` came from an earlier harness revision against
the baseline binary: it detected unexpected command execution while the pin
copy was empty, and independent endpoint readback found the sentinel. It is
not an execution of the final harness. Independent source review subsequently
rejected unrelated gate/schema errors and required typed transport evidence
and fresh endpoint observations.

The shim is still the preexisting ARM64 artifact described above. Real model
judgement, extended continuity, production installation and the remaining
readiness requirements remain unverified. Add `--exercise-pin-rotation` to
include this optional failure/recovery scenario.

## Browser endpoint selection and durable save

The candidate server and a clean detached Dashboard build both identified
`a3173b973ab93a6b64fd301bca105a67a7529d00`. In an Ego task space, the operator
opened this actual Keeper's settings, chose the sandbox tab, selected the
registered `proof_alt` endpoint and clicked **Keeper 설정 저장**. `proof_alt`
was explicitly declared in this isolated runtime and pointed at the same
dedicated test host. The original `proof` declaration was retained.

The dropdown displayed registered endpoint names, host/user/port, remote root
and prior observations. Before save the new endpoint correctly showed no probe
or dispatch observation. After save its real preflight observations appeared;
the UI removed the unsaved marker. Independent TOML readback changed exactly
the observed sandbox tuple from `remote_ssh/proof/inherit` to
`remote_ssh/proof_alt/inherit`. The save also started the previously stopped
manual Keeper; the screenshots show that state change, not merely a draft.

`dashboard-endpoint-picker.png` and `dashboard-endpoint-saved.png` were captured
and visually inspected. `dashboard-before.json`, `dashboard-after.json` and
`dashboard-receipt.json` preserve the readbacks and scope. The Ego task space
was closed with `finish({keep:[]})`, and its owned candidate server was stopped.
Production installation and workspace configuration were not changed.

This does not prove a full Docker-to-SSH profile transition or native TUI
interaction. The saved chat snapshot also preserves an unresolved observation:
the assistant reply's `execution_id` tool tile and its turn's `tool_call_id`
timeline can show different tools in this candidate. Canonical tool results and
the detailed timeline were the execution evidence here; the reply tile's mapping
requires separate investigation. These observations belong to the tested a317
candidate and are not a verdict on an unexecuted rebased head.

## Public shell command redirects

The current public Execute contract offers literal `argv` or an explicit shell
`command`; it has no typed redirect fields. Issue #31442 describes the internal
Shell IR attachment path. That limitation does not establish a failure of the
public shell command route.

An additional actual Keeper run at the same a317 binary used
`--exercise-shell-io`. Its final Execute deliberately requested a `sh` command
with `intent=request_effect` and performed stdin from a file, truncate, append,
and separate stdout/stderr file redirects. All filenames contained spaces.
The command then read the four files and returned their exact expected bytes.
Independent pinned SSH readback matched them, the projected host cwd held none
of those files, and the endpoint bytes were unchanged after server shutdown.
The same manual Keeper was explicitly started after restart and resumed Read
and Execute. Eight tools and ten scripted model requests completed successfully.

The six `shell-io-*` files retain raw tool results, canonical ledger rows,
independent endpoint reads, the result receipt, and binary/harness provenance.
Both file readback paths use raw bytes with strict UTF-8 decoding so newline
translation cannot hide CRLF differences. Independent review found that defect
in an earlier harness; the retained run was repeated in a fresh workspace after
the correction. A separate comparison rejected 48 byte mutations across both
actual generated readback paths, including CRLF and lone CR variants.
The isolated server was stopped. This proves the public shell route on the
measured candidate; internal typed IR redirects, long remote jobs, real-model
autonomy, current-main execution and production installation remain unverified.
The final Execute repeats the redirect writes after restart; only the unchanged
notes file is read without being recreated then. The independent before/after
shutdown comparison is the redirect files' persistence evidence.

## Reported cwd reuse inside a script

A separate actual a317 Keeper run reproduced the narrower consumer defect in
#38593. Its first Execute created `ssh-proof.json` and printed the process cwd.
The next Execute copied exactly that returned cwd into a Python string literal.
Reading the file through that absolute path returned errno 2 (ENOENT), while
reading it relatively in the same process returned the correct fresh marker.
Base64 of `os.getcwd()` identified `/srv/masc/playground/ssh-proof-20261025-e`;
the reported cwd was the host-shaped `.masc/playground` path instead.

`cwd-replay-receipt.json` labels this result **REPRODUCED**, separate from the
surrounding file workflow's PASS. That workflow completed nine calls and eleven
scripted model requests across two server instances. The two selected tool
results and their canonical ledger rows are retained with independent endpoint
readback. `cwd-replay-driver.py` is the frozen, actually executed experiment,
including its historical absolute test paths; it is evidence, not a portable
operator command. Its hash and the imported harness hash are in the receipt.

The existing path interface intentionally exposes logical host bookkeeping
paths. This experiment establishes that such an output cannot be reused as an
OS path inside opaque remote Python code. It does not establish that the public
Execute `cwd` field or every absolute tool argument fails. That negative run
does not execute the repair;
the [endpoint namespace proposal](../../superpowers/specs/2026-10-25-remote-ssh-endpoint-namespace.md)
records the required implementation boundary. An earlier attempt stopped at
workspace provisioning and is excluded from this reproduction.

## Reported cwd reuse after the namespace repair

The isolated candidate built from `cc9b7661cc6d7b5970ccef4007d2faa1544bdf93`
passed the same previous-output-to-Python-literal scenario. Its executable SHA256
is `94d6a318d47aec870c6435da16dbe5aeaba91f3b88f5b1fd57f9148b06d50006`;
artifact 12594891354 comes from workflow run 40181914023. All artifact checksums,
the executable build commit, and each server's full health identity were checked
before accepting the result.

The returned absolute cwd `/srv/masc/playground/ssh-proof-20261025-g` was copied
unchanged into the next Execute's `cwd` and opaque Python program. The program
read the first command's fresh JSON marker at that literal path; base64 of the
actual process cwd decoded to the same directory. Execute metadata agreed with
the endpoint path. Subsequent Write, Read, Edit and Grep used endpoint-absolute
file arguments and returned that same endpoint file name.

The run completed nine actual Keeper tool calls and eleven scripted model
requests, then explicitly resumed the same manual Keeper after restarting the
server. Independent pinned SSH readback verified edited bytes after shutdown.
The two runtime instance IDs are retained in the receipt. This is a scripted
model on an owned Linux SSH endpoint with the separately identified existing
shim; it is not real-model sustained use, an exact-source rebuilt shim,
production installation or proof of overlapping host/endpoint namespaces.

Retained files, copied from the completed run without rewriting their contents:

- `cwd-reuse-receipt.json`: result, source/binary identity and driver/harness hashes.
- `cwd-reuse-observation.json`: copied cwd, process cwd and matching fresh marker.
- `cwd-reuse-tool-results.json`: all nine model-facing tool results.
- `cwd-reuse-tool-ledger.json`: their nine canonical execution records and actual inputs.
- `cwd-reuse-endpoint-after-stop.json`: independent endpoint byte readback.
- `cwd-reuse-driver.py`: the exact executed extension to the existing proof harness.

The earlier f04 candidate failed at first Keeper creation, before any tool call:
the CLI endpoint override had not reached initial prompt construction. cc9
repairs that path, and this run exercises first creation successfully. Later
test-only compilation repairs do not change the cc9 runtime source; this receipt
still identifies cc9 rather than claiming execution of an unbuilt PR head.
