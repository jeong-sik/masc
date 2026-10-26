# task-1534 evidence — admission_error_reason 경계 래칫 허용 목록 정리

- task: task-1534. 브랜치 polish/task-1534-admission-reason-boundary @ 6388bf9
  (base = origin/main 51aa016)
- 방향 정정: 등기 시 전제였던 "죽은 export 삭제(안 A)"는 **검증 당국 정정
  (vrf-0d900eee, keeper_librarian_runtime.ml:364 유일 호출 실측)으로 반증** —
  삭제 시 librarian의 Slot_unusable → lane_fit.unusable → 사용자 보고
  (Exact_request_projection_failed의 slot 제외 사유 한 줄)가 파괴됨.
  검증 당국 권고대로 **스캐너 허용 목록 정정(안 B)**로 수리.

## 변경 (1 file, +4/−2)

packages/agent_core/scripts/check-exact-output-resolver-boundary.sh
scan_public_error_accessors:
- 허용 목록에 `admission_error_reason` 명시 추가(disposition 2개와 동일 구조)
- 실패 메시지에 허용 목록을 명시해 다음 예외가 보이는 결정이 되도록 함
- 래칫은 다른 모든 admission_error_* / target_selection_error_* /
  wire_admission_error_* accessor에 대해 계속 무장 상태(약화 아님)

## 근거 체인 (task-1533/NOTES.md + vrf-0d900eee 정정)

Exact_output.admission_error_reason (mli:481, #35234 9dcf59e 유입)
← keeper_librarian_runtime.ml:364 `Slot_unusable (... reason)`
← fit_decision → lane_fit.unusable → slot_reason_pairs (ml:408)
← Exact_request_projection_failed { slot_id; reason } — 사용자 보고.
호출처는 librarian 단 하나(저장소 전역 재확인: lib/ + packages/).

## 검증 (수정 커밋 이후 리비전 — vrf-a5770991 순서 교훈 반영)

- 01-boundary-fix.log: shellcheck **exit=0**, 래칫 직접 실행(15파일) **exit=0,
  "exact-output resolver boundary: OK"** (커밋 전 워킹트리, 20:33Z 전후)
- 02-at-fix-revision.log: **head=6388bf9(fix_commit, ancestor=yes)에서**
  `dune build @check` **exit=0**; llm_provider 스위트 FAILED 1/4 =
  exact_output_plan.ml:683 자격증명 동결 — 기존 고장 1건 불변(#35091 계열),
  본 변경과 무관
- 남은 red 귀속(01 로그): cohttp_eio_body_flow 1/3(업스트림 cohttp-eio 6.2.1,
  task-1533 판정), media_document_admission 1/16(내 task-1532 수정이 main
  미병합 — PR #35275 대기; 이 브랜치는 51aa016 기반이라 당연히 red)
