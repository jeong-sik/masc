# Keeper remote-ssh readiness

Objective: remote-ssh 를 Keeper 가 Fully 사용 가능한 레벨로 다져놓자.

Initial source: `0f0da021a4600ed84b66499e3514cebd7151926d`.
The earlier live census found zero declared SSH endpoints and 37 microVM
Keeper manifests. That snapshot is a diagnosis, not the final acceptance test.

The target is a Keeper completing work through its own tool surface on a real
Linux SSH endpoint. A mock transport, static source approval, successful
bootstrap, CI build, or operator-issued shell command is partial evidence.
Record server source/binary, shim protocol/release, endpoint, Keeper, operation,
artifact and provenance separately. Preserve current pinned trust and explicit
endpoint authority; no local/Docker fallback on SSH failure.

| Requirement | Authoritative completion evidence | Initial state |
| --- | --- | --- |
| Bootstrap without a GitHub token; preserve work on rerun | Actual CLI creates workspace and reruns with retained file | Implementing |
| Preserve endpoint tool environment on upgrade | Config roundtrip and real endpoint probe using retained path/env_file/scratch root | Implementing |
| Discover registered endpoints and diagnose readiness | Current runtime registry projection; named probe results and UI selection | Missing |
| Change profiles with endpoint/network fields together | Actual TUI/Dashboard request, persisted TOML reread, rejected/uncertain save recovery | Missing |
| Keeper can Execute, Read, Grep, Write, Edit and enumerate files | Keeper tool records and endpoint-side reread/hash; enumeration uses the exposed Execute tool | Baseline actual Keeper file workflow measured; matching candidate remains unverified |
| Path/root/cwd semantics agree across tools, scripts and receipts | Same nested file accessed through each surface, declared roots and sibling refusal scenarios | Audit required; #37324, #38593, #38895 |
| Typed stdin/stdout/stderr redirects work remotely | Actual typed redirect workflow including append and split streams; host path never opened | Gap; #31442 |
| Long commands do not block Keeper interaction | Remote process handle, output/wait/cancel and actual remote child cleanup | Gap; #36941 |
| Explicit repository materialization has exact identity | Declared URL/revision/destination, actual clone/readback, repeat without loss of dirty work | Gap; #31460 |
| Optional GitHub workflow works and cancellation cleans up | Keeper-scoped actual auth and repository operation, no token leakage, cancelled remote login cleanup | Unverified; #32910 |
| Reconnect/restart and transport failures remain truthful | Persisted output reread after server restart; named error on disconnect; explicit cancellation and no orphan | Baseline manual Keeper restarted and reread files; long-base ControlPath defect found; disconnect/cancel still open |
| Endpoint replacement and trust rotation do not borrow old authority | Same-name host/root/key-path changes invalidate readiness and observations; same-path key/pin rotation and ControlMaster reauthentication are separately exercised | Source review found stale cache keys; repair in progress |
| Runtime installation includes the required SSH operator tools | Exact-source packaged bootstrap/shim availability and install/readback on the exercised platforms | Audit required; normal runtime package currently lists four operator executables |
| Operator and Keeper can observe the lane | Current endpoint/shim/last dispatch and errors visible through relevant API, native TUI and browser proof | Unverified |
| Sustained representative Keeper use | Multi-turn real task with artifacts and measured continuity/performance; compare same workload where needed | Unverified |
| Review and integration are complete | Native stack membership/current heads, independent source review, targeted checks, verified merge and matching installed candidate | Not started |

Implementation units remain bounded and are stacked with `gh stack`:

1. Bootstrap workspaces and preserve endpoint-owned configuration. Verify the
   actual CLI against an isolated transport, then independently review it.
2. Registry projection, diagnostics and atomic profile/endpoint selection.
3. Resolve path, file/redirect, checkout and async execution gaps against the
   existing typed contracts. Separate changes when their ownership differs.
4. Provision an isolated real sshd endpoint, run the matching candidate with
   an isolated MASC base/config root, and exercise an actual Keeper workflow.
5. Address independent findings, integrate the whole reviewed stack and verify
   installation/runtime/UI behavior at the resulting revision.

External coding sessions do not run local Dune builds. Request only explicit
targeted CI checks needed for these changes, continue implementation instead
of watching CI, and inspect results at work boundaries. Keeper lanes may build
with their own toolchain under the repository execution protocol. Never call
an unrun or skipped integration case a pass.

Keep this objective active until every requirement is supported by current
evidence. Any unavailable infrastructure/identity must remain an explicit
outstanding requirement, not a reduction of scope.

Baseline file workflow and evidence scope:
[actual Keeper over pinned SSH](../../evidence/2026-10-24-remote-ssh-keeper/README.md).
Bootstrap targeted CI passed at `2172d6e6cc53da69d4ab0264479b767fa8cb0dde`
(run 40078533807). Selection targeted CI passed at
`d8ac0d66fffe3fc89af6becdc0145d7b910c3955` (run 40098708721), after repairing
two module visibility errors from run 40096481342. These results are source and
focused CI evidence; the baseline runtime above is a different commit.
