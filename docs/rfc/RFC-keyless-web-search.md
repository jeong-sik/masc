---
rfc: "keyless-web-search"
title: "API 키 없이도 검색되게 — keyless 최후 수단 provider"
status: Draft
created: 2026-10-14
updated: 2026-10-14
author: muse
related: ["0189", "0383"]
---

# API 키 없이도 검색되게 — keyless 최후 수단 provider

## 문제

`masc_web_search`의 provider 체인(`lib/tool_misc_web_search.ml`
`provider_has_credentials`)은 6개 provider 전원에게 키 또는 셀프호스트
URL을 요구한다.

- Searxng → `MASC_SEARXNG_URL`
- Brave / Brave_llm_context → `BRAVE_SEARCH_API_KEY`
- Tavily → `TAVILY_API_KEY`
- Exa → `EXA_API_KEY`
- Bing_api → `BING_SEARCH_API_KEY` / `AZURE_BING_SEARCH_API_KEY`
- Ollama → `OLLAMA_API_KEY`

키가 하나도 없으면 체인이 비고, 이는 명시적 설정 실패
(`Dependency_unavailable`: no configured provider)로 끝난다. 즉 지금의
웹 검색은 "API 키를 갖고 있다"를 전제로 하며, 키 없는 설치에서는
검색 자체가 죽는다. `masc_web_fetch`은 이미 keyless(curl 직접 fetch)
이므로 검색 쪽만 이 전제에 갇혀 있다.

## 목표

- 키가 하나도 없는 설치에서도 `masc_web_search`가 최후 수단으로
  결과를 돌려준다.
- 키가 있으면 기존 체인 동작이 그대로 유지된다. keyless 경로는
  keyed 경로를 절대 앞지르지 않는다.
- 실패는 기존 실패 분류(RFC-0189)를 그대로 탄다. 새 실패 모양을
  만들지 않는다.

## 비목표

- 멀티벤더 익명 링 로테이션(Hermes식 keyless ring). 벤더별 ToS
  검토가 선행되어야 하며 후속 연구로 남긴다.
- SearXNG 공개 인스턴스 하드코딩. 신뢰성·남용 문제로 채택하지 않는다.
- 브라우저 기반 fetch. JS 페이지는 기존 브라우저 경로가 담당한다.

## 설계

### 새 variant

닫힌 `provider` 합타입에 8번째 variant를 추가한다(가칭
`Duckduckgo`). `provider_has_credentials Duckduckgo = true` 상시 —
자격 증명이 개념상 존재하지 않으므로 gating 함수가 물을 것도 없다.

### 편입 조건

`Duckduckgo`는 **credentialed provider가 하나도 없을 때만** 기본
순서의 맨 마지막에 들어간다. 운영자가 명시 설정한 순서의 실패는
지금처럼 정직하게 실패한다(헌법 `failure_keeps_evidence`: 실패가
상태를 조용히 진행시키지 않는다). 즉 keyless는 "설정 없음"의
구제책이지, "깨진 설정"의 은폐책이 아니다.

### 파서 계약

엔드포인트: `GET lite.duckduckgo.com/lite/?q=<query>` (키 없음,
HTML 응답). 기존 파서들과 동일한 계약을 따른다:

- 결과 링크는 `//duckduckgo.com/l/?uddg=<pct-encoded target>`
  리다이렉트 래핑이므로 `uddg`를 추출·pct-decode한 뒤
  `valid_search_result_url`로 거른다.
- 제목이 비어 있으면 버린다. 스니펫 HTML은 기존
  `clean_search_text` 파이프라인으로 정리한다.
- 빈 결과 배열이 명시적일 때만 `Ok []`. 그 외 파싱 실패는
  `Error (Parse _)`로 기존 `provider_errors`에 합류한다.
- 전송 실패·비-200은 각각 `Transport` / `Server`로 합류한다.

공식 API가 아닌 비공식 HTML 경로임을 코드 주석과 사용자 문서에
명시한다. 마크업 변경·rate-limit는 `Parse`/`Transport` 실패로
관측되며, 체인에 다른 provider가 없으면 지금의 빈-체인 실패와
같은 자리에서 실패한다(구제책의 실패는 조용하지 않다).

### 캐시·속도제한

기존 per-query 캐시와 속도제한 파이프라인을 그대로 탄다.
provider별 분기 없이 `search_impl`을 통과하므로 새 상태 셀이나
설정 키를 만들지 않는다. 새 환경변수도 만들지 않는다(헌법
`env_var_sprawl` 금지).

## 선행 사례

- OpenClaw `duckduckgo` provider: `requiresCredential: false`,
  `envVars: []`, `autoDetectOrder: 100`(맨 마지막). "Free web
  search fallback with no API key required"라는 같은 자리다.
- Hermes Agent: `DDGS`(DuckDuckGo, 키 없음) 백엔드와, cred 0
  설치에서 익명 엔드포인트 링으로 돌아가는 keyless 폴백. 링
  방식은 본 RFC의 비목표로 둔다.
- DDG lite 응답 실측: 결과 7건 내외의 HTML, `uddg` 래핑 링크,
  지역·시간 필터 폼 포함. 파싱 가능함을 확인했다.

## 테스트 전략

- `simulate_for_test`에 기존 `` `Brave_body ``와 같은 자리의
  `` `Duckduckgo_body `` 케이스를 추가해, 고정 HTML 바디를 실제
  파서 경로로 흘려보낸다. 새 snapshot 검사 발명이 아니라 기존
  패턴의 재사용이다.
- gating 단위 검사: 키 0개 환경에서 기본 순서가 `[Duckduckgo]`
  단일이 되는지, 키 1개 환경에서는 keyless가 끼지 않는지.
- 실측 probe(수동, 구현 PR에서 1회): 키 없는 환경에서 probe
  질의 1건 이상 hit. 결과는 게시판 검증 노트로 남긴다.

## 구현 단계

1. 본 RFC 합의 (게시판 결정 요청 3건 해소).
2. `provider` variant + gating + fetcher + 파서 구현 PR
   (스택 위층, source review).
3. 테스트·문서(사용자 매뉴얼의 "키 필요" 서술 갱신) PR.

## 게시판 결정 요청

1. 엔드포인트: `lite` vs `html` — `lite` 권장(이미 실측, 가벼움).
2. rate-limit 대응: 실패로 관측하고 끝낼지, 재시도 정책을 둘지 —
   재시도 없이 실패 관측 권장(헌법 `budget_gate` 금지와 같은 뿌리:
   숫자로 흐름 제어를 만들지 않는다).
3. 링 로테이션 deferral 동의 여부.
