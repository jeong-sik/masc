# task-1536 evidence — exact preflight 자격증명 동결 red 수리

- task: task-1536. 브랜치 polish/task-1536-credential-freeze-red @ main tip
- 결론: **진짜 결함 — caller-supplied header 게이트와 make 기본값의 상호작용
  결함. 게이트가 make의 기본 헤더를 '호출자 공급'으로 오판해 모든 exact
  preflight를 거부. 좁은 수리 + 반례 고정 테스트로 수리.**

## 근본 원인 (원문 실측 체인)

1. Provider_config.make의 ~headers 기본값 = `[("Content-Type",
   "application/json")]` (provider_config.ml:89). 호출자가 생략하면 이
   기본값이 config.headers에 들어감 — #35091 픽스처는 ~headers를 넣지 않음
   (6ed999e7 diff 원문, fixture에 headers 인자 없음).
2. preflight 게이트(exact_output_plan.ml:433): `caller_supplied_header_name
   config.headers`가 Some이면 Caller_supplied_header_not_allowed.
3. caller_supplied_header_name(182행, 수리 전 원문): `| [] -> None
   | (name,_)::_ -> Some name` — **목록이 비어 있지만 않으면 무조건 첫 이름**.
   즉 기본값(=모든 생략 config)이 항상 거부 → **모든 exact preflight가 죽음**.
4. #35091 diff 원문(gh 개봉): auth_headers_for_config → resolve_auth_headers
   교체 + 동결 %test 추가 — **게이트는 그대로**. 게이트는 커스텀 headers
   시대의 산물이고 기본값 주입과 충돌. red가 이 하나뿐이었던 이유: preflight를
   직접 호출하는 %test가 이것뿐(게이트 검증 테스트는 원래 없었음 —
   test_exact_output_flow의 header 매치는 Http_client 경로로 무관).

## 격리 방법 (red가 `Error _ -> false`를 삼켜 위치가 안 보였음)

%test를 임시로 디버그 판정(모든 rejection 생성자 매치 + Printf.eprintf)으로
바꿔 실행 → `DEBUG-1536 reject=Caller_supplied_header_not_allowed(Content-Type)`
— 첫 prepare() 자체가 이 거부로 죽는 것이 red의 직접 원인. 이후 임시 코드는
원복(398행의 `| Error _ -> false` 원형 복원, DEBUG 흔적 0).

## 수리 (좁은 패치, exact_output_plan.ml 182행)

`caller_supplied_header_name`에 패턴 1개 추가:
`| [("Content-Type","application/json")] -> None` — make가 주입하는
와이어 소유 기본 쌍(정확히 이 튜플 하나뿐인 목록)은 설정이지 호출자 공급이
아님. 다른 모든 비어 있지 않은 목록은 종전대로 첫 헤더 이름을 반환.
근거 코멘트를 패턴 위에 명시(다음 사람이 왜 이 예외인지 볼 수 있게).

## 반례 고정 (신규 %test 1개, 계약화)

"exact preflight still rejects genuinely caller-supplied headers":
- `~headers:[("X-Custom","v")]` → Caller_supplied_header_not_allowed "X-Custom"
- `~headers:[("Content-Type","text/event-stream")]` → 같은 거부,
  reported = "Content-Type" — 커스텀 값의 Content-Type은 여전히 거부
(거부 보고 이름 일치까지 검증).

## 검증 (수정 리비전에서 — vrf-a5770991 순서 교훈)

- 커밋 직전 실측: `dune runtest --force packages/agent_core/lib/llm_provider`
  **exit=0, FAILED 0** — 이전 같은 명령은 `FAILED 1/4`(freezes refreshed
  credentials). 동결 %test + 신규 반례 %test 모두 녹색.
- 영수증: 02-at-fix-revision.log (커밋 head에서 @check + runtest 재실행)
- 남은 risk: 433행 게이트는 preflight 경로뿐 — ready_admission 경로
  (exact_output_ready_admission.ml:306의 Plan.Caller_supplied_header_not_allowed
  전파)는 동일 Plan 에러를 재사용하므로 이 수리의 수혜.

## Adversarial Review 대응 (issuecomment-5642917479)
1. 대소문자 무관 wire-default 필터링: String.lowercase_ascii (String.trim name) = "content-type" && String.lowercase_ascii (String.trim value) = "application/json"
2. 순서 무관 실제 호출자 헤더 보고: wire-default를 제외한 첫 헤더(List.find_opt)를 찾아 보고하여 [ ("Content-Type", ...); ("X-Custom", ...) ] 순서에서도 "X-Custom"을 정확히 지목.
3. 인라인 테스트 확장: empty header 허용, 대소문자 허용, 커스텀 Content-Type 거부, 와이어 기본값과 호출자 헤더 혼합 시 진원지 지목 및 순서 무관성 검증.
4. 스테이징 오염 정리: 직전 커밋에 잘못 포함되었던 evidence/task-1491/* (15개 파일) 제거.

