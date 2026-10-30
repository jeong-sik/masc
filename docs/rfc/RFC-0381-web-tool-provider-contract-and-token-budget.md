---
rfc: "0381"
title: "웹 검색은 폴백이 있는 척한다 — provider 계약 정정과 토큰 예산 도입"
status: Draft
created: 2026-08-15
updated: 2026-08-15
author: vincent + claude
supersedes: []
superseded_by: null
related: ["0189", "21228", "5610"]
---

# RFC-0381: 웹 검색은 폴백이 있는 척한다

## 0. Summary

`masc_web_search`는 7개 provider의 폴백 체인을 광고한다. 실측하면 살아있는 provider는 **하나**다. 나머지는 자격 미달로 걸러지거나(API 키 없음), 응답은 200을 주는데 결과가 0~1건이다. 즉 폴백이 존재하는 게 아니라 **폴백의 외형**이 존재한다. 유일하게 동작하는 SearXNG는 Docker 컨테이너를 요구하므로, 컨테이너가 내려가면 검색 기능은 조용히 0건으로 수렴한다.

같은 도구의 `includeContent` 경로는 본문을 **두 번** 싣는다. `results[].page_content`와 `content_text`가 같은 내용을 각각 담고, `Tool_result.message`는 payload 전체를 직렬화해 keeper에게 넘긴다.

이 RFC는 세 가지를 한다.

1. **죽은 provider를 척살한다.** 자격 없는 provider를 조용한 폴백으로 남기지 않고, 자격 미달은 `Config` 실패로 정직하게 드러낸다.
2. **검색과 추출의 백엔드를 분리한다.** 무료 검색(SearXNG)과 유료·고품질 추출을 독립적으로 고를 수 있게 한다. Hermes가 쓰는 축과 같다.
3. **토큰 예산을 도구 계약에 넣는다.** 절단을 휴리스틱이 아니라 결정론적 규칙으로 고정하고, 전문은 파일로 내보내 경로만 반환한다.

Brave LLM Context API를 **옵션 provider**로 추가한다. 기본값으로 만들지 않는다 — 키가 없는 환경에서도 제품이 서야 한다.

## 1. 원칙 → 설계 강제

| 원칙 | 이 RFC에서의 강제 |
|---|---|
| 7. 게이트 | 신규 스케줄링 게이트 0. provider 자격 판정은 이미 있는 `provider_has_credentials`를 그대로 쓴다. 추가하는 것은 게이트가 아니라 **실패의 가시화**다 — 지금은 자격 미달이 조용한 폴백으로 흡수되어 keeper가 "검색했는데 결과가 없다"와 "검색 자체가 불가능하다"를 구분하지 못한다 |
| 8. 레거시 | `Ddg`·`Bing_rss` variant를 코드에서 삭제한다. deprecated 주석·호환 reader·이중 경로를 남기지 않는다. `content_text`/`page_content` 중복도 hard cut이며 둘 중 하나만 남는다 |
| 9. 매직넘버 | 현재 흩어진 리터럴(`4_000`, `20_000`, `50_000`, `2_000_000`, 캐시 30.0초, 타임아웃 15초)을 명명 상수로 올리고 설정 통로에 노출한다. 새 임계값은 만들지 않는다 |
| 10. 휴리스틱 분류 | provider 판별은 이미 variant다. Brave LLM Context는 응답 구조가 `(title, url, snippet)`과 다르므로 **기존 hit 타입에 욱여넣지 않고** 별도 변형으로 받는다. 문자열로 형태를 추측하지 않는다 |
| 19. 재사용 | 추출 파이프라인을 새로 쓰지 않는다. `select_readable_nodes`(article→main→body)와 `clean_search_text`가 이미 있다. 절단 규칙만 결정론적으로 고정한다 |
| 20. 테스트 | acceptance는 Feature 왕복(§5)이다. provider 파서 단위 테스트를 늘리는 대신, keeper가 검색→추출→인용까지 한 바퀴 도는 경로를 검증한다 |
| 23. 경로 | 오프로드 파일은 `<basepath>` 하위에 쓴다. 절대 경로를 코드에 박지 않는다 |
| 24. 설정 통로 | 새 환경변수를 발명하지 않는다. `keeper_runtime_setting_registry`에 등록하고, 비밀이 아닌 값은 `Toml_and_env`, API 키는 `Env_only`로 노출한다. 키는 커밋되는 `config/runtime.toml`에 들어가지 않는다 |
| 25. IDE plane | Hermes·OpenClaw 흡수 항목의 첫 실행이다. 두 제품이 공유하는 축(capability별 backend 분리, 결정론적 절단, 오프로드)을 채택하고 채택하지 않은 축은 §6에 남긴다 |

