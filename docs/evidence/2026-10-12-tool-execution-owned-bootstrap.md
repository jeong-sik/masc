# Tool execution publication follows owned bootstrap admission

Base: c805d388cd3c84340fb09b15d246f527716e6085. The preserved RED fixture completed bootstrap and tools/call but lost the successful result.

Selection fields are now one immutable credential-tagged snapshot with a selection identity. Exported tool/form/errors/result are readonly projections that hide foreign-credential snapshots. Execution owns an exact identity and credential. Normal bootstrap can migrate the original selection only through MCP's immutable actual admission receipt (fromRevision/authRevision). A changed selection or replacement execution cannot be adopted. Authentication recovery forwards its actual producer fromRevision to the admission callback. Callback refusal throws a typed supersession error before transport, and MCP rechecks authentication after the callback.

The first attempted preflight implementation performed redundant bootstrap; its focused test failed with three calls instead of two. It was replaced with the actual MCP admission callback, preserving exactly bootstrap plus tools/call.

Five focused suites passed 28 tests, including real core/dev-token/MCP bootstrap success, external replacement during bootstrap and selection replacement during credential publication. Negative cases perform no tools/call. Existing schema ownership, mounted reload and MCP admission fixtures remain covered. Log: /tmp/tool-execution-owned-bootstrap-focused-20261012.log. TypeScript noEmit exited 0; diff check passed.

This is source/functional fixture evidence with controlled fetch responses, not actual provider/server/browser screenshots, CI, official approval, deployment or full chat completion. Recovery-specific consumer and reactive observer adversarial cases still need review.
