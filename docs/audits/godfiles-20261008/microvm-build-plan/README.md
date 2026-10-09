# Pure microVM build-link planning owner

Base: 558f2fa37df2e9b60e0e319aa3826187b728e7b2.
Code head: cf0fa37f5332ffba0b0ab7ab008e13c55bb4a0ff.

Private keeper_microvm_build_plan owns the guest build mount constant, path flattening, closed link states/plans, scan-result parsing, per-checkout decisions and action/target selection (120 lines). The root retains volume/image operations, command generation, execution probes, refusal display and lifecycle/inventory handling (2497 lines). The public microVM MLI is unchanged.

Four manifest type re-exports and a destructive signature include connect the public constructors to the private canonical owner. No forwarding functions, default values or compatibility readers were added. Extracted bodies are exact parent blocks apart from documentation links and EOF normalization. The preceding invalid-path diagnostic repair remains intact.

The first focused build completed exit 0 but started before extraction edits were finalized; it is not final-head build evidence. Final-source focused build `opam exec -- dune build test/test_keeper_sandbox_microvm.exe` completed exit 0. Selected `build volume` cases 5–13 completed exit 0: nine PASS, WDTIJ4OL. Cases 17–18 completed exit 0: two PASS, 38W5LHQL. Commands used `_build/default/test/test_keeper_sandbox_microvm.exe test 'build volume' <range> --color=never`. These eleven distinct cases cover pure target/plan/parser logic, scan argv, invalid-path and real-directory refusals, action selection and already-correct targets. Other groups were skipped. No guest command was executed. Seven source hashes, one executable hash and both actual logs are retained. Independent source review passed the code head; final evidence delta remains under review. No full CI, installation, VM startup, deployment or live Keeper behavior is claimed. Remaining backend, lifecycle, image, volume and inventory policies require semantic audit; this extraction does not complete the original Godfile candidate.
