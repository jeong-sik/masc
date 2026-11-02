# Physical receiving-turn Skill evidence

The browser rendered `KeeperTurnFlow` as a standalone component at source head
`550f233672c0a748cc87cf34f3f42d2106b43376`, whose backend base is
`714db48454618f7a442889a98f71436e2216c95c`. The harness supplied fixture props,
including the turn record and empty tool entries, and intercepted the HTTP
responses. It did not run the full turn inspector, an installed backend or a
live Keeper. Later documentation/changelog commits do not change that source.

The original fixture is `test/fixtures/skill-ledger-async-actions.json`. Its
invocation is `trace-one#41`; results and actions arrive at
`new-physical-trace#73`. One additional result and causal link were derived from
that fixture to check that three physical actions remain distinct from four
causal links. Original activation frames and the original ledger revision stay
visible. The physical lookup uses the complete receiving turn reference.

Navigation checks establish callback invocation only: the harness callbacks
wrote `messages` or `context` into `#navigation`. They did not open the actual
messages/context tabs or load their provider input. This bundle does not prove
full inspector or exact-input tab integration.

- [Receiving turn](receiving-turn.png): zero current-turn invocations, three
  received handoffs, three physical actions and four causal links. The runtime
  trace request deliberately returns 503; Skill evidence renders and both
  navigation callback checks pass.
- [Incomplete empty scan](incomplete-empty.png): a damaged original ledger is
  reported, and zero returned facts do not become a claim of no receipt or use.
- [Browser observation](proof.json): actual GET paths, rendered text and zero
  page errors for both states. Captured 2026-11-02 with headless Chromium and
  viewport 1120 by 1000, using the fixture props and intercepted HTTP responses
  described above.

Focused validation from `dashboard/`:

```sh
./node_modules/.bin/tsc --noEmit
./node_modules/.bin/eslint src/api/dashboard-skills.ts src/api/dashboard-tools-prompts.ts src/api/keeper-turn-flow.ts src/api/keeper-turn-flow.test.ts src/api/keeper-physical-skill-evidence.ts src/api/keeper-physical-skill-evidence.test.ts src/components/keeper-turn-flow.ts src/components/keeper-turn-flow.test.ts
./node_modules/.bin/vitest run --config vitest.config.ts --no-file-parallelism --maxWorkers=1 src/api/keeper-physical-skill-evidence.test.ts src/components/keeper-turn-flow.test.ts
```

TypeScript and ESLint passed. The new API tests passed 6/6 after correcting the
fixture gap shape and expected error; the component tests passed 4/4. The wider
seven-file check covered the existing dashboard, Skills, async grouping,
Composition and turn-flow consumers. It exposed one pre-existing failure:
`dashboard.test.ts` / `grounds turn-record selected_model / finish_reason`.
The same failure was reproduced at the unchanged root checkout
`a233a3b3a2c017afe73c636ebfcbe1b2013c5fa5`, whose affected test and decoder are
identical to the stack. This is not a claim that the wider suite passed.

Independent source review of `714db484..550f2336` found no remaining P0/P1/P2.
Backend source was independently reviewed separately. Backend OCaml parse checks
are not type checks or execution of the added H2/ledger tests. No Dune, CI,
merge, install, provider acceptance, queue ACK or external PR outcome is proved
by this bundle.
