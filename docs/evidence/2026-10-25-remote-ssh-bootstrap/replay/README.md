# Exact-source shim over the existing SSH endpoint

Static ARM64 artifact run 40199085663 / artifact 12601655322 built candidate
`327fd90f7fec1a07f4ca7e5836d5cad3e8e39c15` with workflow/driver source
`9eadb31bb73bd4d66e43cb34bc6e7715a5106810`. Its downloaded checksums and
binary hash were verified before the direct SSH comparison. The static binary
SHA256 is `a53e5b79eda98a5a4a97c13e772b7b6c0fe724640078690c0445c848b6c88861`.
Its own probe names protocol 3.0.0 and release 0.64.0; the build receipt separately
binds the source commit/tree and the actual config-loading frame in CI.

The owned endpoint is the same container and pinned host key as the neighboring
native bootstrap evidence. A single frame was sent over real OpenSSH with
ControlMaster disabled to two binaries, using the same endpoint configuration,
workspace, payload and existing file:

- The installed preexisting shim returned exit 1 and a framed config refusal
  naming unknown key `env_file`.
- The candidate, copied to its own temporary path, returned a successful framed
  execution. The payload independently reported endpoint cwd, uid 1000, the
  preserved environment value, the preserved PATH tool's output and the exact
  retained file SHA256.

The before/after receipt verifies that the workspace entries/file hash,
configuration bytes and **installed old shim** hash were identical. This probe
did not replace the installed endpoint binary or edit the original config to
make the candidate pass. Raw stdout/stderr and the exact executed driver are
retained. An earlier driver attempt stopped at the expected old refusal because
it compared JSON-escaped stderr text rather than decoding the trailer; it ran no
candidate payload. The corrected attempt's receipt binds its own driver hash.

The comparison above is a direct framed OpenSSH experiment. The following
native-bootstrap and Keeper stages are separate executions with their own raw
logs, drivers, hashes and receipts.

Native macOS artifact run 40201223245 / artifact 12600889724 built helper/server
source `a7685562be55678229ce29668c624d222cd76d67`. The six executable assets and
runtime archive passed their downloaded checksums; the main executable returned
that exact source commit. Helper SHA256 is
`b1463d327eb76f49cde71871b0da4c9eb8c664215ab5258a4a805ca8c2fd4efd`;
server SHA256 is `3c5304609b04f85ba6747407a631a8e14730b7da7dd8d79c0be321a23d367f1a`.
The ten fake-SSH CLI cases passed locally after the native EINTR repair. The
local receipt explicitly records the observed terminal completion and its output
tail; it is not a newly executed test or a full raw log.

The packaged helper then ran three actual SSH bootstrap invocations, with no
GitHub token: old-shim refusal, exact-source shim install, and repeat install.
The old shim returned nonzero `remote_ssh_preflight_unavailable` with its config
cause and no success announcement. Its exit 124 is the native CLI's code; this
driver used no timeout wrapper. The new shim succeeded twice and its installed
remote bytes matched the static artifact hash. The preexisting 39-byte file,
workspace/file owner/group/mode, endpoint `path`/`env_file`/`scratch_root`, and
absence of a Keeper GitHub hosts file were independently reread and preserved.
The identity was already authorized: password-based first key copying is not
covered. The native driver checks helper and shim source identities separately;
the shim is source 327 above, while the helper/server is source a768.

A later first-creation experiment used the same native/artifact pair to prepare
the previously absent `native-fresh-20261026` workspace, still without GitHub
credentials. It returned an empty uid-1000 directory with mode 0700. A binary
marker was then added and a second bootstrap retained its hash and directory
ownership/mode, with endpoint configuration bytes unchanged. Its driver, two raw
CLI logs and receipt are retained separately. The recorded helper/shim byte hashes
match the validated artifacts above. This uses the existing SSH identity too.

After that bootstrap, an actual Keeper used Execute/Write/Read/Edit/Grep over
the same endpoint. Nine calls completed through eleven scripted model requests.
Endpoint-side readbacks verified the edited file and retained binary file after
work, server shutdown, and explicit resumption of the same manual Keeper on a
new server runtime instance. The payload verified the endpoint environment and
PATH tool both initially and in the final resumed execution. It reused the
reported absolute cwd inside Python, as Execute cwd, and in absolute file-tool
arguments. Canonical tool ledger/checkpoint, model requests, server identity,
stream responses and direct endpoint snapshots are retained.

The model is a scripted loopback fixture. These real tool/SSH/bootstrap stages
do not establish real-model autonomy, long-job lifecycle, GitHub authentication,
visible native TUI behavior, release installation, production deployment or full
readiness. Private workspace files and auth tokens are excluded from the public
evidence; the copied files were checked against the actual private token bytes.

Large model/checkpoint/ledger/health/log/stream transcripts are losslessly gzipped
to keep the review diff readable. `transcript-storage.json` binds each original
filename, byte length and uncompressed SHA256; decompressed bytes are identical
to the original public output files. Other receipts and tool results remain plain
JSON/text. `SHA256SUMS` covers the complete retained directory except itself.
The direct comparison preceded the native upgrade, and the Keeper subsequently
created its files. The archived drivers record those initial-state assertions;
repeating the full experiment requires a fresh owned fixture.
