---
rfc: "0383"
title: "웹 아티팩트는 쌓이기만 한다 — 오프로드 파일을 재질의 가능한 코퍼스로"
status: Draft
created: 2026-08-16
updated: 2026-08-16
author: vincent + claude
supersedes: []
superseded_by: null
related: ["0381"]
---

# RFC-0383: 웹 아티팩트는 쌓이기만 한다

## 0. Summary

RFC-0381이 만든 오프로드 경로는 검색·추출 전문을
`<base>/.masc/artifacts/web-fetch/<sha256>.md`에 내용 주소로 저장한다. 첫 keeper 턴
실측에서 검색 1회가 파일 3개(80KB)를 만들었고, keeper는
`keeper_artifact_read(sha256, offset, max_bytes)`로 필요한 조각만 되읽었다
(→ §6 정정: 그때 되읽힌 것은 자동 blob화된 tool result였고, 이 경로의 파일
자체는 keeper reader가 도달할 수 없는 저장소에 있었다. 본문 저장은 #28820에서
`Tool_blob_store`로 단일화됐다).

문제는 이 파일들이 **익명**이라는 것이다. sha256 파일명만 있고 — 어떤 URL에서 왔는지,
언제 가져왔는지, 어떤 제목의 문서인지를 파일 시스템 어디에도 기록하지 않는다. 그 결과:

1. keeper가 같은 주제를 다시 조사할 때 이미 가진 본문을 **재활용할 수 없다**
   (sha256을 알 방법이 없으므로) — 같은 웹 왕복을 반복한다.
