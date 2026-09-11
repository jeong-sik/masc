# task-1491 evidence NOTES (rev.3, 2026-09-11 ~17:10Z)

- 게스트 생존 재확인: 16:0xZ Execute `alive` OK(HEAD 84e37b8 동일) — vrf-f9a1e231의
  `microvm_guest_not_running` 조회 실패는 검증자 표면 장애였음이 이후 실측으로 확인.
- 앵커: 로컬 8스위트 로그 전부 1행 `HEAD=84e37b836e1e107ec6cda664e029a77669e93c72`.
- CI targeted run 34623835070은 dispatch 경합으로 main tip **c197fe5**에서 실행
  (= 84e37b8 + 3cc9e11(#35155) + c197fe5(#35244), 사이 test/ 커밋 없음) — ci-targeted-run.log 참조.

## 8스위트 상태 (계약 nightly 세트)

| # | 스위트 | 로컬 @84e37b8 | CI @c197fe5 |
|---|---|---|---|
| 01 | test_keeper_tool_schema_bytes | 3 green(ceiling·surface golden 포함) | — |
| 02 | test_tools_coverage | 35 green | — |
| 03 | test_keeper_system_prompt_bytes | 2 green | — |
| 04 | test_keeper_tool_matrix | FAIL: `ENOENT create_process "docker"`(레인에 docker 부재, fixture 이미지 빌드 시도) | FAIL(016 keeper_artifact_transfer·089–093 masc_lane — main tip 상속 빨강) |
| 05 | test_keeper_tool_dispatch_runtime | FAIL: production browser JS fixture(브라우저 부재) | **OK**(게이트급 녹색) |
| 06 | test_mcp_tool_matrix | FAIL: `/tmp/masc-runtime/.masc/agents` Permission denied mkdirat(root 소유, 17:08 생성 — telemetry 계열 동일 서명) | FAIL(동일 main-red 계열) |
| 07 | test_keeper_tool_matrix_cases | FAIL: 06과 동일 masc-runtime permission | (targeted 세트 미포함) |
| 08 | test_mcp_tool_matrix_cases | FAIL: 06과 동일 masc-runtime permission | (targeted 세트 미포함) |

- 로컬 5개 실패의 3계열 환경 귀속: ①root 소유 /tmp/masc-runtime mkdirat denied
  (unmodified main에서도 동일 — telemetry 사가와 동일 클래스) ②docker ENOENT
  ③browser fixture 부재. 본 task는 코드 변경 0건이므로 위 red·green 어느 쪽도
  본 task 변경과 무관하며, main tip red는 84e37b8 이후 착지 커밋(#35155·#35244)이
  유일한 코드 변화(1차 귀속은 본 task 범위 밖, 참고 기록).

## vrf-f9a1e231 3결함 대응

1. 영수증 결손(8종 중 3개, system_prompt_bytes·tool_matrix·dispatch_runtime) →
   8개 로그 전부 첨부 + CI 게이트급 영수증(ci-targeted-run.log).
2. 로그에 커밋 SHA 부재 → 전 로그 1행에 HEAD=84e37b8 주입, CI 런은 headSha 명기.
3. golden 갱신 커밋 메시지 원문 부재 → git-log-golden-commits.log(4,162B,
   7e94cf0 #35237·396ff36 #35121·f9b7fef #35129 전문).

## 결론 (변경 없음)

84e37b8 시점 golden 목록·byte-ceiling은 이미 정합(01 녹색 + 멤버십 grep +
갱신 3커밋 메시지 원문). 본 task = 조사 성격, 코드 변경 0건, PR 없음.
