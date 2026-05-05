# archive: lib/cancellation (2026-05)

## Why archived

`lib/cancellation.ml` + `lib/cancellation.mli`는 **MCP 2025-11-25 spec의 client
request cancellation 토큰 store**로 도입됐지만, 2026-05-05 audit 응답 시점에
production caller는 단 하나뿐이었습니다 — `bin/main_eio.ml` + `bin/main_stdio_eio.ml`이
서버 시작 시 `TokenStore.init ()`만 호출. 이후 `create`, `cancel`, `is_cancelled`,
`on_cancel`, `cancel_by_id`, `create_for_task`, `token_to_json`,
`handle_cancellation_tool` 등 모든 token 조작 API는 **production에서 한 번도
호출되지 않음**. 즉 init이 만든 store에 token이 추가되는 적이 없어 사실상 dead
init이었습니다.

또한 `Cancellation.cancel`은 token에 atomic flag를 set하고 등록된 callback을
실행할 뿐, **실제 fiber 취소는 하지 않습니다**. 진짜 fiber cancellation이 필요한
곳(`lib/keeper/keeper_unified_turn.ml` 등)은 직접 `Eio.Cancel.cancel`을 호출하므로
이 모듈을 거치지 않습니다.

`docs/audit-responses/2026-05-05-dashboard-heuristic.md` §5.1 참조.

## Restoration procedure

만약 향후 MCP cancellation tool이 실제 wire-in 되어야 한다면:

1. **RFC 작성** — 어디서 token을 발급/무효화하는지, fiber cancellation과 어떻게
   연동되는지(또는 단순 metadata store로만 사용할지) 명시.
2. **archive에서 lib/로 git mv 복귀**:
   ```
   git mv archive/2026-05-cancellation/cancellation.ml lib/cancellation.ml
   git mv archive/2026-05-cancellation/cancellation.mli lib/cancellation.mli
   git mv archive/2026-05-cancellation/test_cancellation.ml test/test_cancellation.ml
   git mv archive/2026-05-cancellation/test_cancellation_coverage.ml test/test_cancellation_coverage.ml
   ```
3. `test/dune`의 `(names ...)` + `(modules ...)` stanza 두 곳에 `test_cancellation`
   복원, coverage stanza에 `test_cancellation_coverage` 복원.
4. 호출 site 추가 — `Cancellation.TokenStore.init ()`을 다시 호출하는 것이 아니라,
   real cancellation flow의 entry/exit에 token operations 연결.

## Files

| File | Purpose |
|------|---------|
| `cancellation.ml` | Token store implementation (atomic flag + callback list). |
| `cancellation.mli` | Public API: `TokenStore.{init,create,get,...}`, `cancel`, `is_cancelled`, `handle_cancellation_tool`. |
| `test_cancellation.ml` | Token lifecycle + handle_cancellation_tool unit tests. |
| `test_cancellation_coverage.ml` | TokenStore coverage tests. |
