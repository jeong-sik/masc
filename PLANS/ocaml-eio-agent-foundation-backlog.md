# OCaml Eio Agent Foundation Backlog

`masc-mcp`를 Rust/Go agent substrate 수준으로 끌어올리기 위한 foundation backlog.

기준:

- `Adopt now`: 지금 바로 붙여서 속도를 올릴 수 있는 것
- `Bridge / Fork`: 기능은 좋지만 production default로 쓰기 전에 소유권을 확보해야 하는 것
- `Build net-new`: 기다릴 생태계가 아니라 우리가 직접 만들어야 하는 것

참조 corpus: `benchmark/agent_ecosystem_repo_set.json`

---

## Adopt now

### 1. `ocaml-opentelemetry` + `opentelemetry-client-cohttp-eio`

- 목적: tool dispatch, operation, detachment, provider call, retry, cancellation을 span/event로 남긴다.
- 이유: observability는 이미 라이브러리가 있고, `masc-mcp` 전반에 바로 효율이 난다.
- 산출물:
  - 공통 tracing bootstrap 모듈
  - MCP tool latency / error span
  - command-plane operation span
  - provider request span
- 완료 기준:
  - local dev에서 OTLP export 가능
  - 주요 tool path에 trace id가 붙음
  - 최소 1개 dashboard / log correlation path가 생김

### 2. `ocaml-jsonschema`

- 목적: benchmark corpus, proof/report artifact, research export JSON을 schema 검증한다.
- 이유: machine-readable corpus를 넣어도 schema gate가 없으면 계속 drift 난다.
- 산출물:
  - `agent_ecosystem_repo_set.schema.json`
  - corpus validation command
  - CI or local check hook
- 완료 기준:
  - corpus JSON이 schema로 검증됨
  - 필수 필드 누락 시 실패
  - 신규 dataset도 같은 validator를 재사용

### 3. `openapi-ocaml`

- 목적: OAS surfaces, benchmark payload docs, external-facing schema 문서를 한 모델로 묶는다.
- 이유: 지금은 OAS/OA-like contract가 여러 레이어에 흩어져 있다.
- 산출물:
  - 최소 1개 internal schema doc generation path
  - benchmark/resource payload와 연결되는 typed model
- 완료 기준:
  - 신규 JSON corpus schema와 문서가 같은 source-of-truth에서 나옴

### 4. `ocaml-protoc-plugin`

- 목적: 이미 쓰는 gRPC/protobuf 경로를 더 generated-contract 중심으로 단일화한다.
- 이유: 이 영역은 gap보다 hardening 대상이다.
- 산출물:
  - protobuf regeneration rules 점검
  - generated type ownership 경계 정리
- 완료 기준:
  - hand-written protocol glue를 줄이고 generated path를 늘림

---

## Bridge / Fork

### 5. `tmattio/ocaml-mcp`

- 목적: reusable MCP client/server substrate 후보로 검토한다.
- 이유: OCaml community에서 제일 가까운 일반화 경로다.
- 부족한 점:
  - OAuth 2.1
  - cancellation
  - WebSocket / SSE
  - 일부 helper coverage
- 액션:
  - compliance reference로 즉시 활용
  - production dependency는 fork readiness 확보 후 판단
- 완료 기준:
  - missing feature matrix 작성
  - `masc-mcp` needs와 겹치는 부분만 선별

### 6. `tmattio/ocaml-anthropic`

- 목적: Claude 계열 direct provider path를 Eio-native로 확보한다.
- 이유: 기능면은 좋지만 ecosystem gravity가 아직 약하다.
- 액션:
  - vendor/fork 가능성까지 포함해 spike
  - retry / streaming / tool-use / files path를 `masc-mcp` 요구사항에 맞춰 점검
- 완료 기준:
  - direct integration feasibility note
  - 유지보수 리스크 평가

### 7. `Nymphium/openai-ocaml`

- 목적: 바로 adopt가 아니라 교체 기준선으로 사용한다.
- 이유: opam package가 2023 `0.0.1`이고 Lwt 기반이라 현재 agent substrate 기준으로는 부족하다.
- 액션:
  - salvage 가치 평가
  - fork보다 rewrite가 낫다면 바로 폐기
- 완료 기준:
  - `fork` vs `new Eio client` 결론

---

## Build Net-New

### 8. `eio-cdp`

- 목적: Chrome DevTools Protocol 기반 browser automation spine.
- 이유: browser automation은 현재 OCaml stack의 가장 큰 공백이다.
- 반드시 있어야 할 기능:
  - browser/session lifecycle
  - DOM query / click / type / screenshot
  - network inspection
  - console / page event streaming
- 완료 기준:
  - headless Chrome 연결
  - screenshot + click + DOM read smoke
  - `masc-mcp` tool로 감쌀 수 있는 API shape 확보

### 9. `llm-provider-eio`

- 목적: OpenAI / Anthropic / local providers를 공통 interface로 묶는다.
- 이유: provider별 ad hoc wrapper를 늘리면 agent substrate 속도가 계속 깨진다.
- 반드시 있어야 할 기능:
  - sync + streaming completion
  - tool-use / tool-call envelope
  - retry / timeout / cancellation
  - provider-neutral error model
- 완료 기준:
  - Anthropic + OpenAI + local 1종 이상 공통 API로 호출
  - room / worker / keeper에서 같은 path 재사용

### 10. `workflow-eio`

- 목적: long-running agent loops에 checkpoint / replay / retry / backoff를 first-class로 준다.
- 이유: Temporal 같은 reference는 있지만 OCaml default path는 없다.
- 반드시 있어야 할 기능:
  - idempotent step execution
  - durable checkpoint
  - explicit retry policy
  - cancellation-safe resume
- 완료 기준:
  - keeper or repo-synthesis path 하나를 이 runtime 위로 옮김

### 11. `agent-corpus-ingest`

- 목적: 외부 ecosystem survey, benchmark fixture, repo corpus를 정규화해서 resources/dataset으로 넣는다.
- 이유: 이번 조사 결과를 일회성 문서로 두면 다음 조사 때 또 잃는다.
- 반드시 있어야 할 기능:
  - source normalization
  - JSON schema validation
  - metadata refresh timestamp
  - MCP resource/read export
- 완료 기준:
  - `agent_ecosystem_repo_set.json`을 읽는 간단한 resource or CLI 추가

---

## 실행 순서

1. Observability
2. JSON schema validation
3. OpenAI Eio client decision
4. Browser automation spine
5. Workflow runtime
6. Corpus ingest automation

---

## 제외 / 주의

- `Eio`는 교체 대상이 아니다. substrate를 그 위에 쌓는 게 목표다.
- `opam gemini`는 Google Gemini model client가 아니라 Gemini exchange API 패키지라서 이번 backlog 대상이 아니다.
- `Qdrant` 관련 후보는 전부 제외한다. 벡터 저장 전략은 계속 Postgres/pgvector 기준이다.
