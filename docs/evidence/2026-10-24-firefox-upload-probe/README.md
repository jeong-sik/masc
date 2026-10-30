The generated Firefox controls proof still used `Upload {selector; paths}` after the canonical `Browser_action` interface switched to a typed upload target. Code PR #45717 changes only that expression to `Upload {target=Browser_action.File_input "#upload"; paths}`. It retains the staging lease, private snapshot, later file-byte readback, real multipart upload and every existing assertion.

The captured base is `fd75478aa3146c4e3910773ad00336dd0adba472`; code head is `785a76ef673ed7e437ca100066a410a0dfc9d83b`. This evidence layer adds no production or test behavior.

| Historical main execution | Exact tested source | Four executable build | Whole-tree `@check` |
|---|---|---|---|
| [40067402060](https://github.com/jeong-sik/masc/actions/runs/40067402060), job 120793433335 | `574bdc1d1a2e7a62b876c88c3d9b634000cf2227` | actual PASS | actual FAIL |
| [40065856949](https://github.com/jeong-sik/masc/actions/runs/40065856949), job 120788844489 | `f326c4cfe9e2b4547f3b76f6e8d8f164971dc0a0` | actual PASS | actual PASS |

Both runs missed the successful-input receipt cache and executed the build/check commands. Restoring Dune artifacts did not skip those commands. The four targets were `bin/main_eio.exe`, `bin/masc_tui.exe`, `bin/masc_browser_host.exe`, and `bin/deployment_preflight_helper.exe`. `@check` compiled/type-checked test source; it did not execute test cases. The failed run did not write/save a success receipt.

The actual compiler diagnostic was:

```text
File "test/firefox_controls_probe.ml", line 294, characters 43-51:
294 | act upload (Browser_action.Upload {selector="#upload";paths})) with
Error: The field selector is not part of the record argument for the
Browser_lane__Browser_action.interaction.Upload constructor
```

Dune generates that file by concatenating the download fixture and controls fixture with real MASC module aliases. The bad expression is `scripts/fixtures/firefox_controls_probe.ml:263`. That fixture, the download fixture and canonical action ML/MLI are byte-identical between failed 574 and captured base fd754. The exact generating stanza is also identical (SHA256 `f665e341383fb5b0b4781fbbd6a69d8ba67a635f52172894a3e46162692f3e09`); other `test/dune` stanzas changed. At earlier successful f326 the canonical constructor still took `selector`; failed/current source takes `{target : upload_target; paths}` with `File_input of string | Chooser_opener of string`.

[build-observation.json](build-observation.json) retains exact run/job identity, decoded-log hashes, step outcomes, compiler diagnostic, input digests, toolchain/cache details and source blob identities. Ubuntu 24.04.5/x86_64 used the validated OCaml 5.5.1 contract and cached `ci-5-5-1` switch; pin/dependency setup succeeded. Separate runtime compiler/Dune version stdout was not printed; source Dune language/minimum is 3.22.

[source-checks.json](source-checks.json) records OCaml 5.5.1 parser-only checks for the changed fixture and canonical MLI, direct MLI inspection, whitespace validation, exact code head and file hashes. Comparing the complete fixture against the captured base confirms only the reviewed expression differs. These checks do not establish compiled types, linking, a running Firefox proof, a test-suite result, installation or deployment. No local Dune was run.

The existing `main-minimal-build.yml` has no candidate-SHA input and runs its build job only on main. The authorized bounded equivalent is one existing `merge-compile.yml` dispatch pinned to the final evidence-top SHA/PR for the four products, plus one existing `main-check.yml` dispatch at the same frozen branch for `@check`. Workflow checkout semantics and GitHub head snapshots must bind those later receipts to the actual source. Neither request nor completion is claimed by this document; record their actual identities separately after publication.

The historical f326, failed 574 and captured fd754 non-documentation input digests differ, so neither old result is current combined-main compile proof. Earlier installed c2dfa and its build are separate evidence. This small source repair and its evidence require independent source review on both Native layers; CI success does not supply that approval. Root owns whole-stack integration.
