# 도구 뒤 Goal 상태 재주입 진단과 수리

2026-11-09의 `code-reviewer-brother` 반복 응답을 조사했다. 관측 서버의 소스는
`e2c38ca5ad1d850f2890b4e17d0ace08f7eea6b0`, 수리의 base는
`3d1271ef26b82b604b8f88dd6c126947ee4578bd`다. 관련 조립·SDK 전달 소스는 두 커밋에서 같다.

## 관측과 한계

한 실행의 도구 뒤 요청 37개에 같은 Goal 대기 안내가 들어갔고, assistant text 20개가
그 Goal을 다시 언급했다. 이 안내를 조립하는 경로는 요청 끝에 `role=user`,
`origin=system_context`를 붙인다. 같은 경로의 직전 완료 실행에서 보존된 provider
메시지 blob도 이 역할과 안내 내용을 확인했다. 이 스냅샷은 현재 실행 37개의 wire 캡처가 아니다.
OpenAI 호환 경로는 이 carrier를 대화 이력에 저장하지 않고 요청마다 다시 붙인다.
따라서 이번에 확인한 것은 이력 복제보다 새 발화처럼 보이는 반복 전달이다.

그 실행은 소스를 읽고 GitHub 판정을 게시하는 작업도 했다. 뒤에 들어온 채팅 2개는
별도 operation으로 대기했다. 반복 안내만이 도구 루프나 채팅 지연의 유일한 원인이라는
주장은 하지 않는다. [production-summary.json](production-summary.json)은 사적 대화·경로를
뺀 파생 집계다. 원본 raw prefix의 길이와 SHA는 원래 캡처의 식별자이며 이 JSON의 SHA가 아니다.

## 과거 기록

- `keeper_run_tools_hooks.ml`의 task-514 주석은 2026-08-24에 세계 상태를 매 도구 뒤
  재전송해 한 Keeper가 36번 같은 답을 다시 한 사례를 기록한다.
- #45853 (`1e938a0514af`)은 Task 승인·거절 관측이 도구 뒤 사라지는 결함을 수리했다.
  현재 상태를 단순히 생략하면 이 문제가 돌아온다.
- #49257 (`267b180bfc88`, 2026-11-06)은 System 캐시 변경을 줄이려고 Goal 대기 표시를
  끝 문맥으로 옮겼다. 당시 리뷰는 상태 가시성과 전달·출처를 확인했지만, 실모델의 반복
  발화 여부를 측정하지 않았다. 관련 source review의 범위는
  [당시 리뷰](https://github.com/jeong-sik/masc/pull/49257#pullrequestreview-5798394165)에 있다.
- [RFC-0491](../../rfc/RFC-0491-system-is-reissued-only-when-the-carried-front-moves.md)의
  관측 보존 요구와 캐시 선택을 분리해, 상태를 보존하면서 Agent Core 전달 위치를 바꿨다.

## Ollama 공식 계약과 실호출

[OpenAI 호환 API](https://docs.ollama.com/api/openai-compatibility)는
`https://ollama.com/v1`의 chat completions와 `reasoning_effort`를 설명한다.
[도구 호출 문서](https://docs.ollama.com/capabilities/tool-calling)는 assistant의 도구 요청과
tool 결과를 다음 요청에 돌려보내는 순서를 보여 준다. 이 순서에 새 사용자 발화를 덧붙이는
것은 Ollama의 필수 계약이 아니라 MASC가 한 선택이다.

[thinking 문서](https://docs.ollama.com/capabilities/thinking)에 따라 `/api/show`를 조회했다.
[실제 응답](ollama-show.json)의 `deepseek-v4.1-flash`는 `false`, `low`, `high`, `max`를
지원하고 기본값은 `high`다. 운영 설정의 `low`는 지원되는 값이다. reasoning replay는
현재 serializer가 Ollama의 `reasoning` 필드로 돌려보내므로 이 수리에서 바꾸지 않았다.

합성 대화·가상 Read 결과만 사용해 같은 모델에 3가지 요청을 각 2회 보냈다.
운영 대화 전체나 GitHub 쓰기 도구는 보내지 않았고, 반환된 도구도 실행하지 않았다.
모든 호출은 HTTP 200과 `finish_reason=stop`으로 끝났고 긴 도구 루프는 재현되지 않았다.

| 요청의 Goal 안내 위치 | 표본 | 무관한 Goal 언급 | 도구 재호출 |
| --- | --- | --- | --- |
| 마지막 User 메시지 | 2 | 2 | 0 |
| System 관측 | 2 | 1 | 0 |
| 안내 없음 | 2 | 1 | 0 |

이 표본은 전송 위치를 바꿔도 과거 발화나 System에 있던 Goal을 언급할 수 있음을 보여 준다.
반복 발화가 완전히 사라졌다는 증명도, 모든 장기 실행의 원인 분리도 아니다.
응답·usage·요청 SHA는 [ollama-comparison.json](ollama-comparison.json)에 보존했다.
reasoning 본문과 인증정보는 보존하지 않았다. 이 비교는 `temperature=0`의 작은 합성
대화이며 운영 `temperature=1`과 큰 대화창을 재현하지 않는다.

다시 실행할 때는 새 출력 경로를 쓴다.

```sh
python3 docs/evidence/2026-11-09-keeper-proof-context-feedback/ollama-probe.py \
  --output-dir artifacts/keeper-proof-context-probe-new
```

## 수리와 검증 경계

`Keeper_run_prompt.assemble_request_context`는 실제 runtime attempt의
`Runtime_execution.checkpoint_owner`를 받는다. Agent Core는 renderer가 만든
`Goals_awaiting_proof`를 System 관측에 두고 같은 실행의 다음 요청에서도 유지한다.
다른 새 문맥이 없으면 실제 tool 결과가 마지막 메시지가 된다.
official client는 기존 Start/Resume별 입력에 상태를 싣고 vendor System에 남기지 않는다.
실행 주체가 바뀌는 fallback도 같은 관측을 알맞은 위치로 옮긴다.
렌더러가 발행한 상태는 별도 타입으로 보존한다. 이름만 같은 일반 텍스트나 출처가
맞지 않는 문맥은 여러 도구 왕복이나 실행 주체 전환 뒤에도 System 상태로 승격하지 않는다.

Goal 표시가 바뀌는 새 턴에서는 Agent Core System 바이트가 바뀐다. 이 비용을 감수하며,
이전 설계의 캐시 절감량을 수리 후 절감량으로 인용하지 않는다. Task 승인·거절 전달,
실제 도구 실행, SDK의 signed Anthropic history 보존은 변경하지 않는다.

- 변경 OCaml 파일 10개의 `ocamlc -stop-after parsing`과 `git diff --check`를 통과했다.
  사용한 compiler는 5.5.1이며 이 결과는 5.5.2 타입·빌드·실행 증명이 아니다.
- 실제 HTTP wire 시험은 Read 두 번 뒤에도 같은 Goal 상태가 System에 있고,
  새 User 안내가 없으며 마지막 메시지가 tool인지를 검사하도록 바꿨다.
- 현재 단계의 새 턴 반영과 Agent Core/official fallback, 기존 official Start/Resume,
  Task 승인·거절 wire 시험을 검증 범위로 잡았다. 로컬 Dune 실행은 하지 않았다.
- 후보 서버의 운영 설치, 기존 Keeper 회복, TUI 응답 지연 해소는 아직 검증하지 않았다.
