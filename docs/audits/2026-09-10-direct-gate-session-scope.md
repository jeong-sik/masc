# Preserve the actual session scope for direct Gate continuation

A channel-origin direct turn writes its checkpoint beneath
`<session-root>/channels/<channel-key>/<trace>`. The Gate suspension retained
that checkpoint in the actual directory, but reconciliation and retained
checkpoint loading searched `<session-root>/<trace>`. Approval therefore could
not wake the original channel operation through its saved checkpoint.

The existing semantic Gate wait now requires a validated relative session
scope captured from the actual admitted session directory. Reconciliation
uses that scope with the current trace; retained loading uses it with the
accepted checkpoint trace. Admission rejects a different scope. Scope equality
is part of same-wait identity, and SQLite serialization preserves the scope.
Missing scope is rejected rather than silently interpreted as the root session.
This extends the not-yet-deployed C2/C3 Gate wait format.

The production producer/Queue/Owner/current-history/replay fixture now also
runs with its checkpoint in a channel directory. SQLite restart coverage
asserts the channel scope survives reopening, and a different scope cannot
consume the original wait. Invalid path components are rejected. The existing
root-session, denial, and retention-failure scenarios remain in the suites.

Validation at authoring: `ocamldep -modules` syntax parsing and `git diff --check`
passed. No local build or test execution was performed. Targeted CI must run
`test/keeper_chat_operations/test_keeper_direct_gate_wait`, `test_keeper_owner`,
and `test_keeper_tool_dispatch_runtime` on the delivered head.

This is a locator repair, not a claim of deployed Gate continuity. Simultaneous
runtime retry plus new Gate obligations, and failures while binding the Gate
request before checkpoint admission, remain separate dependent work.
