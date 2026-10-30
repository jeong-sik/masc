# Librarian 완료 기록 검증 비용 근거 기록

## 공통 헤더

- 날짜(ISO8601): `2026-10-26T23:10:00+09:00`
- 작성자: `Claude Code (Opus 5.5)`
- 결정 ID: `librarian-history-validation-cost-r1`
- 적용 대상: `MASC_BASE_PATH=~/me` 의 `.masc`, main `6a2d8dd6171`
- 결정 상태: `추적 필요`

## 근거

- 항목: [근거] 서버 CPU 6~8코어의 주원인은 `consume_one` 이 매 pass마다
  보존된 history original 전부와 gate scope 전체를 다시 읽고 해시·파싱하는
  경로다. 같은 요청 본문이 세 군데에 저장된다.
- 출처: [실측 기록](2026-10-26-librarian-history-validation-cost-r1.md),
  `lib/keeper/keeper_librarian_durable_execution.ml`,
  `lib/keeper/keeper_librarian_durable_commit.ml`,
  `lib/keeper/keeper_librarian_original_gate.ml`,
  `lib/lane_addon/lane_addon_tool_request_owner.ml`,
  `lib/lane_addon/lane_addon_store.ml`
- 확인일시: `2026-10-26T22:21:00+09:00` ~ `2026-10-26T22:50:00+09:00`
- 신뢰도: `High` 호출 경로·데이터 중복·CPU 사용량. `Medium` pass 비용
  모델(코드 경로와 마이크로 벤치로 센 하한). `Low` 상수배 개선의 실제 효과.
- 제한조건: 한 장비, 한 base path, 한 바이너리. pass 시간은 직접 재지 못했다.

- 항목: [근거] 외부 시스템은 내용 전체 확인을 데이터가 들어올 때와 따로 돌리는
  점검에 두고, 일상 경로에서는 stat이나 digest로 바뀌었는지만 본다.
- 출처: git racy-git, Bazel #18101, Nix `--check-contents`, restic `check`,
  OpenZFS Checksums, PostgreSQL 18 `recovery_init_sync_method`,
  Build Systems à la Carte(JFP 2020) §2.1·§5.2, Salsa Durability,
  RFC 9162 §2.1.4. 링크는 [연구 문서](../../research/2026-10-26-librarian-history-validation-cost-r1.md#출처)에 있다.
- 확인일시: `2026-10-26T22:30:00+09:00` ~ `2026-10-26T23:00:00+09:00`
- 신뢰도: `High` 1차 문서를 직접 읽은 항목. `Medium` APFS 사용자 데이터
  checksum 부재(2차 출처).
- 제한조건: 사례마다 신뢰 모델이 다르다. masc에 그대로 옮길 수 있는지는
  RFC에서 따로 판단한다.

- 항목: [근거] 설계 문서는 이 비용을 캐시·상한으로 숨기지 말라고 정하고,
  다시 필요 없는 original을 목록에서 빼는 `settle` 을 둔다. Librarian은
  `settle` 을 부르지 않는다. 호출자는 Workspace Curator 하나다.
- 출처: `docs/design/addon-original-request-discovery.md`("No new cache, size
  cap or retry loop hides that cost.", "The caller settles only originals no
  pass needs again and whose body no other record names."),
  `docs/design/librarian-addon-execution.md`,
  `lib/server/server_workspace_memory_addon.ml` 의 `settle_original_with`,
  `rg '(Owner|Retained|Lane_addon_tool_request_owner)\.settle\b' lib bin` 결과 1건
- 확인일시: `2026-10-27T00:20:00+09:00`
- 신뢰도: `High`
- 제한조건: Librarian original을 언제 옮겨도 되는지는 정하지 않았다.

- 항목: [근거] gate 요청의 `capture` 와 history 기록의 `preparation_intended`
  사본은 같은지 비교하는 데만 쓰인다. gate 평가는 실행 기록에서 복원한
  요청으로 입력을 계산하고, worker 인자에는 사본이 들어가지 않는다.
- 출처: `lib/keeper/keeper_librarian_original_gate.ml`(`gate_request`,
  `load_parent`, `validate_successor_request`, `restore_record`,
  `root_preparation`, `continue_captured` 호출), 독립 검토 보고
- 확인일시: `2026-10-27T00:20:00+09:00`
- 신뢰도: `High` 사용처 목록. `Medium` "다른 사용처 없음"(검색 기반).
- 제한조건: 저장 형식을 바꾸는 효과는 실측하지 않았다.

## 검증

- 1차: 누적 CPU 시간 차이, `sample`, memprof로 원인 경로를 좁혔다.
- 2차: 소스에서 호출 경로를 읽었다. 저장 파일을 읽어 세 곳의 크기와 내용이
  같은지 확인했다(capture 3,370,525 바이트, 본문 sha256 = `request_digest`).
- 3차: 마이크로 벤치를 세 번 돌려 최솟값을 썼다.
- 재현 결과: Keeper별 history 기록·history 본문·gate 본문 합계가 같다
  (161/161/161 MB, 236/236/236 MB 등).

## 불확실성

- 미확인 항목: 실제 pass 시간, #46143 적용 뒤 측정, Librarian original을
  `settle` 해도 되는 상태 조건, 처리 안 한 턴이 줄지 않는 원인.
- 영향: 모델 숫자를 측정값처럼 인용하면 효과를 크게 또는 작게 볼 수 있다.
- 추가 확인 필요: pass 관측 로그를 넣고 #46143 전후를 같은 방법으로 잰다.

## 적용범위

- 영향 받는 영역: completed-history Librarian, Lane Add-on tool-request 저장소.
- 제약/배제: 이 기록은 코드와 런타임 데이터를 바꾸지 않았다.
- 롤백 조건: 해당 없음(조사 기록).
