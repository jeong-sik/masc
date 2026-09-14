# task-635 (#26058 / PR #36032) 검증 증거 묶음

생성: 2026-09-14T03:05Z (구양봉) — 소유자 3차 리뷰(5192723206) 수리 후 재실측.
HEAD: eb44424a 이후 수리 커밋(단축 제거 + dead code 복구 + Unavailable 복원).

## 소유자 3차 리뷰(5192723206, 23:26:52Z) 수리 내역

1. **단축 제거** — `Observed_refused`는 이제 모든 network_mode에서 판정자에게 간다.
   근거: "N"/"W" ack는 박스 **설치 실패**(박스 미적용)이지 **시도 차단**이 아니다.
   `Socket_denied ∧ Network_none → 판사 없이 허용` 분기 삭제.
2. **dead code 복구** — `Bytes.to_string`(8바이트 그대로) → `Bytes.sub_string refusing_rule 0 6`.
   이제 "socket"/"write"가 실제로 매치되어 "N"/"W" ack가 나간다.
3. **Unavailable 의미 복원** — `Refused | Unavailable` 합병 해제.
   `Unavailable` → `Observation_unavailable "enforced_box_not_acknowledged"`(박스 적용 모름).
4. 단축 신설(seccomp user_notif/audit 관찰 경로)은 **별도 PR** — 소유자 결론 그대로.

## 실행 원문 (이 디렉터리)

모두 `OCAMLPATH=$PWD/../ocaml-dos-local/_build/install/default/lib` 전제, 로컬 microvm 감옥.

- `check.txt` — `dune build @check` 출력. **exit=0** (무출력 = 통과).
- `exec_shim.txt` — `@test/runtest-test_exec_shim` 출력. **exit=0**.
- `effect_coverage.txt` — `@test/runtest-test_keeper_gate_effect_coverage` 출력.
  **exit=0, 27 tests run, Test Successful** — `network_isolation (task-635, #26058)` 2케이스 [OK]
  (Observed_refused 전 모드 판정자 유지 / Observation_unavailable 전 모드 판정자 유지).
- `readonly.txt` — `@test/runtest-test_keeper_gate_readonly` 출력. **exit=0**.

## 상위 증거 (등기면 좌표)

- 소유자 3차 review 5192723206(23:26:52Z, `jeong-sik`, head=eb44424a57, CHANGES_REQUESTED).
- 내 수리 등기 코멘트 c-9ea2d16d(02:11Z, p-1796f1ba) — 3개 지적 수용 + 다음 행동 제안.
- PR 코멘트 5656617354(22:31:33Z): 소유자 2차 리뷰 이행 보고.

## done 제출 시 evidence_refs 계획

(형식 근거: task-634 AUDITED APPROVED 선례 — playground-root 상대경로 `masc/` 접두 필수)

artifact:masc/evidence/task-635/check.txt · artifact:masc/evidence/task-635/exec_shim.txt ·
artifact:masc/evidence/task-635/effect_coverage.txt · artifact:masc/evidence/task-635/readonly.txt ·
artifact:masc/evidence/task-635/manifest.md · board:p-1796f1ba1f64099a526754311e6bbd9f ·
note: PR #36032 수리 커밋 좌표 + 소유자 3차 리뷰 5192723206 수리 내역 + 제출 시점 gh 직독.
