# Pure microVM build-link planning owner

PR #42120.

Private keeper_microvm_build_plan owns the guest build mount constant, path flattening, closed link states/plans, scan-result parsing, per-checkout decisions and action/target selection (120 lines). The root retains volume/image operations, command generation, execution probes, refusal display and lifecycle/inventory handling (2515 lines). The public microVM MLI is unchanged.

Four manifest type re-exports and a destructive signature include connect the public constructors to the private canonical owner. No forwarding functions, default values or compatibility readers were added. Extracted bodies are exact parent blocks apart from documentation links and EOF normalization. The preceding invalid-path diagnostic repair remains intact.

Focused build `opam exec -- dune build test/test_keeper_sandbox_microvm.exe` completed exit 0. Selected `build volume` cases 5–14 completed exit 0: ten PASS, PUNLY7GF. Cases 18–19 completed exit 0: two PASS, C4ADLTPX. Commands used `_build/default/test/test_keeper_sandbox_microvm.exe test 'build volume' <range> --color=never`. These twelve distinct cases cover pure target/plan/parser logic, scan argv, invalid-path and real-directory refusals, action selection and already-correct targets. Other groups were skipped. No guest command was executed. Seven source hashes, one executable hash and both actual logs are retained. No full CI, installation, VM startup, deployment or live Keeper behavior is claimed. Remaining backend, lifecycle, image, volume and inventory policies require semantic audit; this extraction does not complete the original Godfile candidate.
