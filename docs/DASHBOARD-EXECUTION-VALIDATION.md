# Dashboard Execution Validation

`Execution` surface는 서버 내부 fixture mode로 결정적 검증을 우선합니다. 기본 smoke는 room seeding 없이 `execution_smoke` fixture를 직접 읽고, `Execution -> Intervene/Command` handoff까지 함께 확인합니다.

## Quick Checks

```bash
dune build
dune exec ./test/test_dashboard_execution.exe
cd dashboard && pnpm install --frozen-lockfile && pnpm run build
PLAYWRIGHT_MODULE_PATH=/abs/path/to/playwright \
  ./scripts/harness_dashboard_execution_smoke.sh
```

## Fixture Contract

- env: `MASC_DASHBOARD_FIXTURE=execution_smoke`
- endpoint: `GET /api/v1/dashboard/execution`
- expected lanes:
  - `execution.queue`
  - `execution.session-briefs`
  - `execution.operation-briefs`
  - `execution.worker-support`
  - `execution.continuity`
  - `execution.offline-workers`

## Smoke Expectations

- execution queue shows blocked session and operation blockers
- affected session lane is non-empty
- affected operation lane is non-empty
- worker support lane is non-empty
- offline worker lane is non-empty
- queue selection narrows session/operation support rows
- session handoff preserves `source=execution` on `Intervene`
- operation handoff preserves `source=execution` on `Command`
- clicking a worker support row opens `agent-detail-overlay`
- clicking a continuity row opens `keeper-detail-overlay`

## Notes

- `Execution` smoke is selector-based and should not depend on free-text casing.
- live room state is not required for the fixture path.
