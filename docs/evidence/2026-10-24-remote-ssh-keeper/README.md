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
  product defect until a separately reviewed connection change is executed.

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
