# task-4145 evidence (captured 2026-11-27 20:17-20:43Z by e-masc-the-leader)

Stack #55162/#55180/#55203 merged to main as afd89812d7 / 4b0a7deb42 / d81ecc4232 (sweep run 46060191453 success; head approvals pangyo 6092874606, anyang 6092905640/6092905893/6092906121, be-sleepers 6092897622).

- tree-equality.log: git diff --quiet 488e7baa52 (L3 PR head) vs d81ecc4232 (main tip) -> TREES_IDENTICAL. Same tree => same vite build output.
- ci-run-46060459646.log: full CI log at PR head 488e7baa52 (run 46060459646): type-check success (0 error TS), dashboard job vitest Test Files 212 passed (212) / Tests 5032 passed (5032) (includes dashboard-bundle-preload.test.ts which runs a programmatic vite build), changes/request/python all success.
- guard-main.log: check-unreached-modules.mjs at main tip -> GUARD_RC=0 (334 reachable, 10 pending).
- vitest-main-d81ecc4232.log: local full vitest at main tip, maxWorkers=2 -> 5030/5032 passed, 1 failed (dashboard-bundle-preload) under sandbox memory pressure.
- vitest-bundle-preload-only.log: same file alone, maxWorkers=1 -> RC=0, 1/1 passed (36s).
- build-main-d81ecc4232.log: local pnpm build in this 2GB-cgroup sandbox is OOM-killed (BUILD_RC=137) during rollup chunk rendering after 2220 modules transformed; the production build is proven by CI (bundle-preload test builds the bundle) + tree identity.
