# Actual deferred Addon worker qualification

The focused `test_keeper_addon_deferred_runtime` executable uses the real
configured Runtime and Candle Python MCP worker, exported schema/owner,
Keeper capability surface, tool bundle, ToolSearch and Agent Tool_set.
The actual loaded handler invokes the worker and consumes its structured result.

The Keeper's host-only submit is refused by the actual worker. An explicit
Operator call retains the pending original; the Agent reads that same request.
Off withdraws discovery and refuses the already-loaded handler without RPC.
After real retirement, On creates a different instance/export authority over the
same persistent worker state. The old handler remains stale. A newly loaded
Agent reads the retained original. A denied surface installs neither the tool
nor an unusable loader.

This executable has one case and registers no Exact runner. Module initialization
leaves the runner absent; `For_testing.reset` does not reset that runner. The
actual host cycle records `No_exact_runner` without delivering a fabricated
terminal, so pending recovery is deliberately measured under that condition.
The test does not manufacture a host original or authorize a model judgment.

Independent nonauthor source review and OCaml parser/whitespace checks passed.
The implementation agent also ran a separate three-process Python-only smoke
for Keeper submit refusal, Operator submission and fresh-process original read.
That smoke is not execution of the OCaml integration test. Compiled execution
of this new executable is pending and must be recorded with its actual head.

Container launch/cleanup are process fixtures. No provider, judgment completion,
payout, real Docker, installed native binary, visible Dashboard/TUI or automatic
rebinding of an old Agent handler is established. This bounded case does not
complete C02, E12 or the original 54 acceptance criteria.
