# Exact approval navigation from Keeper chat

Refs #26415. Base:3cce9a517b25863c00b48cfb3dd79b994ebc1044.

Current Gate deferrals park individual calls and emit typed approval lifecycle rows; no current stop reason produces Awaiting_gate_approval. The existing lifecycle producer/history decoder already retains the exact approval ID. This candidate connects that canonical ID to #approvals?approval=ID rather than guessing one from old status prose.

The receiver uses URL identity for selection and queue/history view. A link picks the named pending request even when it is not the first row and survives reload. A missing, removed or undecodable target leaves its identity visible with explicit unavailable detail and no substituted dossier. Choosing another request changes the URL; choosing history explicitly clears the target, and opening an exact link returns to its queue view. A historical status without identity says it cannot open an exact request; its secondary action is explicitly the whole approval list. Route normalization discards approval identity on unrelated tabs.

## Selected execution

Local Vitest:src/components/approvals/approvals-surface.test.ts,src/components/chat/primitives.test.ts,src/router.test.ts —265 PASS. New scenarios cover live typed row versus REST history hydration link identity, exact receiver selection after remount, actual decision request retaining that ID, target disappearance/reappearance and no neighbour substitution, explicit navigation through history. Existing two-suite235 PASS preceded three meaningful cases. Initial new test setup failures (missing required history row ID and attempted assignment to computed gateData) were corrected to the real public contracts, then all selected cases passed. No local Dune, full build or full regression. TypeScript typechecking and CI are not claimed.

## Real browser, controlled inputs

Ego task40 operated actual candidate ChatTranscript/history decoder/router/ApprovalsSurface/API decoder. A local HTTP fixture supplied the frozen history and gate JSON. Clicked the persisted exact link, reloaded, and observed selected=[appr-exact], rail=appr-exact with appr-other first in the queue. An absent target produced zero selected cards and zero dossiers while retaining the requested ID. Screenshots exact-reloaded.png and exact-unavailable.png were visually inspected. Task finished and agent tab closed.

The fixture initially used the normalized summary_status object instead of the wire string and omitted required null keys. The actual API decoder rejected both rows; the fixture was corrected, and valid=[appr-other,appr-exact], violations=[] observed before positive QA. This exposed a misleading not-found message in the initial candidate; final wording reports unavailable detail without inferring absence or completion. Vite's cached inline HTML proxy initially omitted newly added CSS imports; direct candidate CSS links supplied the correct layout for the captures. No API decoder was relaxed.

Reproduce with server.py and its sibling JSON on127.0.0.1:18479, copy browser-harness.html to dashboard/approval-link-qa.html, then serve candidate Vite with MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:18479 on15179. The HTML imports actual source modules; this is a test entry, not an application route. Use /dashboard/approval-link-qa.html, click the request link, reload; then open #approvals?approval=appr-absent. Do not use approval actions against a real backend for this scenario.

## Evidence boundary

These are selected local behavior tests and real Chromium component-fixture interactions. The JSON is a controlled persisted-history representation, not a live Gate-produced approval. A real Keeper call, server write/restart/live-event path, installed Dashboard, deployment and whole #26415 completion remain unproved. Keep the issue OPEN. No authorization policy, server schema or approval lifecycle producer is changed. Source review and formal approval/merge remain separate.
