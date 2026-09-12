# task-1533 — 별개 red 2건 원인 규명 (root-cause-first 결과)

- task: task-1533 (우선순위 3)
- 브랜치: polish/task-1532-audio-expectation
- 기준 HEAD: a0635733 (as of 2026-09-11T20:19Z)
- 실측 일시: 2026-09-11T20:19Z

---

## red #2 — "exact-output boundary violation: admission_error_reason accessor 노출"

### 유입 커밋 (pickaxe 실측 — 02-pickaxe.log)

9dcf59e7b40657b348e5bc2852bd79d9487e2f4b (PR #35234)
Author: Jeong-Sik Yun
Date:   Fri Sep 11 22:54:28 2026 +0900

    fix(librarian): 슬롯 하나의 projection 실패가 exact 레인 전체를
    죽이지 않게 한다 (#35234)
    ...
    A ladder with no projectable slot at all is still a setup error,
    now naming each slot's refusal instead of hiding it:
    Exact_request_projection_failed carries the admission reason,
    rendered by a new Exact_output.admission_error_reason
    (exhaustive over the wire errors, kind names matching the evidence JSON).
    Task: task-1515

### 위반 지점

- 스캐너: packages/agent_core/scripts/check-exact-output-resolver-boundary.sh:544
  scan_public_error_accessors 함수, 553행:
    if (accessor != "target_selection_error_disposition" &&
        accessor != "admission_error_disposition")
  → admission_error_reason이 _disposition 허용 목록에 없어 위반
- exact_output.mli:481: val admission_error_reason : admission_error -> string

### 호출처 (실측)

명령: grep -rn 'admission_error_reason' lib/ --include='*.ml' --include='*.mli'
결과: lib/keeper/keeper_librarian_runtime.ml:364:
        | Error error -> Slot_unusable (Exact_output.admission_error_reason error)

호출처 1건 — keeper_librarian_runtime.ml:364
(모듈 alias Agent_core.Exact_output를 통해 project_slot 내부에서 호출)

이전 NOTES의 "호출처 0건" 주장은 오류였음 (1차 기각 사유).
9dcf59e가 librarian에서 admission_error_reason을 직접 소비하는 구조로 설계됐다.

### 수리 방향

안 A(mli:481 삭제)는 keeper_librarian_runtime.ml:364 빌드를 깨뜨리므로 성립 불가.

올바른 수리 경로:
- 안 B: 스캐너 553행 허용 목록에 admission_error_reason 추가
  (admission_error_reason은 error를 사람이 읽을 수 있는 문자열로 렌더링하는
   accessor로, disposition과 마찬가지로 경계 노출이 합리적)
- 안 C: librarian_runtime이 Exact_output 내부 함수 대신 자체 패턴 매칭으로
  admission_error를 문자열화해 mli 선언을 제거

수리는 별도 task 권장 (본 task 범위: 귀속만)

---

## red #1 — cohttp_eio_body_flow "chunked body reaches the reader intact" (1/3 fail)

- 본질: masc이 아닌 cohttp-eio 6.2.1의 Reader_flow.single_read 버그 —
  두 번째 이후 partial delivery를 청크 offset 0에서 복사해 바이트 반복+손실.
  테스트 파일 헤더(1–17행)가 이를 명시: "pins the contract masc depends on,
  whichever version is linked must pass it", 와이어 증상은 SSE 프레임 자기반복
  → sse/malformed_payload (masc#28761).
- 재현 로그: 01-body-flow-attribution.log (head=86ea7a8, exit=1, 1 failure/3 tests,
  buffer-100 케이스만 실패)
- 판정: 결함 소재는 업스트림 라이브러리. 수리 경로는 별도 task.

---

## 결론

- red #2: 9dcf59e(PR #35234)가 유입, keeper_librarian_runtime.ml:364가 유일 소비자.
  경계 스캐너는 올바르게 위반을 감지했고, 수리는 스캐너 허용 추가(안 B) 또는
  librarian 내부화(안 C). 별도 task 권장.
- red #1: cohttp-eio 6.2.1 업스트림 버그. 별도 task 권장.
- 본 task는 귀속 산출물을 남기고 종결.
