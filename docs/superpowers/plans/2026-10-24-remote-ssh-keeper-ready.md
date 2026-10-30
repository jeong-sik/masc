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

| Requirement | Authoritative completion evidence | Progress and remaining evidence |
| --- | --- | --- |
| Bootstrap without a GitHub token; preserve work on rerun | Actual CLI creates workspace and reruns with retained file | a768 native fresh workspace creation and repeat passed, in addition to old-shim refusal/new-shim upgrade preserving existing bytes and ownership, without GitHub tokens. Password-based first-key copying remains unverified |
| Preserve endpoint tool environment on upgrade | Config roundtrip and real endpoint probe using retained path/env_file/scratch root | a768 native bootstrap preserved all three config fields; direct SSH and actual Keeper payloads verified PATH/env_file. Boxed scratch allocation remains separate |
| Discover registered endpoints and diagnose readiness | Current runtime registry projection; named probe results and UI selection | Actual registry/probe projection and browser endpoint selection measured at a317; native TUI unverified |
| Change profiles with endpoint/network fields together | Actual TUI/Dashboard request, persisted TOML reread, rejected/uncertain save recovery | Browser endpoint save and TOML readback passed at a317; full profile transition and native TUI unverified |
| Keeper can Execute, Read, Grep, Write, Edit and enumerate files | Keeper tool records and endpoint-side reread/hash; enumeration uses the exposed Execute tool | Actual baseline and exact-source a317 candidate workflows measured; scripted model |
| Path/root/cwd semantics agree across tools, scripts and receipts | Same nested file accessed through each surface, declared roots and sibling refusal scenarios | a768 actual Keeper reused endpoint cwd inside Python, as Execute cwd and in absolute Write/Read/Edit/Grep, including restart. Overlapping host/endpoint names and declared-root/sibling runtime cases remain separately open; #37324 and #38895 remain separately audited |
| stdin/stdout/stderr redirects work through the public Execute contract | Actual Keeper command workflow including append and split streams; independent endpoint bytes and no projected host file | Public command route passed at a317; current argv contract has no redirect fields. Internal typed IR attachment gap #31442 remains separate |
| Long commands do not block Keeper interaction | Remote process handle, output/wait/cancel and actual remote child cleanup | Gap; #36941 |
| Explicit repository materialization has exact identity | Declared URL/revision/destination, actual clone/readback, repeat without loss of dirty work | #31460 remains open. Current remote-checkouts module already discovers/inspects endpoint repositories; materialization and caller integration need separate verification |
| Optional GitHub workflow works and cancellation cleans up | Keeper-scoped actual auth and repository operation, no token leakage, cancelled remote login cleanup | Unverified; #32910 |
| Reconnect/restart and transport failures remain truthful | Persisted output reread after server restart; named error on disconnect; explicit cancellation and no orphan | Exact-source a317 candidate passed long-base paths, pin refusal/recovery and explicit manual restart; disconnect/cancel still open |
| Endpoint replacement and trust rotation do not borrow old authority | Same-name host/root/key-path changes invalidate readiness and observations; same-path key/pin rotation and ControlMaster reauthentication are separately exercised | Cache identity fix merged; actual a317 pin refusal and explicit recovery passed without ControlMaster; real identity replacement still unverified |
| Runtime installation includes the required SSH operator tools | Exact-source packaged bootstrap/shim availability and install/readback on the exercised platforms | Six-executable macOS candidate a768 checksums/identity verified and native helper executed; exact-source static ARM64 shim 327 installed by that CLI and used by the Keeper. Host release-installer execution and production install remain unverified |
| Operator and Keeper can observe the lane | Current endpoint/shim/last dispatch and errors visible through relevant API, native TUI and browser proof | Unverified |
| Sustained representative Keeper use | Multi-turn real task with artifacts and measured continuity/performance; compare same workload where needed | Unverified |
| Review and integration are complete | Native stack membership/current heads, independent source review, targeted checks, verified merge and matching installed candidate | Implementation stack #45815 merged; follow-up #45848 has independent source review and targeted checks, but independent GitHub approval and matching installed candidate remain open |

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
Current bootstrap-to-Keeper replay:
[native helper, source-built shim and actual Keeper restart](../../evidence/2026-10-25-remote-ssh-bootstrap/replay/README.md).
Bootstrap targeted CI passed at `2172d6e6cc53da69d4ab0264479b767fa8cb0dde`
(run 40078533807). Selection targeted CI passed at
`d8ac0d66fffe3fc89af6becdc0145d7b910c3955` (run 40098708721), after repairing
two module visibility errors from run 40096481342. These results are source and
focused CI evidence; the baseline runtime above is a different commit.
