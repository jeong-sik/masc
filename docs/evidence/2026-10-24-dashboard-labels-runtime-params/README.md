The preceding Firefox candidate actually built all four operator products but its full-tree `@check` failed at a separate direct consumer. This upper repair removes exactly three stale `Lib.Runtime_params` qualifications from `test/test_dashboard_labels.ml:36,44,49`. It keeps `module Lib = Masc`, the `Lib.Runtime_settings` typed handles and every existing test assertion unchanged.

Canonical `Runtime_params` belongs to unwrapped `masc_core` (`lib/core/dune`). Its `set`/`clear` functions accept the same opaque typed handles exposed by `Runtime_settings`. The existing tests stanza already depends on `masc_test_deps` (`test/dune:1977`), which re-exports `masc_core` (`test/deps/dune:53`). There is no dependency stanza or production API change.

The main boundary was captured once at `4cad4c4ce9cdf8f9c1a1d96a94e4a5a8a54b09e6`. Direct reads there confirm that the test, canonical MLI, core library declaration and test Dune file still match the failed candidate base. A complete qualified-reference scan at `fd75478aa3146c4e3910773ad00336dd0adba472`, plus direct reads of all 40 changed source/fixture/stanza files in the complete 78-file/12-commit delta to that captured main, found no additional qualified `Runtime_params` consumers. Git blob identities for every changed source read were checked. Only those three references in this one test file need the namespace correction. This is a frozen source diagnosis; main was not repeatedly followed.

Historical measurements remain distinct:

| Prior candidate `46b60f3352fb0cd009324620bc0b207d582af0b7` | Actual outcome |
|---|---|
| [merge-compile 40070267421](https://github.com/jeong-sik/masc/actions/runs/40070267421) | Four operator executables built; source receipt MISS; build command executed, not skipped. |
| [main-check 40070270792](https://github.com/jeong-sik/masc/actions/runs/40070270792) | Actual exact checkout; `dune build @check` failed with `Unbound module Lib.Runtime_params` at `test/test_dashboard_labels.ml:36`. |

[Public completed-run readback](https://github.com/jeong-sik/masc/pull/45719#issuecomment-6381054558) records the exact candidate, jobs, commands and limits. [prior-candidate-build.json](prior-candidate-build.json) preserves the verified structured receipt, artifact identity/digest, decoded-log hashes and the actual failed check. The compile workflow head differs from the candidate checkout; its binding step and checkout log establish the actual tested source. Receipt `proof_only` and `toolchain_override` are both false. No binary SHA256 was published by that workflow.

[source-checks.json](source-checks.json) records the canonical dependency direction, exact source hashes, current-main equality and OCaml 5.5.1 parser-only/whitespace checks. These checks do not prove a compiled type-check. The prior four-product PASS does not become a new full-tree PASS or a build of this upper repair. No local Dune, new suite, timeout, facade, compatibility alias, duplicate store, install or runtime change was introduced. A new final-head `@check` request is authorized only after independent review of the published upper vector; no such request or outcome is claimed here.
