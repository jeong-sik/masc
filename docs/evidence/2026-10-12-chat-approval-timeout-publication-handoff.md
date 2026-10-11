# Timeout publication and late-answer handoff

Base: `6938d3a2ea89f0a34b84a1cdde62363ea5973d7e`.

Source inspection found a cross-boundary gap: the registry removed a timed-out wait and returned, then the gate recorded its question in the late-answer store. An HTTP answer between those effects found neither a live wait nor a recorded question. This is a source-derived interleaving, not an executed failure reproduction.

Timeout now atomically removes the actionable wait and publishes a transient retirement record under the same registry lock. The gate supplies an on_timed_out callback that records the exact admission in the late-answer store outside the lock. A concurrent settlement for that admission awaits the publication receipt before returning false, so the unchanged HTTP late-store lookup happens after publication. A finally block removes the transient record and resolves publication on success, exception or cancellation. No durable-failure default approval is introduced; the late store keeps its existing durable append/fencing policy. Retirement records exist only while the actual publication is in flight.

The mock-clock state test pauses publication, starts a concurrent answer, checks that it remains waiting and the timeout is no longer actionable, then releases publication and verifies that the answer sees publication completion before fallback. This test source was not executed. Existing registration, displacement and exact-admission behavior remain unchanged.

Validation: OCaml 5.5.1 syntax-only parsing of all four changed ML/MLI files succeeded without diagnostics; hashes/exits `/tmp/chat-approval-timeout-publication-syntax.json`. `git diff --check` passed. Syntax is not typechecking or functional proof. No local Dune build, CI, formal approval, merge, installed/runtime/provider continuity or screenshots were verified. Independent source review is requested separately.

Broader Thinking/tools/saying/interleaving/broadcast goal remains active. Unseen terminal/frontier/resource retirement, real provider/runtime paths and visible installed UI verification still require work.