2. 운영자가 보존 정책(#28759)을 설계할 근거 데이터(무엇이 언제 왜 저장됐나)가 없다.
3. 축적이 자산이 아니라 그냥 디스크 사용량이다.

이 RFC는 오프로드 시점에 **한 줄의 사실**을 append-only 인덱스에 남겨, 아티팩트
디렉터리를 "검색할수록 축적되는 로컬 코퍼스"로 바꾼다. 새 도구·새 게이트·새 상태 없이.

## 1. 원칙 → 설계 강제

| 원칙 | 이 RFC에서의 강제 |
|---|---|
| Ledger는 evidence authority | 인덱스는 **projection**이다. 진실은 아티팩트 파일 자체(내용 주소)이고, 인덱스 행은 "그 시각에 이렇게 저장했다"는 사실 기록. 인덱스가 유실·손상돼도 아티팩트 읽기는 그대로 동작한다 |
| 행동을 유도·강제하는 장치 금지 | 신선도 필드(`fetched_at`)는 사실이다. 만료·TTL·재검증을 **강제하지 않는다** — 오래된 본문을 쓸지 다시 가져올지는 Keeper가 선택한다 |
| Gate 0 | 어떤 경로에도 새 gate가 없다. 인덱스 append 실패는 오프로드 성공을 실패로 바꾸지 않는다(아래 §2.4) |
| 도구 표면 최소 | **새 keeper 도구를 추가하지 않는다.** 인덱스는 JSONL 파일이고 keeper는 이미 Grep/Read를 가진다 — 파일 계약을 문서화하면 소비 표면은 이미 존재한다 (→ §6 정정: keeper sandbox는 `.masc`를 파일 표면으로 주지 않아 이 전제는 agent/운영자 레인에서만 성립한다) |
| 레거시 금지 | 인덱스 스키마는 v1 단일. reader/converter/migration 없음. 스키마가 바뀌면 hard cut |
| SSOT | URL→내용 매핑의 진실은 웹이다. 인덱스는 "우리가 관측한 시점의 사실"만 기록하며, 같은 URL의 다른 시점 관측은 서로 다른 행(그리고 대개 다른 sha256)이다 |

## 2. 설계

### 2.1 인덱스 파일

경로: `<base>/.masc/artifacts/web-fetch/index.jsonl`
형식: append-only JSONL, 행당 하나의 오프로드 사실.

```json
{"schema":"masc.web_artifact.v1","sha256":"2dd3ef61…","source_url":"https://lewinb.net/posts/…","title":"Playing with OCaml Effects","bytes":36909,"fetched_at":"2026-08-15T18:08:02Z"}
```

| 필드 | 의미 |
|---|---|
| `schema` | `masc.web_artifact.v1` 고정 |
| `sha256` | 아티팩트의 내용 해시(= `Tool_blob_store` 주소, §6) — `keeper_artifact_read`의 첫 인자 |
| `source_url` | 추출 원본의 최종 URL (리다이렉트 해소 후) |
| `title` | 추출된 `<title>` (없으면 필드 자체 생략 — null 저장 금지) |
| `bytes` | 오프로드된 전문 크기 |
| `fetched_at` | 오프로드 시각 (UTC ISO8601) |

같은 sha256이 다시 오프로드되면(동일 내용 재획득) **행을 또 쓴다** — "그 시각에도
그 URL이 그 내용이었다"는 독립된 관측 사실이고, dedup은 파일 계층(내용 주소)이 이미
해결했다. 인덱스는 로그이지 테이블이 아니다.

### 2.2 소비 계약 (도구 추가 없음)

keeper는 기존 도구로 코퍼스를 쓴다:

```
Grep(path=<base>/.masc/artifacts/web-fetch/index.jsonl, pattern="effect handlers")
  → 행에서 sha256과 fetched_at을 얻는다
keeper_artifact_read(sha256=…, offset=0, max_bytes=…)
  → 본문. RFC-0381의 OUTLINE 지도(절단 마커)와 같은 주소 체계
```

행이 가리키는 파일이 없을 수 있다(운영자가 지웠거나) — `keeper_artifact_read`가
이미 그 실패를 정직하게 반환하므로 인덱스 쪽에 존재 보장 장치를 만들지 않는다.
projection은 힌트이지 계약이 아니다.

### 2.3 쓰기 지점

오프로드 성공 직후 한 곳(`Tool_misc_web_fetch.offload_full_text`의 성공 경로 인근)에서
append한다. 필요한 입력(`source_url`, `title`)은 호출자(handle/enrichment)가 이미
갖고 있으므로 시그니처로 전달한다. 쓰기는 O_APPEND 단일 `write`로 행 단위 원자성을
얻는다(동시 오프로드 교차 시에도 행이 섞이지 않는 크기 범위).

### 2.4 인덱스 append 실패의 처리

오프로드는 성공했는데 인덱스 append가 실패하면(디스크·권한): **오프로드는 성공으로
남는다.** 전문 보존이 1차 가치이고 인덱스는 projection이다. 실패는 조용히 지나가지도
않는다 — 절단 마커에 `[index_unavailable=<reason>]` 행으로 드러난다. 기존
`full_text_unavailable` 마커와 대칭인 표면이며, 도구 계층은 로깅 무의존(로그는
dispatch 계층의 몫)이라는 기존 경계를 지킨다. 이것은 counter-as-fix가 아니다 —
잃는 것은 파생 데이터(행 하나)뿐이고 durable truth(아티팩트)는 온전하다.

## 3. 구현 범위

| PR | 내용 | 산출물 |
|---|---|---|
| PR-1 | `offload_full_text` 확장: source_url/title 전달 + index.jsonl append + Feature 테스트(절단 왕복 후 인덱스 행 존재·스키마·sha256 일치) | 코드 + 테스트 |
| PR-2 | 소비 계약 문서화: ENV-CONTRACT/QUICK-START의 아티팩트 문단에 인덱스 경로·스키마·Grep 소비 패턴 명시 | 문서 |

## 4. 명시적 비범위 (Non-goals)

- **임베딩/시맨틱 검색 없음.** BGE-M3 등은 Second Brain 인프라이고 MASC 코어의 의존
  경계 밖이다. 텍스트 Grep이 v1의 전부다. 시맨틱 계층이 필요해지면 별도 RFC로,
  MASC 밖의 소비자로서 index.jsonl을 읽는 방향이 먼저다.
- **보존·만료 정책 없음.** #28759의 주제이며, 이 인덱스는 그 정책이 설 근거 데이터를
  만드는 쪽이다.
- **검색 시점 자동 코퍼스 조회 없음.** WebSearch가 인덱스를 먼저 보고 웹을 건너뛰는
  자동화는 행동 유도 장치다 — 코퍼스를 쓸지는 Keeper의 선택으로 남긴다.

## 5. Acceptance

1. 절단을 유발하는 fetch 왕복 후 `index.jsonl` 마지막 행이 방금의 sha256·URL을 담는다
   (Feature 테스트).
2. 인덱스 파일을 지워도 fetch/read 경로의 동작이 변하지 않는다 (projection 증명).
3. keeper가 Grep→`keeper_artifact_read` 2단으로 과거 본문에 도달한다 (턴 실측, RFC-0381
   Iteration 5와 같은 방법). (→ §6: 라이브 실측에서 keeper 레인은 두 단계 모두
   실패했다 — 본문 읽기는 #28820 수정으로 열렸고, 발견 경로는 레인을 나눠 정정)

## 6. 실측 정정 (2026-08-16, #28820)

:8949 격리 인스턴스에서 acceptance를 keeper 레인으로 처음 끝까지 밟은 결과
(근거: `docs/evidence/web-artifact-corpus-acceptance-2026-08-16.md`):

- **acceptance 1은 라이브 PASS** — 절단 5건이 index 5행 + 본문 4파일을 만들었고,
  서로 다른 URL 2개가 같은 내용 해시 한 파일로 dedup되는 것까지 관측했다.
- **acceptance 3은 keeper 레인에서 양 단계 모두 불성립이었다.**
  ① keeper sandbox는 `.masc`를 파일 표면으로 주지 않아 인덱스 `Grep`이 도달
  불가(상대경로가 playground 기준으로 해석). ② 본문이
  `artifacts/web-fetch/<sha>.md`에 있었는데 `keeper_artifact_read`는
  `Tool_blob_store`(`tool_blobs/`)만 resolve한다. §0의 "되읽었다"는 관측은
  web-fetch 파일이 아니라 같은 턴의 자동 blob화된 tool result를 읽은 것이었다.

정정 내용:

1. **본문 저장 단일화 (#28820)** — `offload_full_text`가 전문을
   `Tool_blob_store.put_durable`로 저장한다. 마커는 경로 대신
   `full_text_sha256=<sha>`를 싣고, 그 sha가 곧 `keeper_artifact_read`의 첫
   인자다. `artifacts/web-fetch/`에는 `index.jsonl`만 남는다. 이전 위치의
   `.md` 파일은 reader가 없던 표면이므로 hard cut(이관 코드 없음)하며, 남은
   파일의 처분은 운영자 몫이다(#28759). 인덱스의 옛 행이 가리키는 sha가 blob
   store에 없을 수 있음은 §2의 기존 계약("행이 가리키는 파일이 없을 수 있다")
   그대로다.
2. **소비 레인 구분 (2026-08-16 확정, #28820)** — 같은 턴/checkpoint 안의
   재독은 마커 sha로 keeper 레인에서 성립한다 (라이브 실측:
   `keeper_artifact_read` outcome=ok, 06:12:22Z). 인덱스를 뒤져 sha를
   **발견**하는 교차 세션 경로는 agent/운영자 레인**만**이다 — 이것이 v1의
   최종 계약이다. 근거: sandbox 계약이 `.masc` 상태의 파일 접근을 금지하므로
   keeper 발견은 도구여야 하는데, 프로덕션 코퍼스 3행·keeper 교차 세션
   재질의 수요 관측 0건 상태에서 도구 표면을 늘리지 않는다. keeper 발견
   도구는 수요 증거(재질의 시도 실패 로그 누적)가 관측되면 그때 별도 RFC로
   제안한다 — §4 "새 keeper 도구를 추가하지 않는다"는 그 시점까지 유효하다.
