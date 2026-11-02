# Capability probes retain the selected idle declaration

PR [#47242](https://github.com/jeong-sik/masc/pull/47242) derives the Claude,
Codex and Antigravity probe idle timeout from the selected runtime model and
captured execution default. A later live-catalog reload or runtime removal no
longer replaces that declaration. Native admission and reasoning ownership are
unchanged. Muse already uses the selected declaration.

The public capability-probe fixture selects a private runtime, then reloads or
removes its catalog from the first supplied `now` callback. Six cases cover
Claude/Codex unbounded or absent declarations across a later positive live
timeout and runtime removal. Every case requires an input receipt before
protocol acknowledgement and an actual inert host tool callback. The controlled
0.4-second silence distinguishes the explicit 0.1-second idle declaration;
neither adds a production deadline. Antigravity's projection is source-reviewed;
the six new cases do not exercise an Antigravity catalog race.

Both actual executions are workflow **Test**, ref
`fix/probe-selected-timeout-20261101`, dispatch `minimal=true`, existing
900-second targeted-suite guard:

- [41302158676](https://github.com/jeong-sik/masc/actions/runs/41302158676),
  checkout `116dd79de7b42b136d2dfa45180344b7a0869452`: **FAILURE, 2 PASS / 4 FAIL**. Four reload cases hit the
  newly read live 0.1-second idle limit; both runtime-removal controls passed.
- [41304451817](https://github.com/jeong-sik/masc/actions/runs/41304451817),
  checkout `3a8ef4d8f533aff349e10e50d49e9b93e9d6a47c`: **SUCCESS, 16 PASS / 0 FAIL**. The common six pass;
  ten existing Claude native-effort controls are separate candidate-only cases.
  Actual order is selected idle six, then native-effort ten.

The common six have two successes maintained, four failures fixed and zero
regressions. The four failed baseline cases verify catalog replacement and
input receipt before failing on the returned provider error; they do not reach
the host-tool success assertion. The successful candidate reaches that check.
Runtime/environment state and private child
processes are restored before fixture cleanup. No local build/typecheck ran.

The pair's complete delta is the probe `.ml`/`.mli` plus changelog. Complete test,
Core and config trees match across the pair. Baseline production lib/Core/config
trees equal direct parent `2709c82231ad0d4c4e77d8dda2ab51edc3a0275d`. All other 18 named inputs, including the
complete fixture, Dune and runner, are byte-identical. `source-sha256.json`
records all 20 inputs and four tree IDs at the actual successful source.

The later whole-stack publication retains all 20 named inputs and test/config
trees. Its lib tree differs by a lower Antigravity MLI comment correction; its
Core tree contains a separate response-persistence repair and terminal fixture.
Those changes are excluded from the historical probe execution claim. The
publication binding records this boundary without claiming current Core-tree
identity or execution at a later publication head.

`manifest.json` records completed metadata, checkout, raw/selected byte counts
and SHA-256 digests. `baseline.txt` and `candidate.txt` are ANSI/BOM-normalized,
line-selected derivatives retaining every actual case row, checkout, target,
summary and failure assertion. Raw logs remain in ignored campaign artifacts.
`cases.tsv` seals each identity with source path, group, index and fixture SHA;
ellipsized display names are not identities. Compact UTF-8 JSON keys with a
single LF hash to `372c187376b51fc67ed41411a2c3a77daa523c72ecfc4288d2c9dd22d3839f8b` for common six and `9f2d891f710609233032c997f28bfa6a4adb732fa565911d930512f67f2875b6` for all 16.

Full regression, real provider/account, installed runtime, OS restart and
whole-stack integration are unverified. Internal source/evidence review is not
formal non-author GitHub approval. #27898's original acceptance remains open;
no issue is closed.
