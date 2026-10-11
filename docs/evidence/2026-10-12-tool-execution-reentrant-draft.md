# Preserve a draft edited during execution admission

Base: 2fcfce86110f9dc172f6c7067193480fdfd02f04. Independent source review identified that publishing execution state can invoke an observer that edits the same selection's form. The following reset restored the submitted snapshot and discarded that new draft.

A real signals effect observes executing and calls public updateFormValues. Its write is untracked to avoid creating a fixture feedback cycle. The parent fails with submitted text remaining instead of the new draft: /tmp/tool-execution-reentrant-draft-red-20261012.log. The request must still carry submitted arguments. The result reset now preserves the latest same-owner selection state and changes only result.

Additional real MCP consumer fixtures verify expired-dev-credential recovery publishes its successful receipt, while external credential or selection replacement during recovery prevents retry. These fixtures use controlled fetch responses, actual core/dev-token/MCP and actual consumer state.

Three suites passed 30 tests; TypeScript noEmit exited 0. Log: /tmp/tool-execution-auth-recovery-focused-20261012.log. No actual provider/server/browser screenshots, CI, independent GitHub approval or installation is claimed. The original P2 review and earlier RED remain evidence; final source review is pending.
