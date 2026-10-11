# Approval identity through durable events and TUI waiting state

Base: 1405a05b88fde0594110e076a50c83a5f3353838.

The opaque admission identity now has a dedicated pure Keeper_tool_approval_id module. The gate creates one identity per approval callback and passes it to mandatory registry admission, REQUESTED and SETTLED. Inventory serializes the same registered value. Identity parsing uses the existing canonical UUIDv7 boundary, with no provider-string fallback.

Durable event JSON and AG-UI retain this identity. TUI live decoding and durable-log projection carry the same typed value into the waiting state. Settlement matches admission identity instead of the reusable provider call ID; provider ID remains separate metadata for the tool's argument row. The TUI request decoder requires actual args/reason fields instead of synthesizing a prompt from an incomplete request.

Functional state case added: two requests share a provider call ID but have different admission IDs; settling the older ID leaves the newer awaiting state. The gate callback test also verifies that REQUESTED names the actual registry row. Existing stream and event fixtures carry canonical typed IDs, with one shared ID for each opening/closing pair. Direct registry callers were updated for the required admission parameter.

Validation: changed OCaml files parsed with OCaml 5.5.1 using stop-after parsing; /tmp/chat-approval-event-id-syntax-final-20261012.json. This is syntax only, not typechecking, build or functional execution. The final receipt includes the shared-ID fixture edits and per-file source hashes. git diff --check passed. No local Dune/CI/runtime/screenshot/formal approval claims.

Remaining mandatory stages: HTTP and late-answer identity lookup, registry authority key, Web state and commands, TUI answer commands/inventory ownership, unseen-settlement and inventory frontier/resource reconciliation. Provider-ID reuse is not fully fixed until these paths switch and are verified. Earlier producer identity helpers were replaced by the dedicated type module rather than kept as compatibility aliases.
