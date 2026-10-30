# Benchmark parallel request policy

## 공통 헤더

- 날짜(ISO8601): 2026-09-19T18:13:00+09:00
- 작성자: Codex
- 결정 ID: bench-parallel-request-policy
- 적용 대상: Terminal-Bench arm renderer, runtime binding materialization
- 결정 상태: 추적 필요

## 근거

- 항목: 모델의 parallel 지원 능력과 이번 요청에서 parallel을 억제하는 정책은 다르다.
- 출처: [Anthropic parallel tool use](https://platform.claude.com/docs/en/agents-and-tools/tool-use/parallel-tool-use), [Claude Code CLI reference](https://code.claude.com/docs/en/cli-reference), [settings](https://code.claude.com/docs/en/settings), `claude --version` / `claude --help` (2.1.278), [실제 HTTP 요청 캡처](before.json).
- 확인일시: 2026-09-19T18:13:00+09:00
- 신뢰도: High
- 제한조건: HTTP 캡처는 설치된 `8021c64ac303bdc8e7f3ac815f29b6ce38e1912f` 바이너리를 loopback으로 실행한 결과다. 모델 제공자를 호출하지 않았다. CLI 미지원은 MASC adapter가 제공하는 제어를 기준으로 한다.

## 검증

- 1차: renderer가 `supports-parallel-tool-calls`를 arm별로 바꾸지만 catalog 분기는 그 값을 읽지 않음을 확인했다. 요청의 `disable_parallel_tool_use` 기본값은 false였다.
- 2차: 캡처의 `toml`을 임시 `<base-path>/.masc/config/runtime.toml`에 저장하고 `masc runtime-verify --base-path <base-path> --timeout 15 claude.claude-fable-5`를 실행했다. loopback 서버는 count-tokens에 `input_tokens: 8`, completion에 캡처 완료를 알리는 HTTP 400을 답했다.
- 3차: parallel capability를 false와 true로 바꾼 두 실행 모두 `/v1/messages` 요청에 tools가 1개 있고 `tool_choice`는 없었다. 동일한 전송 경로에서 억제 정책이 빠졌음을 확인했다.
- 재현 결과: 결함 재현. 두 명령의 종료 코드는 의도한 HTTP 400에 따른 1이며 모델 응답·도구 실행·benchmark 통과를 뜻하지 않는다. 새 테스트는 binding TOML부터 fresh/resumed Agent 설정을 거쳐 Anthropic·OpenAI Responses 요청 JSON까지 검사한다. 로컬 Dune 빌드는 하지 않았고 OCaml 실행 검증은 PR CI에 맡긴다.

## 불확실성

- 미확인 항목: 변경된 바이너리의 실제 provider 호출과 Terminal-Bench 점수.
- 영향: 구버전은 새 binding 키를 거절한다. 새 빌드 전에는 새 renderer로 benchmark를 실행할 수 없다.
- 추가 확인 필요: PR CI의 OCaml 테스트와 새 바이너리의 요청 캡처. renderer의 `anthropic` provider 이름은 별도 catalog identity 결함이 있어 이 캡처에서는 실제 catalog provider인 `claude`를 썼다. scoped `claude`의 effort 계약도 없어 high를 생략했다. 원래 benchmark 설정 전체가 성공했다는 증거가 아니다.

## 적용범위

- 영향 받는 영역: binding의 `disable-parallel-tool-use`와 benchmark b·c·d. catalog capability는 유지한다. MASC가 억제 정책을 전달하지 못하는 공식 CLI·native Ollama·Gemini는 true를 거절한다.
- 제약/배제: spawn, 여러 Keeper의 동시 실행, 모델 지원 사실을 병렬 도구 호출 정책으로 대체하지 않는다. false는 허용이며 실제 병렬 호출 발생을 보장하지 않는다.
- 롤백 조건: 선언한 억제 정책이 provider 요청에 실리지 않거나, 미지원 runtime이 성공으로 받아들이면 해당 변경을 되돌리고 arm 결과를 유효한 비교로 사용하지 않는다.

## Provider 계약 리뷰 보완

- 항목: HTTP serializer가 필드를 만들 수 있어도 모든 호환 서비스가 억제 정책을 지원하는 것은 아니다. 모델의 병렬 생성 능력과 provider의 억제 제어 지원은 별도 사실이다.
- 출처: [Anthropic](https://platform.claude.com/docs/en/agents-and-tools/tool-use/parallel-tool-use#disable-parallel-tool-use), [OpenAI](https://developers.openai.com/api/docs/guides/function-calling#parallel-function-calling), [OpenRouter routing](https://openrouter.ai/docs/guides/routing/provider-selection#requiring-providers-to-support-all-parameters), [Z.ai request reference](https://docs.z.ai/api-reference/llm/chat-completion).
- 확인일시: 2026-09-19T20:18:12+09:00
- 신뢰도: High
- 제한조건: 각 서비스의 공식 요청 계약이다. 개별 모델 호출·성공률을 실측했다는 뜻은 아니다. Z.ai는 이 문서에서 해당 제어를 확인하지 못했으므로 지원한다고 추정하지 않는다.
- 검증: provider catalog의 `supports_parallel_tool_suppression`을 strict bool로 파싱하고, canonical ID/alias로 조회한다. 미선언/false/unknown provider는 억제 요청을 거절한다. 현재 true 선언은 native `claude`, `openai-responses` 두 provider뿐이다. OpenRouter의 일반 인자 문서만으로 gateway downstream의 억제 지원을 보장할 수 없다. 기본 routing은 미지원 인자를 무시할 수 있고 MASC는 `require_parameters`를 보내지 않으므로 OpenRouter도 미선언으로 유지하여 억제 요청을 거절한다. 모델의 `supports_parallel_tool_calls`는 유지한다.
- 추가 확인 필요: 보완 head에서 provider 계약/alias/잘못된 타입/미확인 endpoint 거부 및 기존 actual wire tests를 CI에서 다시 실행한다. 이전 cad3066b68의 targeted CI는 249 tests 통과했으나 이 보완의 검증으로 재사용하지 않는다.
