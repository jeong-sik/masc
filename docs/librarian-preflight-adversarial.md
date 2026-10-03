# Attack false no-change decisions before enabling skips

The shared Choice decoder establishes wire validity. It cannot prove that a
valid `keep_current` answer preserves a correction, prohibition, preference
change or unfinished obligation. Keep production preflight disabled until
the separately observed quality and full execution criteria are satisfied.

The synthetic corpus at
`test/fixtures/librarian_preflight_adversarial.json` contains explicit
corrections, new prohibitions, obligations hidden among repetitions, revoked
facts, new qualifiers and quoted instruction attacks, plus duplicate and
transient-acknowledgement controls. Korean cases exercise the operator's input
language. Each expected classification and rationale is visible for independent
review. These cases attack the new preflight, not historical-record recovery.

`masc-librarian-preflight-eval` renders the candidate directory's Librarian template
with its normal variable builder, then calls the production preflight. Expected
labels and rationale are not sent to the model. Every input is synthetic;
there is no generation lane, snapshot replacement, range consumption or
production Keeper write. The evaluation honors the runtime's preflight opt-in,
lane/destination credentials and the supplied Keeper's exclusion. Use a separate
test TOML with preflight enabled; do not change the production TOML for this run.
The command deliberately does not restore workspace `prompt_overrides.json`.
Its report declares `prompt_mode=candidate_directory_no_persisted_overrides`;
a passing result therefore covers the supplied candidate files, not a deployed
Keeper's effective template when persisted overrides are active. CLI help names
this mode, and the report retains the actual rendered prompt for every case.

All current facts receive the same timestamp captured at evaluation startup,
so epoch-zero ages cannot reward generation merely for refreshing a stale fact.
The synthetic Keeper instructions are empty for every case, independent of the
expected labels. `--keeper` supplies identity and exclusion policy only; this
corpus does not evaluate a production Keeper's configured instructions. The
report records `fact_observed_at` and `keeper_instructions` alongside each fully
rendered prompt so both input choices can be inspected.

After a focused native build is explicitly requested under repository policy:

```sh
scripts/dune-local.sh build bin/masc_librarian_preflight_eval.exe
_build/default/bin/masc_librarian_preflight_eval.exe \
  --input test/fixtures/librarian_preflight_adversarial.json \
  --output /path/to/new-private-report.json \
  --config /path/to/isolated-test-runtime.toml \
  --prompt-dir config/prompts \
  --keeper synthetic-librarian-preflight
```

The output directory must exist and the report must be a new file. It is
created with mode 0600 before the first request, including all rendered prompts,
corpus hash, config revision and available binary identity. Awaiting and final
observations are persisted through the same report; an interrupted run retains
unmeasured samples. The received destination/model and request hashes remain
attached to each observation, including failover evidence.

`false_no_change` is a `keep_current` decision on a `must_generate` case.
`uncertain` still preserves the need to generate. A control that chooses
generation is an efficiency miss, not evidence of lost information. Unavailable,
failed or invalid answers stay `not_measured`, never a measured success. Exit 0
means no false no-change among this fully judged corpus only; it does not prove
general model accuracy, provider-call savings, final memory quality or latency.
The report leaves Goal completion unestablished. Review these labels and add
actual counterexamples before extending a quality claim beyond the frozen set.

Native execution and actual model results have not been collected by this
source change. Related work: task-2023, goal-1790911534058-d6e92111, issue #40755.
