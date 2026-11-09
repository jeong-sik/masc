# Native execution history: frontend candidate observation

Source candidate: `ea6228b4b3552e545253f85f83ebb29d565cc7a3`, with base
`ae1eab278fd3780ec5ba27201b14b7271e370660`. The screenshots show the actual
`ChatTranscript` consumer using synthetic HTTP responses from
[`dashboard/fixtures/native-execution-history`](../../../dashboard/fixtures/native-execution-history/README.md).
They do not show an installed candidate server or an executed Core journal.

## Observed

- [Completed call](completed.png): expanded Core history, all three event pages
  consumed through the same high watermark, canonical parent/node tree shown.
- [Second call](second-call.png): a second retained association selects its own
  node tree.
- [Missing journal](missing-journal.png): a refused Core read remains an explicit
  error, with the ordinary conversation still visible.
- [Requests](requests.json): five synthetic native-history requests; the later
  pages keep the original `through` cursor and advance `after`. No trajectory
  or tool-log request substitutes for these history reads.
- [Validation](validation.json): three frontend test files, 183 tests passed;
  full Dashboard TypeScript and targeted ESLint exited successfully. Commands
  ran from `dashboard/`. The local incremental-cache path is sanitized as
  `<artifacts>`; raw logs remain in the campaign's ignored working artifacts.

Ego Lite TaskSpace 40 rendered the Vite fixture on loopback. Screenshots are
unmodified browser captures. [Manifest](manifest.json) records their bytes and
the candidate's source-file hashes; it does not certify later source changes.

## Failure and correction

Candidate `98ccbf59952fd1bc5af940144d0952dd92e77f4c` passed the earlier 181
frontend tests but failed this actual conversation mount in Chromium. The htm
`<>` tag became an empty element name and raised `InvalidCharacterError`.
The candidate above imports Preact's real `Fragment`. Two additional typed
operation integration cases cover the previously absent mount path; the final
183-test result and these successful captures belong to the corrected source.

## Evidence limits

The backend changes passed syntax parsing and independent source review only.
No local Dune build, OCaml typecheck, Core/Owner behavior run, CI, installation
or deployment is established here. The new-process completed-history scenario
in `test_keeper_ingress_native_restart.ml` remains unexecuted in this record.

The full transition in [#25338](https://github.com/jeong-sik/masc/issues/25338)
remains open: historical driver provenance, official/native mixed execution,
unbound calls and aggregate consumers are not covered by this frontend fixture.
