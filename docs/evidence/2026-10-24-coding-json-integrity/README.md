# Coding-eval collection rejects ambiguous JSON

At base `7501aec032012869d8b979e0d14e1a9a9464ace7`, the production
`coding_eval_inputs.py collect` CLI accepted a receipt containing two
`provider` fields and wrote only the second value into `runs.jsonl`. This
discarded the source ambiguity before the OCaml report's strict duplicate-key
decoder could reject it. Existing-manifest capture and collection had the
same permissive JSON decoder.

The authored regression ran against that unchanged production implementation
first: two tests produced eight expected assertion failures (`baseline.txt`).
Seven collection scenarios cover duplicate provider, model, memory mode,
experiment digest, run ID, nested keys, and manifest keys. The other failure
covers duplicate keys while resuming an existing experiment manifest.

The repair installs one rejecting `object_pairs_hook` for every manifest and
receipt read in the input helper. It catches duplicates before canonical
encoding, including duplicates nested inside objects. Collection validates
all inputs before creating a replacement, so refusal leaves the existing
index unchanged and creates no partial temporary index.

After the repair, the actual production CLI/function fixtures pass, together
with existing input-change, corpus-oracle and symlink controls. The command
in `after.json` ran five tests: four passed and the actual Docker test was
explicitly skipped. Docker grading code did not change and was not rerun by
this author. The earlier Docker receipts remain evidence for their recorded
source/image only. The product diff passed `git diff --check`. The preserved raw baseline unittest log contains trailing whitespace, so the full evidence-inclusive diff does not pass that check. No local Dune build, native
report execution, provider call or live Keeper experiment was run here.
