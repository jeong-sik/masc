# Actual isolated native TUI / API review

**OBSERVED PASS within the exercised installation, On/Off/reconnect and native PTY scope.** No P0–P2 blocker observed on that path. This is not whole-goal, Dashboard, provider or release verification.

## Identity and isolation

Downloaded source `a6fba325404c963061b7b95c4c564e35f5ea5e2e`, native run 39928840589, workflow `9bf443caaeaf8c54db442c64cfb90d87d6b7cf26`. Independently read both executable embedded commits and checked server SHA256 `c0c96aefea1a1bbfe23f693fbbdb823228710565d04b7050c54359d5765a3e22`, TUI SHA256 `1b85a7130be2331e9cfdef09129d44dbdbd172f7a9724102e51e637f05c35f98` and generated key-reference hash against receipt. Native artifact logs report 26 TUI + 5 application tests successful; these are preexisting selected checks, not new local tests.

The actual matching server and TUI ran under `/tmp/masc-addon-actual-review-20261023/workspace`, private HOME/XDG/config and unused port 52645. Full health confirmed those effective roots and embedded server source. Live `/Users/dancer/me/.masc` and installed programs were untouched. A privately copied installed native launcher was necessary: its hash is recorded, its build source unverified. No container was created.

## Actual observed sequence

| Action | Actual evidence |
|---|---|
| Features → Plugins | Native PTY captures `02-features`, `03-plugins-empty`; two distinct product surfaces |
| Package grouping | `06-package-roles` and real package-catalog API; Browser/Analysis groups from explicit role |
| Role/service/runtime | `07-role-service-preview` shows Browser role, MCP-tools service, host-process execution separately |
| Guided local draft | `08-local-draft`; actual API `08-api-before-save` still zero declarations |
| Explicit save | `10-save-result` + `10-after-save-inspect`: durable file receipt and applied worker `01a16812-b06a-7000-ad4b-4d590ec6ee25` |
| Off draft, before save | `11-off-unsaved-draft` + API `11-unsaved-off-inspect`: worker remained enabled |
| Save Off | `13-after-off-inspect`: inactive installation, original retained native release; original Python PID 44581 absent |
| Reconnect On | `18-reconnected-inspect`: replacement `01a16814-72b5-7000-a94e-29142454bdec`, same installation/manifest/run/config revision, old instance retained |
| Explicit observation | `19-explicit-observe` accepted pending; later `20-after-observe-inspect` has new instance seq 2/pending false; `21-reconnected-editor` shows matching coverage cursor |
| Current/history UI | `19-current-reconnected` + `20-reconnected-history`: active replacement and independently identified old history |
| Final cleanup | `23-final-off-inspect`: both instances retained with native release; durable claim records consumed. `cleanup.json`: server/TUI/both Python PIDs absent, port available |

The worker is the actual first-party `addons/output-statistics/server.py` and `addons/protocol.py` from the selected source, run over real native MCP stdio. Fixture manifests explicitly choose host_process, omit container-only limits and use one Browser-role variant of the same statistics worker. No mocked HTTP, model or worker backend. With empty sources it correctly returns zero rows and partial upstream coverage (no count known); that is no proof of domain data processing.

Saved owner/configuration, original/replacement incarnations, observation files and native claim history were copied from this workspace to `evidence/durable-runtime/`. File receipts were observed in the real TUI; API read/observe requests and responses are stored with bearer omitted. Keyboard commands, full raw PTY bytes and interpreted cell buffers are retained. There are no screen assertions.

## Artifacts and limits

Evidence: `/tmp/masc-addon-actual-review-20261023/evidence`. Exact hashes: `evidence-manifest.json`. Seven PNGs in `screenshots/` rasterize the actual PTY cells; they are explicitly not OS screen captures or physical paint/latency measurements, and default colors are supplied by the renderer. Representative current/history image was visually inspected.

No Dashboard, real provider/model, browser backend/transport, exported tools, server-restart recovery, real input results or whole 54-item goal was exercised. Features readiness labels were observed, not promoted to provider health. Artifact receipt does not include the externally supplied native launcher. The real UI/API result here is bounded to this trusted native first-party fixture.

No source changes, new tests, Dune, typecheck, local build/test runs, CI watch, public PR, push or approval. Capture-tooling issues were resolved locally: unauthenticated reads initially returned401 until isolated admin login; a read-only logging helper attribute typo was corrected. Final state has no live owned processes; only this workspace's files and evidence remain.
