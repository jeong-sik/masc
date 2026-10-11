# Tool execution normal bootstrap failure

Candidate base: fb5e6b744f9c104b42f18ee1d9d8beaa4833dd0f.

The real core/dev-token/MCP/consumer path, with only fetch and external toast/report/store boundaries supplied, completes exactly two calls (bootstrap and tools/call). The successful tool output is absent from lastResult. The new functional fixture fails; /tmp/tool-execution-bootstrap-red-20261012.log records it. This is an intentionally failing candidate, not a passing change or integration-ready PR.

Source cause: the credential notification clears executionOwner and selection while ensureBinding performs the original call's legitimate bootstrap. The caller pinned pre-bootstrap authRevision and selection, so its successful receipt cannot publish. A schema admission callback alone cannot solve execution selection retirement. The repair must preserve the exact owned bootstrap provenance while immediately revoking externally replaced credentials and user selections; matching token text or adopting the latest credential is not sufficient.

No actual server/provider, browser screenshot, CI, approval or deployment is claimed. External replacement, reentrant selection and authentication recovery must be verified alongside the positive bootstrap case before integration.
