# Audit Responses

이 디렉터리는 외부 코드 audit(deep-review CI, 외부 모델 리뷰, 사람 리뷰 등)에 대한
**verification matrix + 분류 근거 + 해소 PR 링크**를 보관합니다. 다음 audit이 같은
false positive를 다시 내지 않게 하는 audit memory 역할을 합니다.

## 왜 필요한가

외부 audit은 codebase의 **현재 상태와 의도된 설계**를 모를 때가 많습니다. 특히:

- 의도적 architectural decision(예: passthrough, deferred execution)을 "버그"로 분류
- 이미 fix된 항목을 stale snapshot 기준으로 다시 보고
- caller-context 없이 grep만으로 "사용 안 됨" 결론

내부 MEMORY에 따르면 외부 audit "Critical" 항목 중 **30~67%가 stale 또는 misread**.
같은 audit 시리즈가 반복될 때마다 verification에 동일한 시간을 다시 쓰는 것은
낭비이고, 문서화로 한 번 끊어두면 다음 audit이 이 디렉터리를 먼저 읽고 검증된
항목을 제외할 수 있습니다.

## 절차

외부 audit 받으면:

1. **Verification matrix 작성**: 각 클레임을 (A) verified bug, (B) intentional design
   that audit misread, (C) partial truth, (D) stale 로 분류. 30-50줄의 caller-context
   인용 + 분류 근거(`.mli` 인용, RFC 번호, commit hash) 첨부.
2. **본 디렉터리에 commit**: 파일명 형식 `YYYY-MM-DD-<short-topic>.md`. 예:
   `2026-05-05-dashboard-heuristic.md`.
3. **(A) 항목만 PR로 연결**: (B)는 코드 코멘트 + audit-response cross-reference로
   audit memory를 강화. (C)는 사용자 의사 확인 후 별도 처리. (D)는 commit 링크만
   기록.
4. **Audit-response 문서가 직접 가리키는 코드 위치**에 한 줄 코멘트 추가:
   ```ocaml
   (* See docs/audit-responses/YYYY-MM-DD-<topic>.md §N. *)
   ```
   이렇게 두면 다음 reviewer가 코드를 보다가 audit-response로 진입할 수 있습니다.

## 작성 시 가이드라인

- 각 클레임의 분류는 **읽는 사람이 검증할 수 있어야** 함. 즉 file:line + 인용 +
  caller-context를 빠짐없이 적습니다. "stale"로 분류했다면 fix commit hash를
  명시.
- 분류 (B)는 audit이 misread한 이유까지 적습니다. 단순히 "intentional"로 끝내지
  말고 "[file].mli §X에서 deferred 명시" 같은 구체적 reference.
- 분류 (D)는 fix commit + 머지 날짜 + 검증 방법(test/grep)을 같이 적습니다.

## 기존 응답

(시간순)

- `2026-05-05-dashboard-heuristic.md` — deep-review CI의 dashboard / heuristic_metrics
  / admission_queue / resilience / cancellation / local_runtime_pool / bounded /
  llm_metric_bridge / lockfree_atomic 9개 영역 24개 클레임 매트릭스.
- `2026-05-05-integrated-improvement-design.md` — INTEGRATED_IMPROVEMENT_DESIGN.md
  의 4-phase × 18 action item (16→36 keeper 확장 통합 재설계) 매트릭스. 정량
  클레임 70%가 stale 또는 active 트랙과 중복; 진짜 design idea(생성 CLI/API,
  N+1 batch, 3-Tier disclosure, env unification)는 RFC-0029~0032 후보로 분리.
