# Distinct configured models keep distinct runtime and run identities

The actual production shell functions accepted `ollama:org/model` and
`ollama:org-model` as one sanitized alias. They declared only the first
`api-name`, then skipped the second model's episode using the first model's
receipt because both produced the same run directory. `baseline.json`
records the exact source head, driver hash, generated configuration and
observed skip. The experiment-check callback was explicitly replaced with a
fixture success; no server, provider or grader executed.

The repair hashes canonical JSON containing the complete original
provider/model pair for runtime aliases. Run IDs hash provider, model, case,
integer repeat index, experiment digest and memory mode. No input name is
sanitized into identity. The row retains the original readable values.
Resume reads the original receipt through the duplicate-rejecting decoder
and requires all those fields plus run ID to match, including JSON types.

The actual shell-function probe now observes two distinct aliases, two
faithful `api-name` bindings, two distinct run directories and independent
successful resumes. Eight wrong-bound receipt controls refuse run ID,
provider, model, case, repeat index, boolean-as-index, experiment and memory
mode changes without overwriting evidence. Existing admission/operation
transport fixtures were updated to locate actual emitted run IDs rather
than fixed names; four shell fixture controls passed.

`after.txt` and `after.json` retain the executed checks: six Python behavior
tests passed, one actual Docker test was explicitly skipped, and four
controlled transport shell fixtures passed. Shell syntax, changed OCaml-test
syntax and `git diff --check` passed. Grader code did not change. This does
not establish native report execution, live provider model identity or a
Keeper episode; no local Dune build was run.
