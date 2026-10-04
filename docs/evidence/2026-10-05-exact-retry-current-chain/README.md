# Exact setup retry on the current activity chain

Candidate `5334d702ce1365332d3aa2cc658a4af28a74d55d` composes the #41172 typed setup-retry completion repair and #41191 historical evidence-link clarification through #41208. All 221 tests in the Exact panel, Runtime editor, manual resume control and Settings surface suites passed. TypeScript and changed-source ESLint completed with exit 0. The introducing-owner 198-test result remains separate; downstream additional tests account for this count.

Commands from dashboard:
```sh
node node_modules/vitest/vitest.mjs run src/components/exact-lane-activity-panel.test.ts src/components/runtime-toml-editor.test.ts src/components/model-setup-resume-control.test.ts src/components/settings-surface.test.ts --config vitest.config.ts --no-file-parallelism --maxWorkers=1
node node_modules/typescript/bin/tsc --noEmit
node node_modules/eslint/bin/eslint.js src/lib/exact-lane-activity-session.ts src/components/exact-lane-activity-panel.ts src/components/exact-lane-activity-panel.test.ts src/components/model-setup-resume-control.ts src/components/runtime-toml-editor.ts src/components/settings-surface.test.ts
```

Dependency package/lock files matched the reused local node_modules. Raw logs are byte-exact; hashes are in checks.json. Native bin/lib/test/packages trees are unchanged from published leaf9f26f8f, so native tests were not rerun. No browser, real backend activation, full CI, deployment, formal approval or TerminalBench claim. Pending Browser/native and Machine workspace findings are separate responses.
