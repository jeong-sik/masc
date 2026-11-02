# Exact turn source outcomes

The actual full Turn Inspector at source head
`7177cd820a2100c910edfc84172e8f537c738eb8` was rendered in headless Chromium
using Vite and intercepted synthetic GET responses. This is frontend integration
evidence, not a running backend, a provider submission, or a deployment result.
The functional change was independently reviewed at
`a423db1f4e58fb7798af6aee154076b24d508d9e`; the intervening commit only added
the PR's changelog fragment.

The turn record is the first row of the repository's
`dashboard/src/api/fixtures/turn-record-writer.jsonl`. Source outcomes and
provider-input parts are explicitly synthetic. All requests select Keeper
`alpha` and `trace-1780648779957-00000#4071`; no live Keeper was messaged.

The browser completed these paths with no page errors:

1. Select **입력과 실행** and observe a completed-turn ACK for one exact source,
   while another source has no observed receipt. The admission revision
   `9007199254740993` retains its exact digits. See [source-outcomes.png](source-outcomes.png).
2. Use **실제 메시지 열기**, open the message part, and render its returned text in
   the real Messages tab. See [messages.png](messages.png).
3. Return to flow and use **System·도구 스키마 열기**. The real Context tab reads
   and renders the System part and tool-schema part for the same turn.
   See [context.png](context.png).
4. Reload with a damaged-row/storage-error response. The independently observed
   receipt remains visible alongside partial coverage; the empty source is not
   classified as currently pending. See [partial-read.png](partial-read.png).

[proof.json](proof.json) retains the request paths, exact source head, browser
scope and observed text. [capture-hashes.json](capture-hashes.json) identifies
the unchanged copied capture bytes. The local runner and original output are
under `artifacts/stimulus-cycle-observability-20261102/continuation-2/source-outcomes-preview/`;
`node run.mjs` was run from that directory. It closed its Vite server and browser.

Focused verification at this source:

- Four Vitest files: **27 tests passed** (API `keeper-turn-flow`,
  `keeper-turn-source-outcomes`, `keeper-physical-skill-evidence`, and the
  `keeper-turn-flow` component tests).
- TypeScript `tsc --noEmit` and ESLint for all changed TypeScript files passed.
- The new OCaml interface, implementation, runtime-trace caller and lifecycle
  test file passed `ocamlc -stop-after parsing`. The OCaml lifecycle tests were
  **not executed**; no local Dune build or CI run was requested.

The new ledger join has not been measured in the installed server. Its read is
streamed through the existing runtime-trace IO worker/cache path. Retained-read
positives do not certify an atomic current queue snapshot or an external PR
verdict. The pre-existing H2 runtime-trace route gap is outside this change.