## 2. 문제 — 실측 (2026-08-15)

### 2.1 폴백은 외형만 있다

`lib/tool_misc_web_search.ml:229`의 기본 순서는 자격 있는 provider만 남긴 뒤 무자격 두 개를 꼬리에 붙인다.

```ocaml
let default_provider_order () =
  [ Searxng; Brave; Tavily; Exa; Bing_api ]
  |> List.filter provider_has_credentials
  |> fun official -> official @ [ Ddg; Bing_rss ]
```

현재 환경에 설정된 자격은 `MASC_SEARXNG_URL` 하나뿐이다. 따라서 실제 체인은 `[Searxng; Ddg; Bing_rss]` 3단이다. 세 provider를 같은 질의로 직접 호출한 결과:

| Provider | HTTP | 결과 수 | 소요 | 판정 |
|---|---|---|---|---|
| SearXNG (`localhost:8888`) | 200 | 20건 | 1.81초 | 정상. 단 Docker 컨테이너 `masc-searxng` 필요 |
| DuckDuckGo HTML (`html.duckduckgo.com`) | **202** | **0건** (`result__a` 매치 없음) | 0.31초 | 봇 차단 페이지. `<link rel=canonical href=https://duckduckgo.com/>`만 반환 |
| Bing RSS (`bing.com/search?format=rss`) | 200 | **1건** (`<item>`) | — | 사실상 무응답 |

SearXNG 응답의 `engine` 필드는 전부 `brave`였다. 지금도 Brave 인덱스를 쓰고 있으며, 그 앞에 Docker 한 겹이 끼어 있다.

결과: 컨테이너가 내려간 순간 검색은 0건 또는 1건이 된다. 이때 도구는 실패하지 않고 **빈 성공**을 반환한다. keeper는 "웹에 정보가 없다"고 결론 내린다.

### 2.2 같은 판단이 이미 한 번 있었고 main에 닿지 못했다

`8a1bd382e9` (2026-06-10, `qa-king/task-718-websearch-backend-swap`):

```
task-718: remove Bing_rss from default provider fallback chain

Bing RSS was the last-resort fallback in default_provider_order()
tail (@ [Ddg; Bing_rss]). Brave/Tavily/Exa fetch functions already
exist — they were just shadowed by the hardcoded Bing_rss tail.
```

`git merge-base --is-ancestor 8a1bd382e9 origin/main` → **false**. 진단은 정확했고 diff는 한 줄이었으나 main에 도달하지 않았다. 이 RFC는 그 판단의 두 번째 시도이며, 이번에는 `Ddg`까지 포함해 근본에서 자른다.

### 2.3 본문이 두 번 실린다

`lib/tool_misc_web_enrichment.ml:288-304`은 enrich된 hits를 `results`에 넣고, **같은 hits를 렌더링한 문자열**을 `content_text`로 또 넣는다.

```ocaml
[ "results", `List enriched_hits
; ...
; ( "content_text",
    `String (render_content_text ... enriched_hits) )
]
```

`lib/tool_types/tool_result.ml:128`에서 성공 결과의 message는 payload 전체 직렬화다.

```ocaml
let message : result -> string = function
  | Completed { data; _ } | Deferred { data; _ } ->
    (match data with
     | `String s -> s
     | other -> Yojson.Safe.to_string other)
```

따라서 keeper가 받는 문자열에는 본문이 정확히 2회 들어가며, JSON 이스케이프(`\n` 2자, `"` 2자)가 얹힌다. 기본값(`limit` 5 × `contentMaxChars` 4,000)으로 40,000자, 상한(20,000자)이면 200,000자가 한 턴에 투입된다.

