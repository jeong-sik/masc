# Publish a distinct server approval admission identity

Base: 115bb2c8beee9f0475ae5256c6b594df72fc23d2.

End-to-end call-site inspection confirmed that registry lookup, HTTP answer, stored events, Web state and TUI authority all still use the provider call ID. This is not a wait incarnation, so provider reuse remains a real unresolved aliasing risk.

This is the producer stage of that full repair, not a replacement acceptance target. Each registry registration now mints one opaque approval_id through the existing process-wide Random_id UUIDv7 generator. The pending record carries that ID independently of the unchanged provider tool_call_id. GET /keepers/tool-approvals publishes it from the actual registry record. The registry type is abstract, preventing provider strings from masquerading as admission IDs inside OCaml code. The health fixture was updated for the expanded record.

A functional lifecycle test registers and answers two successive waits with the same provider call ID and checks their distinct admission identities. Source interfaces, direct consumers and fixtures inspected; git diff --check passed. No local Dune build/test was executed per execution_protocol; no runtime, CI, screenshot or formal approval claim.

Mandatory next stages: bind Registry.settle and late-answer lookup to this identity, propagate it through REQUESTED/SETTLED and durable journal/AG-UI/TUI decoding, bind Web/TUI answer commands and state keys, validate stale-wait noninterference and unseen-settlement/frontier reconciliation. None of these are claimed solved by this producer stage. Existing behavior remains incomplete until the full path is switched and verified.
