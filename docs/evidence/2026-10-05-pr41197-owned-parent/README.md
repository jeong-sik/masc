# #41197 owned-parent integration

Merge the published #40960 owned evidence repair into the nonempty-refusal child. The sole conflict was two adjacent test-registration additions; both the child minimum-admission cases and all six parent ownership/publication cases are retained. The child product source remains byte-identical to its previous published head; the parent Store implementation is byte-identical to its reviewed source.

Focused OCaml5.5.1/DUNE_JOBS=2 worker build passed. All37 worker cases passed in7.015s from the built test directory with declared isolated test environment and DUNE_SOURCEROOT. Exact source, binary and raw logs are in checks.json. This checks the composition and does not relabel historical REDs as a new regression run or claim full RPC-frame, provider, fullCI or release proof.