### 2.4 그 밖의 실측

- **캐시가 캐시 역할을 못 한다.** `MASC_WEB_SEARCH_CACHE_TTL_SEC` 기본 30.0초(`lib/config/env_config_runtime.ml:291`). Hermes·OpenClaw는 15분이다. 30초는 같은 턴 안의 재호출조차 놓친다.
- **API 키가 설정 SSOT 밖에 있다.** `BRAVE_SEARCH_API_KEY`·`TAVILY_API_KEY`·`EXA_API_KEY`·`BING_SEARCH_API_KEY`는 `env_present`로 raw env를 직접 읽으며 `keeper_runtime_setting_registry`에 등록되어 있지 않다. `web_search` 카테고리 등록 항목은 6개뿐이다.
- **`web_fetch`에 목적지 제한이 없다.** `validate_redirect_target`(`lib/tool_misc_web_fetch.ml:348`)은 http/https 스킴만 검사한다. loopback·사설 대역·링크로컬(`169.254.0.0/16`) 차단이 없어, keeper가 읽은 페이지의 지시에 따라 `http://127.0.0.1:8935`(MASC 자신의 API)를 fetch할 수 있다.

## 3. 설계

### 3.1 provider 계약: 조용한 폴백 제거

`Ddg`·`Bing_rss` variant를 타입에서 삭제한다. 파서(`parse_ddg_html`, `parse_bing_rss_items`, `looks_like_rss_payload`)와 그 테스트도 함께 삭제한다.

자격 있는 provider가 하나도 없으면 빈 성공이 아니라 `Config` 실패를 반환한다. 이는 "unknown → permissive default" 안티패턴의 역방향 정정이다: 설정되지 않은 상태를 편리한 기본값으로 흡수하지 않는다.

```ocaml
(* 자격 필터 후 비었으면 빈 결과가 아니라 설정 실패 *)
match provider_order () with
| [] -> Error (Config "no web search provider is configured")
| providers -> run_chain providers
```

구현 주(PR-2 반영): `Config`는 per-provider 오류 변형이고 aggregate 경계는
RFC-0189 관례대로 `Runtime_failure`를 유지한다 — `search_impl`의 반환
시그니처가 이미 `(_, string) result`라 aggregate를 typed로 올리는 것은 이
RFC 범위 밖의 리팩터다. 빈 체인은 해결 방법을 담은
`no_provider_configured_message`로 `Runtime_failure`가 되며, 위 의사코드의
의도(빈 성공 금지 + 안내 동봉)는 그대로다.

### 3.2 capability별 backend 분리

Hermes의 축을 그대로 채택한다. 검색과 추출은 서로 다른 provider가 잘한다.

| 설정 키 | 노출 | 용도 |
|---|---|---|
| `web_search.provider_order` | `Toml_and_env` | 검색 체인 (기존 키 재사용) |
| `web_fetch.extract_provider` | `Toml_and_env` | 추출 backend. 미설정 시 내장 Readability |
| `web_search.brave_api_key` 외 키 | `Env_only` | 시크릿. TOML에 쓰지 않는다 |

내장 추출(`select_readable_nodes`)은 기본값으로 남는다. 추출 backend는 그것이 실패했을 때가 아니라 **명시적으로 지정됐을 때** 쓴다 — 자동 폴백을 만들면 §3.1에서 제거한 조용한 흡수가 다시 생긴다.

### 3.3 Brave LLM Context를 옵션 provider로

`GET /v1/llm/context`는 URL+스니펫이 아니라 관련도 순위가 매겨진 추출 청크를 반환하며, **토큰 예산이 요청 파라미터**다.

| 파라미터 | 기본 | 범위 |
|---|---|---|
| `maximum_number_of_tokens` | 8192 | 1024–32768 |
| `maximum_number_of_tokens_per_url` | 4096 | 512–8192 |
| `maximum_number_of_urls` | 20 | 1–50 |

