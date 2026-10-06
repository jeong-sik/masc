# Agent Core public interface closure (#41188)

Base: `87123f7df94a27ded447b5b05d01c2f5178de029` (fresh origin/main).
Two public aliases named private modules whose CMIs are absent from the public
interface directory. A fresh copy-sandbox build of two small real consumers
failed on both missing targets before this repair. The private CMIs themselves
existed, so the failure was the published interface boundary, not missing source.

The schedule facade expands its existing signature. The pre-execution gate
facade exposes its documented settlement constructors and settle operation,
using public Hook/Event_bus/Tool_contract/JSON types. Gate scheduling helpers
still depend on private execution modules and remain internal. Implementations,
private_modules, and their behavior are unchanged. The other top-level aliases
with explicit interfaces have no private-module type references.

Commands, with OCaml 5.5.1 activated, from this worktree:

```sh
scripts/dune-local.sh build --sandbox=copy packages/agent_core/test/test_public_tool_schedule.exe packages/agent_core/test/test_public_pre_execution_gate.exe
DUNE_BUILD_DIR="$PWD/_build-public-green" scripts/dune-local.sh build --sandbox=copy packages/agent_core/test/test_public_tool_schedule.exe packages/agent_core/test/test_public_pre_execution_gate.exe
_build-public-green/default/packages/agent_core/test/test_public_tool_schedule.exe
_build-public-green/default/packages/agent_core/test/test_public_pre_execution_gate.exe
```

The first build used unchanged production source and failed with both missing
aliases. The second used the repaired interface and a separate previously absent
build directory; both builds disabled the artifact cache. The green build and
both consumers passed. Public target CMIs remain absent: consumers compile via
the structural facade, without making implementation dependencies public.
The consumers exercise schedule roundtrip/invalid batch rejection and the real
gate's Continue/Block/missing approval/owned approval callback settlements.

An earlier setup attempt failed because the new tests stanza omitted its modules
field. That test-only setup mistake was fixed before the actual product RED;
its log is retained separately. Raw logs are unchanged. checks.json records
source, binary and CMI hashes, and manifest.json hashes the evidence files.
This is focused public-interface closure evidence, not a TUI/PTY, full-suite,
CI, deployment, or release result. The issue's original TUI failure was not rerun.
