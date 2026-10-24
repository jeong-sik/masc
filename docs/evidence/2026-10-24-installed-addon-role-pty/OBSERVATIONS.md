# What the installed interaction proves

This evidence addresses the role-grouping and original-selection gaps recorded for frozen #45430. It observes the installed client implementation already present after #45417/#45426; it does not implement or push another product variant.

## Original role and selection scenario

The input `fixture-snapshot.json` deliberately lists Execution before Browser. Its Summary contains an inactive Memory declaration before the Browser worker, so Summary and Flow have different selectable indices. The Browser worker started with package role `analysis`, but its complete, unique current declaration has the exact installation ID and path with role `browser`. A different worker has a declaration with the same installation ID and a different path.

The installed client actually displayed:

- The inactive declaration under Memory & judgment.
- Browser under the current declaration's Browser role, with its original Analysis metadata separately visible.
- The raw-first manual Execution worker under Execution environment.
- The mismatched worker under Category unverified, separately from the declaration at the different path.

These are manual observations of the captured terminal, not new row-order or screenshot assertions. The supplied role metadata does not claim real plugins were running.

The operator entered `:`, `go Plugins`, Enter, then selected Browser with `j`. Pressing `f` opened Flow with action target `worker-browser`. Pressing `a` opened the Browser action menu; Enter produced one actual client POST to `/api/v1/lane-addons/actions`. `action-requests.json` contains the exact instance, expected incarnation, generated request ID and action. The fixture returned its own receipt; Summary kept Browser selected. A later `f`, `f` round trip again retained that original selection. Text frames and the raw stream retain each observation.

## Replacement scenario

The second fixture first supplied the same original worker. After selecting Browser and opening Flow, its owned snapshot replaced that worker with the new pair `worker-browser-replacement` / `worker-browser-replacement` and updated the current declaration. Pressing `r` read the changed snapshot through the actual client HTTP path.

Flow then displayed no selected Plugin action target. Pressing `a` reported that explicit selection was required. `replacement/before-reselection-action-count.json` records zero action POSTs at that boundary. The actual event log contains the inventory reads but no action before reselection. Only after explicit `j`, `a`, Enter did the client submit one action naming the replacement pair; its exact request is retained in `replacement/action-requests.json`.

This is a concrete keyboard-loop refresh/replacement observation. It does not cover every scheduling race or all history, detail, technical and subscription transitions. The preexisting compiled state/action suites remain a separate evidence source; none was fabricated or rerun locally for these captures.

## Current identity contract

At the installed source commit and the inspected main, `Lane_addon_runtime` serializes an instance's incarnation from that same instance ID, and action admission rejects a different incarnation. `Lane_addon_action` likewise rejects a receipt with a different incarnation. Consequently these valid fixture pairs have equal ID/incarnation strings; their equality is an explicit current protocol property. The replacement uses a new unique pair. An invented independent-incarnation success case would violate the current host contract.

Directly inspected source: `lib/lane_addon/lane_addon_runtime.ml` instance serializer and action admission, and `lib/lane_addon/lane_addon_action.ml` context/receipt validation at commit `107c58401723313611f7c599bbe15225de5910da`. `landed-main-source-equality.json` binds the identical installed-source and main role/selection implementation and category domain files.

## Scope and limits

The actual executable is the installed TUI, not a source projection or freshly built private executable. The HTTP server, worker data and action receipt are synthetic. The frame images are lossless PNG presentations of captured tmux text; original ANSI bytes and text remain available. The initial Dashboard has partial-source diagnostics because the fixture serves only the relevant role/action boundary, not a complete operator backend.

The visible `confirmed` state describes the fixture's returned receipt. No real worker, external search, model, container, production server mutation, installation or deployment is proven by it. Both fixture listeners and private tmux sessions were explicitly stopped and their closure checked. No local Dune build, new screenshot/layout test or new control heuristic was introduced.

## Independent artifact review

The coordinating agent independently opened the original role, Flow and action-receipt images, read the captured original action POST, and separately opened the replacement-refusal image and read the zero-before-reselection count, replacement action POST and cleanup receipts. That review confirmed the stated observed target/withdrawal behavior within the fixture scope. It is an independent artifact observation, not a formal GitHub approval, additional execution, real worker effect or production-server proof.
