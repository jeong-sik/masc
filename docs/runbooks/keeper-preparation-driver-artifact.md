# Build an isolated preparation driver

The preparation measurement harness needs a macOS executable built from its
exact candidate source. The ordinary Linux behavior log artifact contains no
Darwin driver. The manual probe workflow can build only that driver without
installing a server, replacing the operator's binary, or requesting provider
execution. Keep this CI change in its own Native Stack, separate from the
feature candidate.

Choose a full candidate commit containing `test/keeper_preparation_trial_driver.ml`
and the corresponding coordinator and prompt sources. Select the CI workflow
branch independently:

```sh
gh workflow run linux-x64-probe.yml --repo jeong-sik/masc \
  --ref "$CI_WORKFLOW_BRANCH" \
  -f target=preparation-driver-macos-arm64 -f candidate_sha="$CANDIDATE_SHA"
```

The target refuses a missing or noncanonical commit identity. Checkout pins that
identity, verifies the actual source before and after the one explicit Dune
target, and packages the executable, coordinator, harness guide and prompts from
that same source. No feature branch is merged into the CI branch. The macOS
runtime target also accepts an explicit candidate as described below; other
manual targets retain their existing checkout behavior.

At a work boundary, inspect the completed run and its actual build step. Download
the `preparation-driver-macos-arm64-<candidate>-attempt-<n>` artifact to a new
private directory. `build-receipt.json` records the actual candidate commit/tree,
separate workflow head, run/attempt, platform, target and every payload file's
size/SHA256. Verify those against the run identity, requested candidate and
downloaded bytes before using the executable. An uploaded artifact or a supplied
source SHA alone does not establish a successful build.

The artifact verifier reads only the downloaded files. Supply identities read
independently from the actual completed GitHub run and its selected candidate:

```sh
python3 scripts/ci/verify-preparation-driver-artifact.py \
  --directory "$PRIVATE_ARTIFACT_DIRECTORY" --source "$CANDIDATE_SHA" \
  --workflow-head "$ACTUAL_WORKFLOW_HEAD" \
  --run-id "$COMPLETED_RUN_ID" --attempt "$ACTUAL_RUN_ATTEMPT"
```

It rejects missing, extra, changed or nonregular payload entries and identity
mismatches, and prints the verified executable and receipt digests. It does not
query GitHub or certify completion, behavior, dependency compatibility or a model
trial. Keep its output outside the immutable artifact directory.

The executable is a native probe, with dependencies recorded by `otool -L`, opam
and Homebrew. This target does not establish a relocatable installed runtime;
verify that the local host provides the recorded native dependencies. Artifact
extraction may remove executable permissions; restore them only on this verified
private candidate. Keep the installed MASC binaries and live base unchanged.

Follow the packaged `PREPARATION-HARNESS.md` using an explicit experiment and a
new private output directory. Build completion is separate from a successful
harness run, real provider identity, paired preparation metrics, independent PR
approval, release verification and visible Ask Question behavior. Preserve
failures and unfinished attempts in the denominator.

## Build the same candidate for Ask Question observation

The driver does not contain the TUI or establish visible Ask Question behavior.
Use the existing four-companion macOS runtime probe with the same candidate SHA:

```sh
gh workflow run linux-x64-probe.yml --repo jeong-sik/masc \
  --ref "$CI_WORKFLOW_BRANCH" \
  -f target=macos-arm64 -f candidate_sha="$CANDIDATE_SHA"
```

When `candidate_sha` is empty, this target selects the immutable workflow head,
preserving its ordinary manual-probe behavior. An explicit candidate selects
that source without merging it into the CI stack. The target builds only the
existing four companions and uses the existing relocatable runtime packager.
It checks both server and TUI embedded build identities against the selected
source. `probe.json` separates actual candidate commit/tree from workflow head
and run/attempt; artifact names contain the candidate commit.

Read the actual completed run, payload hashes and embedded identities before
using this archive in a new private base. Run the candidate with an isolated
connection and record its actual Ask source, TUI answer/delivery decision and
final visible frame. Build/identity output alone does not prove this scenario.
Keep the operator's installed binaries, live base and Keeper configuration
unchanged during the candidate observation.
