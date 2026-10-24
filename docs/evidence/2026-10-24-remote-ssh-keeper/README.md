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
