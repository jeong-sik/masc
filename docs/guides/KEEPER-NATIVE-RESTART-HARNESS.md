# Keeper direct-message restart harness

`test/test_keeper_ingress_native_restart.ml` exercises the admitted direct-message
entry through the real Owner, `Keeper_turn`, `Keeper_agent_run`, and native Core
execution store. It uses a loopback HTTP provider and the real in-process
`keeper_person_note_set` tool under a temporary workspace.

The first provider response loads the deferred tool with `keeper_tool_search`.
The second calls the note tool. The tool appends to the note journal, so a second
execution would add another row even if its visible note text stayed unchanged.

## Interruption scenarios

The settled-result scenario exits a child process from `on_tool_result_ready`.
Core has already committed the ToolResult and Keeper has committed its tool-call
log, but the next native checkpoint has not been saved. The parent checks that
the Owner is Active, its exact checkpoint lacks the target ToolResult, and the
Core journal contains that result before allowing the recovered invocation to run.

After restart, the same operation enters the real Keeper turn. The test checks
the original input and metadata, the loaded-tool receipt, one provider-visible
ToolResult, one note append, one approval pre-hook invocation, and one committed
tool log/ready callback. It also checks the recovered repetition observation and
the final Owner receipt and acknowledgement. A wrong operation digest must be
rejected without changing the retained execution authority.

The terminal scenario exits after the Keeper turn returns but before the Owner
accepts the returned outcome. Startup must retain the terminal evidence and
report interrupted delivery without dispatching the operation again.

## Running and reading evidence

Use the [approved leader-selected CI procedure](../../scripts/review/APPROVED-CI-SELECTION.md)
to prepare a candidate containing the current reviewed harness and its prerequisites.
A feature branch or an earlier successful head does not supply the selection receipt.
After the workflow changes are integrated into main, dispatch the selected suite
through the trusted main workflow using the actual prepared `SELECTION.json`:

```sh
gh workflow run leader-ci.yml --repo jeong-sik/masc --ref main \
  -f candidate="$(jq -r .candidate SELECTION.json)" \
  -F selection=@SELECTION.json \
  -F tests=true -f suites=test_keeper_ingress_native_restart
```

Read the completed run's actual suite log, exact candidate checkout SHA and selected scope. Each successful
scenario emits a JSON receipt with the test executable's SHA-256 and observed
counters. The Test step sets `MASC_TEST_CANDIDATE_SHA` from the checked-out
`HEAD`; receipts use this value, not the reusable workflow caller's `GITHUB_SHA`.
Outside that step, an unset candidate value is recorded as null. The workflow
uploads the suite runner log. A failed or unexecuted case
is not acceptance evidence, and a previous head's result does not certify a new
integration candidate.

## Scope

The fixture starts real application resources and an Owner registry, but calls
the admitted Keeper entry directly. It does not start the public HTTP server or
exercise the complete server bootstrap. Its approval count refers to the actual
chat approval policy hook. The ready callback runs inside the post-tool observer;
counting it does not claim every later observer side effect survived the crash.

This harness covers text input, durable ToolResults, and the specified Keeper
repetition/load metadata. Arbitrary handler Context mutations, media projections,
autonomous producers, external effects lacking a settled result, and delivery of
a lost terminal reply have separate contracts. A successful run is neither a
production deployment nor completion of the full harness Goal.
