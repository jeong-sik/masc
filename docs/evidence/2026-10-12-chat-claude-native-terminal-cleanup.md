# Claude native content cleanup

Parent: `5f9bf90592a56f4c0a7980c7ed128c30cc625c7a`.

## Authority and defect

`Runtime_claude_code.observe_native_start` owns native occurrence admission.
Its registry distinguishes new, active replay, closed replay, and conflict;
only new admission publishes Native_tool_started. The projection must not
duplicate that replay authority with another terminal identity ledger.

The stream adapter's native map routes admitted observations to content
indexes. Previously Native_tool_finished called the completion observer before
retiring routing and stopping content. An observer exception skipped cleanup,
and a reentrant callback could still find the old routing entry. Turn_finished
closed text/reasoning content but did not close unfinished native content.
The runtime's result handling directly emits Turn_finished without fabricating
missing native completions, so the unfinished-block case is reachable.

Completion now retires routing before observation; Fun.protect guarantees
stop_content in Eio.Cancel.protect afterward, preserving the existing
completion-before-block-stop bridge contract. Terminal publication clears
native routing before closing remaining blocks and MessageStop. Neither path
invents a completion receipt or success status. Native replay authority stays
in the runtime registry.

## Verification

Executed on 2026-10-12 in the isolated checkout, all exit 0:

```
ocamlc -stop-after parsing lib/keeper/keeper_claude_code_runtime.mli
ocamlc -stop-after parsing lib/keeper/keeper_claude_code_runtime.ml
ocamlc -stop-after parsing test/test_keeper_claude_code_runtime.ml
git diff --check
```

These prove syntax and whitespace only. Two registered CLI protocol fixtures
cover an admitted native call lacking a result before terminal, and a raising
completion observer. They inspect stream lifecycle and callback state rather
than TUI text, layout or row order. They are **not executed**.

Type checking, build, CI, live Claude behavior, installation and actual TUI
or dashboard screens remain unverified. If the stop callback itself explicitly
raises, Fun.protect can replace the original exception with Finally_raised;
Cancel.protect prevents inherited cancellation, not an explicitly raised
exception. Claim-time Skill delivery capture remains a separate unresolved
boundary and is not certified by this change.
