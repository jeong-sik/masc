# #41161 parent propagation

Published #41161 `fa5f560930d417d254fe1955b4ed579e74ce8cb4` cleanly merged
published #41160 `9607401db6a914b4241628c80a7724a48ae49ad0`.
No independent source/test edits were required. Parent changes include the
same-workspace read retry and independent Settings resource settlement. The
child runtime cache resources are unchanged; their authority invalidation and
reload rejection contracts remain compatible with those parent changes.
Incoming Lane panel/editor changes have no child modifications; native source
and tests match the published parent.

Focused commands in dashboard:

```sh
pnpm test src/components/runtime-toml-editor.test.ts src/components/settings-surface.test.ts src/lib/runtime-workspace-resource.test.ts src/lib/runtime-catalog-resource.test.ts
pnpm exec tsc --noEmit --pretty false
```

All 160 tests in four suites passed, followed by a passing typecheck. The
previous 440-test and synthetic-browser evidence remains historical and was
not rerun here. No native build/PTY, browser, full CI or release proof is claimed.
Raw logs are copied unchanged, including their trailing blank lines.
