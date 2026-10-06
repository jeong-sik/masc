# Ask workspace cancellation fixture evidence

Baseline: PR #41155 `39824b5af5918df6befedc483266706f23aeb786`, main product `6fc062feee7e33a271e09dc155d9feffee923704`. The baseline and repaired checkout have identical `bin/` and `lib/` sources. No production changes or product RED are claimed.

The connection-aware fixture adapter and Ask ingress/cancellation assertions are ported narrowly from frozen release parent `bdd448e956fab264219713b26bd554d3023dfed4`. Other queue, image, A/B/A, runtime and observer scenarios are unchanged. The shared adapter leaves socket ownership with the HTTP handler and only exposes a nonconsuming EOF/reset observation.

Two actual TUI scenarios passed: armed answer without submission and an admitted held POST. Each first exercises the real HTTP adapter with GET: status405, no request gate and no admitted mutation. The submitted path records exactly one POST in A before writing response bytes; B withdrawal removes the question/editor/confirmation, closes the held client before response release and within the existing8s dispatch deadline (below the product10s HTTP timeout), then the released old completion cannot recreate the answer mode or submit in B.

Executed binary: retained exact-main6fc TUI, SHA256 `196d9fce8ecced88ab44ac424d300d9744299ee1f707d323eac9c0803d7bae0e`, rehashed before use. No new native build. `ask-pty.log` records the actual exit0 result of the focused `ask_workspace_withdrawal` invocation; this is synthetic loopback HTTP/PTY evidence, not full regression, release, installed production, or newer-main execution.

Ruff and diff check passed. Pyright is **not clean**:249 baseline diagnostics become273 (index191→214, call29→30; argument27 and possibly-unbound2 unchanged). The added closed fixture variant exposes24 more pre-existing broad-union indexing/calling errors outside the repaired Ask path; the new adapter dispatcher explicitly handles its type. Compact checker summaries and raw-output hashes are retained here; complete outputs remain at `/tmp/pr41155-ask-baseline-pyright.json` and `/tmp/pr41155-ask-pyright-final.json`. No suppression or broad fixture typing cleanup was added.

Remaining release-derived obligations are separate: #40852 Gate-settings applied-diagnostic readiness and #40854 Home startup followup applied-frame readiness. Neither is changed or claimed complete here. #41152 Item proof remains an open followup. The original frozen release PRs and their historical evidence remain untouched.
