# Eval Feed owned read boundary

## Reproduced defect

The Eval Feed reader joined an unvalidated `agent_name` onto its eval root and
used ordinary directory/file reads. Isolated sentinel snapshots demonstrated
parent traversal and symlink-supplied data. No operating files were traversed.

| Direct-reader case | Original | Candidate |
| --- | --- | --- |
| `../outside` selects an eval-root sibling | 1 foreign row | 0 rows |
| Agent directory symlink | 1 foreign row | 0 rows; not listed |
| JSON symlink beside one local JSON | 2 rows | 1 local row |
| Eval-root directory symlink | 1 foreign row | 0 rows; no agents listed |
| `.agent_core` ancestor symlink | 1 foreign row | 0 rows; no agents listed |

Actual HTTP-router cases additionally reproduced a parent selector reading
foreign data, a linked agent appearing in the fleet, and a linked JSON replacing
the latest retained snapshot. All three cases pass after repair. A NUL-selector
control still returns no snapshots. These are file-boundary/correctness results,
not a production latency benchmark or a report of operating data disclosure.

## Repair

The reader validates a single literal component with the existing
`Fs_compat.owned_relative_path`. It inventories directories with the existing
descriptor-relative `read_owned_directory`, and reads JSON with
`load_owned_regular_file`, reusing its parent/leaf and descriptor identity /
snapshot validation. There is no ordinary-file fallback or realpath-preflight
permission shortcut. The workspace is the ownership root; `.agent_core`, eval,
agent directories and JSON symlinks are refused. Relative workspace roots are
resolved against the caller's current working directory.

Agent listings classify direct entries without following symlinks. Names such
as `-` and Unicode remain valid. No ASCII regex, new size/count cap, UID policy
or permission gate was added. No UID/permission ownership guarantee is claimed.
Expected initial ENOENT with no close failure remains quiet; other read failures
remain diagnostic. Typed filesystem failures produce the existing empty-result
contract, and Eio cancellation propagates. JSON schema, filename-descending order
and limit behavior are preserved.

## Verification and provenance

Explicit native targets only, OCaml 5.5.1:

```sh
opam exec --switch=5.5.1 -- dune build test/test_eval_feed.exe test/test_dashboard_http_core.exe
_build/default/test/test_eval_feed.exe
_build/default/test/test_dashboard_http_core.exe test eval_feed_owned_boundary
_build/default/test/test_dashboard_http_core.exe test eval_feed_cache_selection
_build/default/test/test_dashboard_http_core.exe test effective_tool_quality_sampling
_build/default/test/test_dashboard_http_core.exe test exact_query_cache_identity
```

Original production was rerun with link-safe fixture cleanup: direct cases
**5 FAIL / 3 PASS**, HTTP cases **3 FAIL / 1 PASS**. The raw suite output shows
each failed case and the first assertion's details; it does not print every
failed assertion's complete trace. No teardown errors appear in these retained
baseline logs.

Final candidate: **23 + 4 + 3 + 3 + 5 = 38 PASS**. Coverage includes existing
parser/serializer/retained ordering/limit cases, literal and relative names,
quiet fresh-boot absence, the four HTTP boundary cases and the parent cache
repairs. Source, command, exit, log and executable hashes are in `validation.json`.
The chain is eval reader -> owned filesystem APIs -> `test_eval_feed.exe`;
eval-feed route -> reader and response cache -> `test_dashboard_http_core.exe`.

Independent review found that the old shared fixture cleanup followed directory
symlinks. The fixture now removes its own `.agent_core` without following links.
After the corrected baseline, its cleanup guard moved from the request body to
before fixture preparation, covering setup failures too. Baseline and final
HTTP test hashes therefore differ. The exact two-location change is retained
in `baseline-to-candidate-runner.patch`; scenario bodies and snapshot fixtures
are unchanged. Final candidate compilation and all 38 checks ran after this move.
The verbatim unified patch contains its required blank context line (` `), which
`git diff --check` flags as trailing whitespace in this evidence artifact.

Full regression, CI, deployment, browser/UI readiness and latency measurements
were not performed. Coordinated concurrent replacement stress was not run; this
repair reuses the shared owned-reader validation rather than claiming additional
race guarantees. Temporary fixture trees are removed without following links.
