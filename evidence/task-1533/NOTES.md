# task-1533 — 별개 red 2건 원인 규명 (root-cause-first 결과)

- task: task-1533 (우선순위 3), 브랜치 polish/task-1532-audio-expectation에서 규명 실행
- 기준: origin/main 8c8b9ee (2026-09-12 실측)

## red #2 — "exact-output boundary violation: admission_error_reason accessor 노출"

- **유입**: #35234 (9dcf59e, fix(librarian): 슬롯 하나의 projection 실패가 exact
  레인 전체를 죽이지 않게 한다). pickaxe `git log --all -S 'val
  admission_error_reason' -- exact_output.mli` → 9dcf59e 단일 유입.
  9dcf59e는 HEAD(16ac22c)의 조상임을 `merge-base --is-ancestor`로 확인.
- **위반 지점**: packages/agent_core/scripts/check-exact-output-resolver-boundary.sh
  `scan_public_error_accessors` — `val (target_selection_error|wire_admission_error|
  admission_error)_*` accessor를 금지하며 `*_disposition`만 허용.
  exact_output.mli:481 `val admission_error_reason : admission_error -> string`이
  이에 걸림(정당한 경계 스캔).
- **핵심 사실 — 죽은 export**: 저장소 전역 검색 결과 `admission_error_reason`의
  호출처는 **0건**(exact_output.ml:948의 구현 자체와 956행에서 wire reason을
  문자열로 쓰는 것뿐; 다른 모듈·테스트 소비자 없음). #35234가 accessor를 노출만
  하고 소비자를 남기지 않았다.
- **판정**: 결함 아님(동작 아님) — 경계 위반 **가드의 옳은 발화**, 유일한 실수는
  소비자 없는 accessor export. **권장 수리(안 A)**: exact_output.mli:481의
  `val admission_error_reason` 선언 삭제(구현은 내부 사용 위해 유지 — mli에서
  선언을 빼면 unbound module value 경고 없이 내부만 남는 구조).
  안 B(스캐너 허용 목록에 reason 추가)는 경계 약화라 채택하지 않음.
- **검증**: 수리 시 `bash packages/agent_core/scripts/
  check-exact-output-resolver-boundary.sh` 녹색 + `dune build @check` 녹색 필요.

## red #1 — cohttp_eio_body_flow "chunked body reaches the reader intact" (1/3 fail)

- **본질**: masc이 아닌 **cohttp-eio 6.2.1의 Reader_flow.single_read 버그** —
  두 번째 이후 partial delivery를 청크 offset 0에서 복사해 바이트 반복+손실.
  테스트 파일 헤더(1–17행)가 이를 명시: "pins the contract masc depends on,
  whichever version is linked must pass it", 와이어 증상은 SSE 프레임 자기반복
  → sse/malformed_payload (masc#28761).
- **재현**: 로컬 opam 스위치 **cohttp-eio 6.2.1** 설치 확인(01 로그).
  `dune exec .../test_cohttp_eio_body_flow.exe` → "1 failure! in 0.001s.
  3 tests run." exit=1 (buffer 100 케이스만 실패 — 버퍼가 청크보다 클 때는
  partial delivery가 없어 통과).
- **판정**: 결함의 소재는 업스트림 라이브러리. 수리 경로는 ①opam 패키지 업그레이드
  (cohttp-eio >= 6.2.2+ 수정본 여부 확인 필요 — 현재 스위치에서 선행 조사) 또는
  ②masc 측 reader가 partial delivery를 보정하는 우회. 어느 쪽이든 **본 task의
  "원인 규명" 범위를 넘는 독립 수리**라 별도 task로 갈음.

## 결론

- red #2: 안 A(481행 export 삭제)로 즉시 수리 가능 — 소비자 0건 확인됨.
- red #1: cohttp-eio 6.2.1 업스트림 버그(테스트 헤더가 이미 문서화) —
  버전 확인 후 업그레이드 또는 별도 결정 필요.
- 본 task는 규명 산출물만 남기고 종결하며, 수리는 각각 별도 task 권장.
