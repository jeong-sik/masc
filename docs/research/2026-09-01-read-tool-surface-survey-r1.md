# 읽기 도구 표면 조사 — 6개 하네스 코드 레벨 대조와 keeper_artifact_read 판정

## 왜 조사했나

수정 7건 배포(2026-09-01 22:14) 후 65분 창 실측에서 남은 fanout 79건 중 46건이
`keeper_artifact_read`였다. 로그를 열어 보니 한 keeper(code-reviewer)가 11,721바이트
blob을 `max_bytes=500`으로 24왕복에 걸쳐 순차 페이징하고 있었다. 도구 기본값은
65536(=상한)이라 한 호출이면 끝났을 읽기다. 응답에는 `total_bytes`와 `next_offset`이
이미 있었고, 모델은 설명 문구("continue with the returned next_offset")가 가르친
프로토콜을 그대로 따랐다. 배경: `2026-09-01-tool-roundtrip-waste-r1.md`.

같은 문제를 기성 하네스 6개가 어떻게 푸는지 코드 레벨로 조사했다.

## 결과 — 6개 하네스 대조

| 하네스 | 읽기 페이지 기본/최대 | 잘림 시 모델에게 주는 것 | 완독 vs 페이징 독트린 |
|---|---|---|---|
| Claude Code | 기본 = 통째 (256KB / 25K 토큰 한도) | 자르지 않고 에러로 거절, 에러에 총량+한도 명시 | "read the whole file" (기본 변형) |
| Codex | 전용 read 없음(shell), skills.read 페이지 512KB | 원 토큰수 + 총 줄수 + 중간 생략 마커 | "선택한 파일은 부분 읽기 말고 완독, 페이지네이션되면 next_cursor를 EOF까지" |
| pi | 2000줄/50KB — 기본이 곧 최대 | `[Showing lines A-B of TOTAL. Use offset=N to continue.]` | "전체가 필요하면 offset으로 끝까지"; partialRate를 자체 스크립트로 측정·최소화 |
| Hermes | 2000줄/100K chars — 기본이 곧 최대 | 구조화 `next_offset` 필드 + 총 줄수 든 hint; 같은 구간 4회 재읽기는 BLOCKED 에러 | 기본=최대, 페이징은 복구 수단 |
| OpenClaw | pi를 재수출 (2000줄/50KB) | pi와 동일 | 시스템 프롬프트를 통째 교체해서 읽기 전략 신호가 도구 설명 하나뿐 |
| Orca | 커서 프로토콜 전용 (미리보기 120줄, 커서 읽기는 최대 기본) | `limited`(이어 읽기 가능) vs `truncated`(소실) 구분 + 다음 커서 명령 문장 | 터미널 스트림 특성상 페이징 설계 (파일 읽기와 다른 문제) |

### 수렴점 (터미널 스트리밍인 Orca 제외 5개)

1. **기본값이 곧 최대값** — 인자 없는 호출이 통째 읽기다. 작은 페이지를 기본으로
   두는 하네스는 없다.
2. **페이징은 복구 수단** — 설명은 완독을 기본으로 말하고, offset은 "큰 파일일 때"
   로만 안내한다. Codex skills 독트린이 가장 명시적: "progressive disclosure는
   파일 선택에 적용되지, 선택한 파일의 부분 읽기가 아니다."
3. **잘림 응답이 다음 호출을 받아쓸 수 있게 한다** — 총량과 다음 offset을 계산해서
   문장으로 준다(pi/Hermes). 이번 주 enum 에러 수정(#32326)과 같은 원리.
4. **재읽기 낭비를 코드가 막는다** — Claude Code와 Hermes 모두 "파일이 안 변했으면
   이전 결과를 참조하라"는 dedup 응답을 갖고, Hermes는 4회째 반복 읽기를 에러로
   차단한다. `keeper_tasks_list` unchanged 수정(#32322)과 같은 사상.

### 반면교사

- Claude Code #21841 실측: 초과분을 잘라서 주는 것보다 총량을 알려주는 에러로
  거절하는 쪽이 쌌다(잘린 내용 ~25K 토큰 vs 에러 ~100바이트). 잘림을 "친절"로
  설계하면 안 된다.
- OpenClaw 자체 exec는 200K 캡을 마커 없이 tail만 남긴다 — 모델이 잘린 사실
  자체를 모른다. silent failure의 교과서 사례.
- Claude Code의 "2000줄 기본" 문구는 코드에서 강제되지 않는다(실제 한도는
  바이트/토큰). 설명과 코드가 어긋나면 문구가 곧 결함이 된다 — 이번
  keeper_artifact_read 사건과 같은 구조.

## masc 판정

- 실행기는 이미 옳다: `Keeper_artifact_read.page_of_slice_within_output_budget`이
  JSON 봉투 64KiB 예산에 맞는 최대 content를 이진 탐색으로 채운다 — Codex
  skills.read의 `page_response`와 동형 알고리즘.
- 응답도 이미 옳다: `total_bytes`, `next_offset`, `eof`를 모두 준다.
- 모델이 만나는 blob은 대부분 작다: 생성 시 blob 격상은 64KiB 초과뿐이지만,
  히스토리 강등(RFC-0363)이 오래된 tool result를 크기와 무관하게 blob 마커로
  바꾼다. 라이브 중앙값 2,862바이트(`keeper_model_input_demotion.mli`).
- 결함은 설명 문구 하나: "Use the marker's sha256, then continue with the returned
  next_offset"이 순차 페이징을 정식 프로토콜로 가르쳤다.

## 변경 (이 PR)

`config/tools/keeper_artifact_read.toml` 설명을 수렴점 1·2에 맞게 재작성:
마커의 `bytes=`가 총 크기, 기본 max_bytes가 상한이라 한 호출이 대부분을 통째로
돌려준다, 완독이 기본이고 `eof=false`일 때만 `next_offset`으로 잇는다.
`test/test_keeper_runtime_schemas_toml_parity.ml`의 바이트 pin을 함께 갱신.

## 후속 후보 (이 PR 범위 밖)

- 반복 읽기 차단: Hermes의 3회 경고 / 4회 차단, Claude Code·Hermes의
  unchanged-dedup 응답. `keeper_artifact_read`는 sha256이 내용 주소라 같은
  (sha256, offset, max_bytes) 재호출 탐지가 특히 싸다.
- 측정기 보정: `github_pull_request_read`처럼 `method` 필드로 다중화된 도구는
  `input.method`를 서브툴로 봐야 probe 오탐이 사라진다
  (`scripts/measure-tool-roundtrips.py`).
- 스크립트 제출형 합성(Hermes PTC, Codex code-mode)은 기존 결론 유지 —
  `keeper_plan_execute` 0/368 사망 실측이 있어 RFC 없이 재도입하지 않는다.

## exact identity

- masc 기준 커밋: 069a90409b (`fix/artifact-read-single-call-norm` 분기점)
- 조사 대상 사본: Claude Code 261739a(로컬 재구성 트리), Codex 2b7c279,
  Hermes 5a8e8a6, pi a63fb12, Orca dff2ff0e (이상 일회용 얕은 클론),
  OpenClaw b4e2e74 (+ 전역 설치 `@mariozechner/pi-coding-agent` 0.52.7)

## 재측정

배포 후 `scripts/measure-tool-roundtrips.py`로 fanout 중 `keeper_artifact_read`
연속 실행 수와 blob당 호출 수(65분 창 실측: blob 8개에 54호출, 최대 20호출)를
다시 잰다. 성공 기준: blob당 호출 수가 페이지 산수(⌈bytes/65536⌉) 근처로 수렴.