응답 형태가 `(title, url, snippet)`과 다르므로 기존 `normalized_hit`으로 다운캐스트하지 않는다. 다운캐스트하면 이 provider를 쓰는 이유(사전 추출된 청크)가 사라진다. 검색 결과를 두 변형으로 받는다.

```ocaml
type search_payload =
  | Hits of normalized_hit list      (* 기존 provider *)
  | Grounded of grounded_context     (* Brave LLM Context *)
```

키가 없으면 자격 필터에서 빠지므로 이 경로는 아예 열리지 않는다. 기본값이 아니다.

### 3.4 결정론적 절단과 오프로드

절단은 LLM 요약이 아니라 규칙이다. Hermes의 head/tail 분할을 채택한다.

- 상한 초과 시 앞 75% + 뒤 25%를 마크다운 줄 경계에서 자른다.
- 잘린 자리에 `[TRUNCATED]` 표시와 **전문 파일 경로**를 남긴다. 파일은 `<basepath>` 하위에 쓴다.
- keeper는 필요할 때 그 경로를 읽는다. 전문을 컨텍스트에 밀어 넣지 않는다.

`content_text`와 `page_content` 중 **`content_text`만 남긴다**. 이유: keeper가 실제로 읽는 것은 렌더링된 텍스트이고, `results[].page_content`는 같은 내용을 구조화된 형태로 중복 보관할 뿐 별도 소비자가 없다.

### 3.5 목적지 제한 (`web_fetch`)

`validate_redirect_target`을 스킴 검사에서 목적지 검사로 확장한다. 최초 요청과 각 리다이렉트 홉 모두에 적용한다.

- 차단: loopback(`127.0.0.0/8`, `::1`), 사설(`10/8`, `172.16/12`, `192.168/16`), 링크로컬(`169.254/16`, `fe80::/10`), `0.0.0.0`
- SearXNG는 `localhost:8888`이지만 `web_search`의 provider 경로이지 `web_fetch`의 사용자 입력 경로가 아니므로 영향이 없다

원칙 #7("게이트는 목표 도달 이후")과의 관계를 명시한다. 이것은 스케줄링·admission 게이트가 아니라 **외부 입력이 내부 주소로 향하는 것을 막는 경계**다. keeper가 웹에서 읽은 내용이 곧 다음 도구 인자가 되는 구조에서, 이 경계가 없으면 외부 문서가 내부 API 호출을 지시할 수 있다.

## 4. 구현 분할 (Stacked PR, 각 ≤ 20k token)

| PR | 범위 | 새 기능 |
|---|---|---|
| PR-1 | 본문 중복 제거(`page_content` 삭제), 캐시 TTL 기본값 정정, 매직넘버 명명 | 없음 (순수 결함 수정) |
| PR-2 | `Ddg`·`Bing_rss` 및 파서·테스트 삭제, 무자격 시 `Config` 실패 | 없음 (hard cut) |
| PR-3 | API 키 4종 `Env_only` registry 등록, `web_fetch.extract_provider` 추가 | 설정 통로 |
| PR-4 | Brave LLM Context provider + `search_payload` 변형 | 옵션 provider |
| PR-5 | Ollama `web_search`/`web_fetch` provider | 옵션 provider |
| PR-6 | 결정론적 절단 + `<basepath>` 오프로드 | 토큰 예산 |
| PR-7 | `web_fetch` 목적지 제한 | 경계 |

PR-1·PR-2가 먼저인 이유: 새 provider를 붙이기 전에 중복 전송과 가짜 폴백을 없애야 이후 PR의 효과를 측정할 수 있다.

## 5. Acceptance — Feature 왕복

함수 단위가 아니라 keeper가 도는 한 바퀴로 검증한다.

1. **자격 없음이 드러난다.** 모든 provider 자격을 제거한 상태에서 `masc_web_search` 호출 → 빈 성공이 아니라 `Config` 실패. keeper 로그에 설정 부재가 남는다.
2. **컨테이너가 내려가도 거짓 성공이 없다.** `masc-searxng` 중지 후 호출 → 0건 성공이 아니라 provider 실패로 종료.
3. **본문이 한 번만 실린다.** `includeContent=true` 호출의 payload 직렬화 길이가 PR-1 전후로 비교된다. 같은 질의·같은 hit 수에서 감소분을 기록한다.
4. **절단이 결정론적이다.** 상한을 넘는 페이지에서 head/tail 비율과 오프로드 경로가 재현된다. 같은 입력 → 같은 출력.
5. **목적지 제한이 동작한다.** `http://127.0.0.1:8935/health` fetch → `Workflow_rejection`. 리다이렉트로 우회하는 경로도 각 홉에서 차단.

