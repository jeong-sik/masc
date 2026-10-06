# Inherited absorb-gate fixture drift

The integrated #41162 consumer run reached an inherited fixture failure, not a
new Exact activity behavior defect. Actual diagnostic execution showed two
successful same-actor records and identical global registry ownership: the
parent Librarian pass plus its absorb evaluation. Ancestor `1c3d79293e` (#40709)
added the separate evaluation records without updating this cardinality check.

The fixture now reads full records and distinguishes the structured parent
input from the evaluation direction/request input. It requires exactly one
parent and one evaluation per actual JEV request, and rejects unclassified
records. Run-ID prefixes do not select records. Existing status, output,
credential-redaction, memory-store and durable-replay assertions remain.

Advancing the test exposed a second inherited assumption: ancestor
`d6a6b884f4` (#40758) prepends JEV preflight evidence. The meaningful assertion
is that absorb evidence precedes large exact output on success, not that it is
the first field. Failed passes intentionally retain gate evidence without an
exact_output field; the test asserts that separate typed-status contract.
The intermediate unconditional-both-fields test was incorrect for failure
output and is preserved as an explicitly superseded assertion attempt.
No production code was changed.

Commands from the worktree root:

```sh
opam exec --switch=5.5.1 -- scripts/dune-local.sh build test/test_keeper_librarian_absorb_gate.exe
```

Then from `test`, with `DUNE_SOURCEROOT` set to the worktree root:

```sh
../_build/default/test/test_keeper_librarian_absorb_gate.exe
```

The final focused build passed and all 45 tests passed. `diagnostic-red.log`
is actual judgment case 27; `first-field-red.log` and
`unconditional-fields-red.log` are intermediate full-suite failures.
An initial diagnostic-only compile used an unexported lane helper and was
corrected before the diagnostic execution; it is not product-regression proof.
These are local native fixtures, not full CI, deployed runtime or release proof.
Raw logs are copied unchanged, including trailing blank lines.
