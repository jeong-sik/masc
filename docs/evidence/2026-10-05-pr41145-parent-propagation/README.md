# #41145 parent propagation

Published #41145 `1270dc3d2de2705db4388705d4c130ea0a0100f4` cleanly merged
published #41135 `026a52a548665de62a00d98aa0a47050a2db77d6`.
No independent product, test or dependency changes were made.

The Web inventory reader uses `/api/v1/lanes`, now available through the parent
H2 route as well as H1. Its explicit enabled Boolean declaration contract is
unchanged and matches the parent serializer. Native source/tests are identical
to the published parent; no native build or PTY run was repeated.

In dashboard, the initial test invocation failed before tests because this
worktree had no node_modules (`web.log`). `pnpm install --offline --frozen-lockfile`
then passed (`install.log`), followed by:

```sh
pnpm test src/api/lane-inventory.test.ts src/components/lane-inventory-panel.test.ts
pnpm exec tsc --noEmit --pretty false
```

The two focused reader/presentation suites passed all seven tests (`web2.log`);
typecheck passed (`tsc.log`). These are mocked-HTTP component/decoder tests, not
an actual browser/H2 run, full CI or release proof. Parent evidence and older
browser artifacts remain historical. Raw logs are preserved exactly.