증거는 로그·실측 수치로 저장소에 남긴다(원칙 #22).

## 6. 채택하지 않은 것

- **LLM 보조 모델로 추출 내용을 요약하는 경로.** 검색 스니펫 일부가 Hermes에 그런 기능이 있다고 기술하나, 공식 문서에는 없고 결정론적 절단만 기술되어 있다. 절단을 비결정론으로 바꾸면 같은 입력이 같은 출력을 내지 않는다. 채택하지 않는다.
- **Firecrawl·Tavily·Exa를 기본 경로로 승격.** 키가 필요한 provider를 기본으로 두면 키 없는 환경에서 제품이 서지 않는다. 자격 기반 필터를 유지한다.
- **추출 실패 시 자동 provider 폴백.** §3.1에서 제거한 조용한 흡수와 같은 구조다. 명시 설정만 쓴다.
- **`web_crawl` 도구 추가.** Hermes에는 있으나 현재 MASC에 소비자가 없다. 소비자가 생기면 그때 만든다.

## 7. 근거

**코드 (2026-08-15, `origin/main` 80747590c9)**
- `lib/tool_misc_web_search.ml:229` — `default_provider_order`
- `lib/tool_misc_web_enrichment.ml:288-304` — 본문 이중 적재
- `lib/tool_types/tool_result.ml:128` — payload 전체 직렬화
- `lib/tool_misc_web_fetch.ml:348` — 스킴만 검사하는 리다이렉트 검증
- `lib/config/env_config_runtime.ml:287-293` — 타임아웃 15초 / 캐시 30초
- `lib/config/keeper_runtime_setting_registry.ml:569-597` — `web_search` 카테고리 6항목
- `8a1bd382e9` — 미머지 선행 판단

**외부 (2026-08-15 확인)**
- Hermes Agent, Web Search & Extract — `web_search`/`web_extract`, capability별 backend 분리, `extract_char_limit` 기본 15,000자(2,000–500,000), head 75%/tail 25% 절단 + `[TRUNCATED]` + 파일 경로, 2MB 캡. <https://hermes-agent.nousresearch.com/docs/user-guide/features/web-search>
- OpenClaw, Web Tools — Brave 기본 + Perplexity 옵션, Readability 우선 후 Firecrawl, 사설/내부 호스트 차단 + 리다이렉트 재검사, 캐시 15분. 로컬 사본 `~/me/workspace/yousleepwhen/openclaw/docs/tools/web.md`
- Brave Search, LLM Context API — `GET /v1/llm/context`, `maximum_number_of_tokens` 기본 8192(1024–32768), `maximum_number_of_tokens_per_url` 기본 4096(512–8192), $5/1,000 요청. <https://api-dashboard.search.brave.com/api-reference/summarizer/llm_context/get>
- Ollama — `POST /api/web_search`(`max_results` 기본 5, 최대 10), `POST /api/web_fetch`(title/content/links, 마크다운), 무료 계정 API 키. <https://docs.ollama.com/capabilities/web-search>
- AIMultiple 벤치마크 — Agent Score(= 평균 관련 건수 × 품질 1–5): Brave 14.89 / Firecrawl 14.58 / Exa 14.39 / Parallel Pro 14.21 / Tavily 13.67 / Perplexity 12.96 / SerpAPI 12.28. 레이턴시 Brave 669ms ~ Parallel Pro 13.6초. **평가 시점은 페이지 내 표기가 엇갈려 확인 필요.** <https://aimultiple.com/agentic-search>

Confidence: 코드·로컬 실측 High. 외부 API 파라미터 High(공식 문서). 벤치마크 순위 Medium(단일 출처, 시점 불명확).
