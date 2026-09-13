# Installed LSP failure: project Dune command resolution

The installed 851f412 IDE sent the complete didOpen document but produced no diagnostics. The same input was replayed directly to an independently owned ocamllsp process, bypassing the MASC proxy. The exact existing fixture URI, source bytes and upstream initialization parameters were retained. No browser rerun, live server restart, original source edit, or product build was performed.

## Default environment reproduces the failure

`default-environment/stderr.txt` records ocamllsp's didOpen handler failing inside Merlin_config.Process.start: execve selected `/Users/dancer/me/scripts/dune` and returned EACCES. That file exists with mode 0644 and is not executable. The original document was never registered; codeLens returned an empty list, inlayHint returned “no document found”, and no publishDiagnostics arrived during the observation. The independently owned server then completed shutdown/exit with code 0. This reproduces the installed symptom without proxy delivery or concurrent writer involvement.

The first disposable harness failed to parse the server's additional Content-Type header; that harness failure is explicitly retained in initial-harness-failure.json. The corrected parser produced all three complete protocol captures here.

## Corrected command resolution

`toolchain-path` repeats the same input with only the existing OCaml toolchain bin directory prepended to PATH. Its Dune executable is mode 0755. The server now registers the document, inlayHint succeeds and publishDiagnostics arrives. `explicit-build-system` independently selects the same executable with ocamllsp's existing OCAMLLSP_PROJECT_BUILD_SYSTEM setting and observes the same result. These are distinct environment interventions, not two claims of installed success. Each owned process exited cleanly and the original source hash remained unchanged.

`toolchain-path-buffer-change` changes only the owned language server document buffer to `let value = 1\n` at version 2. Its initial three diagnostics become exactly one: the project configuration diagnostic remains, while both syntax/typed-hole diagnostics disappear. Both notifications omit the optional version. The source file stays byte-identical. `diagnostics-reference.json` retains both text hashes and exact diagnostic arrays for a subsequent installed comparison.

The diagnostics include the two expected syntax/typed-hole errors and one project-configuration error: no Dune config exists for this fixture source. Therefore a subsequent syntax repair must be verified separately from that remaining configuration diagnostic; a universal zero-marker assertion would overstate what this fixture can establish. No local Dune build was run. Only ocamllsp's normal `dune ocaml-merlin` configuration retrieval occurred.

## Next operational step and remaining scope

At the next authorized owned restart, prepend the resolved toolchain directory containing the working ocamllsp/Dune pair to the service PATH while retaining the remaining entries, then rerun installed IDE acceptance on that explicit environment. Keep the nonexecutable wrapper untouched. Report the existing project configuration diagnostic separately.

The direct replay establishes environment-dependent document registration and diagnostic delivery by ocamllsp, not installed proxy/browser success, updated-document continuity, full IDE acceptance, or Keeper LSP use. Separate proxy concerns remain unproven for this failure: concurrent notification/request frame serialization and silent rejection of invalid document roots. The current process stderr drain also hides ordinary LF-delimited short diagnostics; exposing those errors is a separate observability improvement.

The archived replay scripts contain probe-specific paths and operate on the explicitly selected read-only fixture. They are evidence utilities, not product configuration or portable runtime defaults.
