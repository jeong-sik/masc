---
rfc: "0363"
title: Historical tool-result demotion in the bounded transmission view
status: Draft
author: Claude Opus 5 (1M context)
created: 2026-08-05
supersedes: []
related:
  - RFC-0351 (memory-first context management) — this implements the L5 tool_result line
  - RFC-memory-os-bounded-context-and-librarian-curator (#26534)
  - "#26545 / #26551 / #26800 (Runtime_model_input_tail_window)"
  - "#25096 (Tool_output / Tool_blob_store externalization)"
---

# RFC-0363 — Historical tool-result demotion in the bounded transmission view

## 0. 한 줄 요약

Tool 결과는 생성 시점에 64 KB 를 넘을 때만 blob 으로 나간다. 라이브 체크포인트 5,540 개 중 그 임계를 넘는 것은 1 개다. 나머지는 히스토리에 인라인으로 영구히 남아 매 요청마다 재전송된다. provider 가 요청을 크기로 거절하면, 그 시도의 재전송에서 tool 결과와 완료된 tool 인자를 전송 사본에서만 기존 blob 마커로 강등한다. 그 밖에서는 이미 보낸 메시지를 다시 쓰지 않는다(§3.4.1).

## 1. 문제 — 실측 (2026-08-05, `trace-1785189111927-00005`)

| 실측 | 값 |
|---|---|
| checkpoint 메시지 | 15,421 |
| checkpoint 직렬화 | 28.2 MB |
| tool 메시지 (인라인) | 5,540 |
| tool 메시지 (이미 마커) | 58 |
| **인라인 tool 바이트** | **20.0 MB = 전체 메시지 바이트의 71%** |
| 인라인 크기 p10 / p50 / p90 / p99 / max | 751 / **2,862** / 8,264 / 10,761 / 67,351 B |
| **현행 임계(65,536 B) 초과 개수** | **1** |

`Tool_bridge.maybe_externalize` 의 기본 임계는 `Common.max_tool_output_bytes` = 65,536. 중앙값 tool 결과는 그 1/23 이다. **쓰기 시점 externalization 은 이 분포에서 사실상 발화하지 않는다.**

> **2026-09-03 갱신 — 위 문단의 전제가 더는 성립하지 않는다.** #32748 이 발행 임계를 `Common.max_tool_result_wire_bytes` = 16,384 으로 내렸다. 공식 클라이언트 CLI 가 그보다 큰 결과를 자기 세션 디렉터리 파일로 흘리는데 Keeper 는 그 경로를 열 수 없어서다. 옛 상수 `max_tool_output_bytes` 는 제거됐다.
>
> 새 임계로 다시 세면 2026-09-01~03 `tool_calls` 기록 30,368건 중 **1,262건(4.2%)** 이 초과한다 (`keeper_artifact_read` 311, `keeper_tasks_list` 171, `masc_schedule_list` 81 등). 쓰기 시점 externalization 은 이제 발화한다.
>
> 이 RFC 의 나머지 논증은 2026-08-05 기준 측정 위에 서 있으므로 그대로 둔다. 다만 1장이 이득의 근거로 삼은 "쓰기 시점은 효과 없음" 은 재측정 없이 인용하지 말 것.

### 1.1 이득은 요청 축소가 아니라 히스토리 깊이다

`Runtime_model_input_tail_window` 는 이미 요청을 예산에 맞춘다 — 실측상 이 trace 는 히스토리의 1.9–4.7% 만 전송된다. 인라인 tool 바이트가 71% 를 차지하므로, **모델이 보는 깊이의 대부분을 오래된 tool 출력이 잡아먹는다.**

강등이 사는 것은 **예산당 원자 수**다.

### 1.2 외부 수렴

세 개 하네스가 같은 것을 한다 (2026-08-05 업스트림 소스 직독):

| 시스템 | 메커니즘 |
|---|---|
| claude-code 2.1.222 | 최신 5 개 tool_use id 유지, 나머지는 디스크 spill 후 경로 + 2 KB 프리뷰로 치환 |
| openclaw `80da6166` | `role==='toolResult'` 만 prunable, 최근 3 assistant 턴 보호 |
| hermes-agent `1be70d63` | `_prune_old_tool_results`. 코드 주석: *"old tool outputs otherwise ride in history and are re-sent verbatim on every subsequent turn"* |

MASC 만 per-result cap 만 갖고 **히스토리 pass 가 없다**.

### 1.3 RFC-0351 과의 관계

RFC-0351 §4 타입 수명이 이미 이 줄을 적어놓았다:

> `tool_result` — **사이클 스코프** — 닫힌 사이클은 조립 시 축약/스필 대상

본 RFC 는 그 줄의 구현이다. 새 정책이 아니다.

## 2. 이미 있는 것

새 저장소·도구·provider 의존이 없다.

| 부품 | 위치 | 제공 |
|---|---|---|
| content-addressed blob store | `lib/tool_blob_store/tool_blob_store.mli` | `put ~bytes ~mime -> Tool_output.t`, sha256 샤딩, atomic, 멱등 |
| 마커 코덱 | `lib/tool_blob_store/tool_output.mli` | `Inline \| Stored of artifact_ref`, `encode_for_oas`, `decode_from_oas` (`Not_marker \| Invalid_marker \| Decoded`) |
| 모델용 페이지 리더 | `lib/keeper/keeper_artifact_read.mli` | sha256 / offset / max_bytes. **이미 모델에 노출** (`keeper_tools_oas_bundle.ml:26`) |
| 원자 라벨링 | `lib/runtime/runtime_model_input_tail_window.ml` | `annotate`, `atoms_per_window = 60` |
| 메시지 측정기 | `keeper_turn_driver_try_provider.ml:261-264` | `Yojson.Safe.to_string (Keeper_context_core.message_to_json msg)` |

## 3. 설계

`model_input_projection` 안에서 원문 기준 cut 을 먼저 계산하고, 그 cut 이 이미 제외한 원자만 강등한 뒤 최종 cut 을 다시 계산한다. 전송 사본만 바꾸고 durable state 는 건드리지 않는다 (RFC-0351 §3 L5 "history 재작성 없음").

```
raw = project_with_drop ~measure_message_bytes ~capacity_bytes ~reserved_bytes messages
demote ~demote_before:(* §3.4.1: 크기 거절 뒤에만 거절된 요청의 원자 수, 그 밖에는 0. 예외: 끝난 턴의 결과는 그 턴의 끝 *) messages
  |> project_with_drop ~measure_message_bytes ~capacity_bytes ~reserved_bytes
```

### 3.1 강등 대상 — 타입으로 판정한다

`Agent_sdk.Types.ToolResult { content_blocks; content; _ }` 중 **모두** 만족하는 것:

1. 본문이 요청에 실리는 자리다. 결과의 `content` 는 늘 본문이다. `content_blocks = Some blocks` 면 `blocks` 안의 `Text` 블록 하나하나도 본문이다(§3.1.2 개정). 나머지 조건은 본문 하나하나에 따로 건다.
   인코더마다 보내는 본문이 다르다. `Some` 이면 Anthropic·OpenAI(이미지 없음)·Responses 는 블록만 보낸다. Gemini 는 늘 `content` 를 보내고, OpenAI chat 은 블록에 이미지가 있으면 `content` 와 블록을 함께 보낸다(§3.1.2 의 표). 그래서 둘 다 바꾼다. `Some` 안의 이미지·문서·오디오는 마커로 표현할 수 없으므로 그대로 둔다.
2. `Tool_output.decode_from_oas content = Not_marker`
   `Decoded` 는 이미 강등된 것이고, **`Invalid_marker` 는 강등하지 않는다** — 마커 모양인데 파싱에 실패한 payload 를 blob 으로 다시 저장하면 손상을 고착시킨다. 세 경우를 exhaustive match 로 다룬다.
3. 원자 인덱스 < `demote_before` 경계 (§3.4.1: 크기 거절 뒤의 재전송에서만 거절된 요청의 원자 수. 예외로 끝난 턴의 결과는 그 턴의 끝이 경계다)
4. `upper_bound_demoted_bytes msg < measure_message_bytes msg`

판단은 (a) 타입, (b) 정수 비교, (c) 바이트 비교뿐이다. 중요도 점수·문자열 분류·휴리스틱 임계값 없음 (RFC-0351 §2 원칙 2). 끝난 턴의 결과에만 고정 문턱(본문 2,048바이트)이 있다(§3.4.1 끝 단락).

### 3.1.1 알려진 틈 — 타입이 있는 블록으로 오는 결과 (2026-11-05)

§3.1.2 개정 전의 조건 1 은 `content_blocks = Some` 인 결과를 통째로 뺐다. 블록이 있으면 `content` 는 요청에 실리지 않으니 `content` 를 마커로 바꿔도 요청이 줄지 않기 때문이다. 그래서 블록으로 오는 도구 결과는 한 번 실리면 줄어드는 길이 없었다.

`docs/evidence/tool-result-carry-2026-11/measure_tool_result_carry.py` 로 10-29 ~ 11-04 저장된 요청 5,479개를 쟀다. 정의와 한계는 그 폴더의 README 에 있다.

| 측정 | 값 |
|---|---|
| 도구 결과가 실린 바이트 | 3.996 GB (본문 11.53 GB 의 34.6%, 저장된 크기 기준) |
| 그중 `masc_dos_*` 아홉 도구 | 1.711 GB (42.8%). 결과 4,804개 중 마커로 바뀐 것은 16개 |
| 그중 저장용 평문 사본(`text_content`) | `masc_dos_*` 실린 바이트의 54.7%, 전체 사본의 99.9% |
| 마커로 바뀐 결과 전체 | 39,080개, 실린 바이트의 33.2%. 서로 다른 마커 23.3 MB 가 평균 57번 실린다 |

`masc_dos_*` 는 MCP 형 `CallToolResult` 를 텍스트 블록 하나로 돌려준다(표본 하나로 확인했고 모든 결과가 그런지는 재지 않았다). 조건 1 이 든 두 이유 중 "이미지·문서를 담아서 마커로 표현할 수 없다"는 텍스트 블록만 있는 결과에는 해당하지 않는다.

조건만 풀면 안 되는 이유가 있다. `message_measurer` 는 `message_to_json` 의 길이를 재는데, 이 JSON 은 블록과 함께 평문 사본을 쓴다(`Agent_core.History.content_block_to_json`). 요청에 실리는 것은 블록뿐이다(`Api_common.tool_result_wire_fields_with`, `Backend_openai_serialize.tool_result_content_string`). 그래서 이런 결과의 측정값은 요청에 실리는 크기보다 크다. 이 상태에서 텍스트 블록 결과를 강등하면 줄어든 것으로 계상되는 양이 요청이 실제로 줄어드는 양보다 크다. 조건 1 이 막으려던 "추정이 하한이 되는" 경우와 같은 방향이다.

§3.1.2 가 이 틈을 닫는다. 측정기는 그대로 두고 `content` 와 안쪽 `Text` 를 함께 바꾼다. 측정기가 세는 감소와 한 레인의 요청이 줄어드는 양은 여전히 다르다. 그래도 요청이 한도를 조용히 넘지 않는 이유는 §3.1.2 의 (가)에 있다.

재지 않은 것: 모델이 마커의 `preview` 만으로 충분한지. `masc_dos_*` 를 쓰는 Keeper 가 크기 거절을 받는 일은 2026-11-06 msx-retro-mania 에서 일어났다(§3.1.2).

### 3.1.2 개정 — 블록으로 온 결과도 글 본문을 마커로 바꾼다 (2026-11-06)

#### 일어난 일

2026-11-06 09:22Z~12:10Z 에 msx-retro-mania 의 요청이 dispatch 전에 54번 거절됐다. 10:23Z 뒤 거절의 입력 수는 412,549~413,067 토큰이다(`Context overflow (limit: 500000): prepared request requires <N> input + 128000 reserved output tokens`). 입력에 쓸 수 있는 몫은 500,000 − 128,000 = 372,000 토큰이다(`Prepared_completion_request.admit`). 입력 수는 Anthropic `count_tokens` 가 실제 요청 몸체를 센 값이다(`Exact_output_count_tokens`).

1. 턴 #8670 이 도구 결과를 저장하며 돌다가 09:56Z 에 같은 거절(372,692)로 끝났다. Agent Core 턴은 실패하면 끝 줄을 남기지 않는다. 그래서 다음 턴들의 경계는 #8670 이 시작한 atom 5197 그대로다.
2. 다음 턴들은 5197 부터 싣는다. #8670 의 턴 기록이 받아들여진 시작점이다(로그 `origin=past_librarian_point:turn_record#8670`).
3. 경계 재전송은 새 시작점이 거절된 시작점보다 엄격히 뒤일 때만 보낸다(`turn_boundary_resend_sequence`, `keeper_turn_driver_try_provider.ml:3209`). 5197 > 5197 이 거짓이라 건너뛴다.
4. 마지막 걸음은 현재 턴 강등이다. 범위의 도구 결과 138개(아래 스크립트의 `measure` 가 센 값)는 모두 `content_blocks = Some` 이라 개정 전 조건 1 이 전부 뺐다. 강등한 조립이 거절된 조립보다 작지 않으니 강등도 없다(`current_turn_demotion`, `keeper_turn_driver_try_provider.ml:1440-1444`).
5. 그래서 매 턴 같은 요청을 만들고 같은 거절을 받았다.

4 는 이 절이 고친다. 1·3 에서 경계가 움직이지 못하는 것은 Librarian RFC §4.10 의 8 이 답한다. 끝 줄은 바꾸지 않는다.

#### 잰 것

`docs/evidence/mcp-result-demotion-2026-11/` 의 스크립트로 저장된 checkpoint 를 읽기만 해서 쟀다(2026-11-06T14:50Z). 정의와 한계는 그 폴더의 README 에 있다. 스크립트는 본문과 마커를 JSON 한 겹으로 견준다. 코드는 레인의 인코더로 견주므로(아래 (가)), 두 번 이스케이프하는 레인에서는 스크립트보다 적게 줄 수 있다. msx 는 한 겹인 Anthropic 레인이다. 바이트는 저장 JSON 기준이고, 넷으로 센다. 측정기는 블록과 평문 사본을 함께 센다. 블록은 Anthropic 이 보내는 모양이다. 사본은 Gemini 가 보내는 `content` 다. OpenAI chat 은 결과 본문을 JSON 문자열로 한 겹 더 싸서 보낸다(아래 표).

| msx-retro-mania, atom 5197~5262 | 값 |
|---|---:|
| 실린 메시지 | 132 |
| 도구 결과 | 138 (텍스트 블록만 87, 이미지+텍스트 51) |
| 마커가 되는 안쪽 `Text` 블록 | 138 |
| 마커가 되는 평문 사본 | 88 (나머지 50개는 이미 마커) |
| 마커보다 짧아 그대로 남는 본문 | 0 |
| 이미지 블록 | 51 |
| 측정기 바이트 | 2,306,538 → 526,634 |
| 블록 바이트 | 1,209,154 → 467,428 (741,726 줄어듦) |
| 사본 바이트 | 1,034,288 → 48,442 |
| OpenAI chat 결과 본문 바이트 | 881,315 → 94,105 |

msx 는 Anthropic 레인이라 블록 바이트가 요청에 실린다. 토큰은 추정이다. 줄어드는 741,726 바이트를 5.87 B/tok 으로 나누면 약 126,400 토큰이다. 413,067 − 126,400 ≈ 286,700 이고 372,000 아래다. 이 결론은 환산값에 크게 기대지 않는다. 줄어든 텍스트가 토큰 하나에 18.06 바이트보다 많이 들 때만 넘친다(741,726 / (413,067 − 372,000)).

이미지는 따로 센다. 51개 모두 640×480 PNG 이고 checkpoint 에는 미디어 참조로 저장돼 있다(51개 합 8,057 B). 이 개정은 이미지를 바꾸지 않는다. 이미지가 픽셀로 실리든 이미지를 읽은 글로 바뀌든(RFC-0265 media degrade), 그 몫은 413,067 안에 이미 있고 강등 뒤에도 그대로다. 픽셀로 실리면 Anthropic 근사식(w×h/750)으로 약 20,900 토큰이다(확인 필요).

같은 질문을 code-reviewer 에 하면 답은 0 이다. 그 범위(atom 8014~8264, 블록 바이트 6,068,341)의 도구 결과 298개는 모두 문자열 본문(`content_blocks = None`)이라 지금 규칙으로도 강등 대상이다. 그중 189개가 마커가 되고 109개는 마커보다 짧아 남는다(6,068,341 → 5,615,026 B). 12:12Z 에 이 Keeper 의 요청이 크기로 거절됐을 때는 경계 재전송이 움직였다(atom 8014 부터 5,681,919 B 거절 → 경계 8257 부터 90,329 B, 받아들여짐). 범위의 76.5%(4,641,758 B)는 System 역할로 저장된 지난 context carrier 다. 이것은 이 개정의 범위 밖이다(#49192).

#### 조건 1 의 두 이유에 답한다

(가) "`Some` 이면 `content` 가 요청에 실리지 않으니, `content` 를 바꾸면 추정이 하한이 된다."

반만 맞다. 인코더마다 보내는 본문이 다르다.

| 인코더 | `Some` 결과에서 보내는 글 |
|---|---|
| Anthropic (`Backend_anthropic`) | 블록 |
| OpenAI chat, 이미지 없음 (`Backend_openai_serialize.tool_result_content_string`) | 블록 전체를 JSON 문자열 하나로. `Text` 본문은 두 번 이스케이프된다 |
| OpenAI chat, 이미지 있음 (`Tool_result_projection.with_image_followups`) | `content` 와, 따라 붙는 user 메시지의 블록 |
| Responses, 이미지 없음 (`Backend_openai_responses`, `content_string_of_tool_result`) | 블록 전체를 JSON 문자열 하나로(`output`) |
| Responses, 이미지 있음 | `input_text`·`input_image` 조각 목록 |
| Ollama (`Backend_ollama`) | 블록 전체를 JSON 문자열 하나로. 이미지는 `images` 로 옮긴다 |
| Gemini (`Backend_gemini`, `functionResponse.response.result`) | `content`. 이미지가 있으면 따라 붙는 부분의 블록도 |
| GLM (`Backend_glm`, OpenAI chat 요청을 그대로 만든다) | OpenAI chat 과 같다 |
| Kimi (`Api_common.kimi_message_to_json`, Anthropic Messages 모양) | 블록 |

어느 하나만 바꾸면 어떤 레인에서는 요청이 줄지 않는다. 그래서 둘 다 본문으로 본다. `content` 와 안쪽 `Text` 하나하나가 각자 본문이다. 둘을 함께 보내는 레인(이미지가 있는 OpenAI chat 과 Gemini)에서도 둘 다 마커가 된다.

측정기(`message_to_json`)는 블록과 `content` 를 함께 센다. 그래서 측정기가 세는 감소와 한 레인의 요청이 줄어드는 양은 다르다. Anthropic 레인에서는 `content` 의 감소가 요청에 없다.

이 차이로 요청이 한도를 조용히 넘지는 않는다. 개정 전 이유가 걱정한 것은 window 가 과소평가된 측정으로 자르고, 물질화된 요청이 예산을 넘는 일이다. 지금 Agent Core 레인에는 바이트 창이 없다(`keeper_turn_driver_try_provider.ml:997-998`). 측정기는 두 곳에서 "작아지는가"에만 답한다. 메시지 후보가 원래보다 작은가(`plan`, `keeper_model_input_demotion.ml:399`), 강등한 조립이 거절된 조립보다 작은가(`current_turn_demotion`)다. 요청이 한도에 드는지는 공급자의 셈(`admit`)이나 공급자의 거절이 정한다. 덜 줄었으면 다시 보낸 요청이 다시 거절되고, 사다리의 다음 걸음이 답한다.

레인마다 줄어드는지는 그 레인의 인코더에 묻는다. 본문은 그 레인이 이 결과만 든 메시지를 마커와 함께 더 짧게 보낼 때만 바뀐다(`Keeper_model_input_wire_bytes.measurer`; `plan` 의 `shrinks_on_the_wire`, `keeper_model_input_demotion.ml:294`, :345-371). 재는 법은 이렇다.

- 결과를 부르는 assistant 메시지를 앞에 두고, 그 레인 설정으로 `Complete_common.serialize_http_request` 가 만드는 요청 몸체의 길이를 잰다. 레인의 인코더는 `Provider_http_codec.of_config` 가 고른다.
- 미디어는 자리와 종류만 두고 payload 는 비운다. 두 모양이 같은 미디어를 실으므로 비교에서 지워진다. payload 를 읽으면 계획을 세우는 CPU 작업 안에 미디어 저장소 I/O 가 생긴다.
- 본문마다, 앞서 고른 본문을 마커로 둔 위에서 잰다. 인코더가 요청을 거절하면(`None`) 그 본문은 남는다.
- 측정은 메시지마다 한 번이다(`memoize_message_measurement`, `keeper_turn_driver_try_provider.ml:1806`).

그래서 레인이 보내지 않는 본문은 바이트가 같아 남는다. Anthropic 의 `content` 가 그렇다. 두 번 이스케이프하는 레인에서 마커가 본문보다 길어지는 본문도 남는다. 한국어 433자(1,299 B) `Text` 블록은 JSON 한 겹으로는 마커 1,116 B, 본문 1,301 B 다. 두 겹으로는 마커 1,514 B, 본문 1,299 B 다. 마커는 preview 를 `%S` 로 쓰므로 한국어 바이트가 `\ddd` 네 글자가 되고, 그것이 다시 이스케이프된다. 메시지 비교만 두면 긴 `content` 가 줄어든 몫이 짧은 `Text` 블록이 마커로 커진 몫을 덮어, 블록만 보내는 레인에서 그 결과가 커진다.

거절 뒤 재전송의 허락(`current_turn_demotion`)은 측정기 바이트로 본다. 계획된 결과 본문은 모두 그 레인의 요청을 줄이므로, 측정기 바이트가 줄었으면 그 레인에 보낼 것이 바뀌었다. 레인이 보내지 않는 본문만 있으면 계획이 비고, 측정기 바이트도 같아 다시 보내지 않는다.

§3.1.1 의 방향 1(측정기를 요청 모양으로)은 택하지 않는다. 측정기는 창의 셈이라 레인마다 달라지면 안 된다. 레인마다 다른 질문은 본문 하나를 바꿀지뿐이고, 그것은 위의 레인 측정이 답한다. 방향 2 의 "강등 뒤 `content_blocks = None`" 은 택하지 않는다. 그렇게 하면 같은 결과의 이미지가 요청에서 사라진다.

(나) "`Some` 은 이미지·문서를 담고 마커로 표현할 수 없다."

지금도 맞다. 그래서 글만 바꾼다. 안쪽 블록 중 `Text` 만 바꾸고 `Image`·`Document`·`Audio` 는 그대로 둔다. 참조로 저장된 것은 참조로, 인라인인 것은 인라인으로 나간다. 미디어의 크기는 RFC-0265 media 경로가 다룬다. msx 의 이미지 51개는 모두 이미 참조다(`source.sha256`).

#### 다른 RFC 가 둔 제외와 규칙에 답한다

| 자리 | 이유 | 답 |
|---|---|---|
| RFC-durable-tool-result-markers §6 | 블록 결과의 durable 마커는 범위 밖이다 | 그대로 성립한다. 이 개정은 전송 사본만 바꾼다. 그 절에 이 개정을 적었다 |
| RFC-tool-results-age-out-of-context 열린 질문 4 | 지난 턴 마커에 이미지 블록이 드는가 | 들지 않는다. 글 본문만 바뀐다 |
| Librarian RFC §4.10 의 1 | 새 시작점이 엄격히 뒤일 때만 다시 보낸다. 같은 요청을 다시 보내지 않기 위해서다 | 그대로 성립한다. 1 이 움직이지 못하는 자리(실패한 턴이 끝 줄 없이 atom 을 남긴 자리)는 이 절의 강등이 먼저 답하고, 그래도 넘치면 8 이 이번 턴의 시작부터 보낸다. 8 도 시작점이 엄격히 뒤일 때만 보낸다 |
| 창 RFC §10.4 | 강등은 거절 뒤에만 하고 범위를 좁히지 않는다. `artifact_read` 가 없는 Keeper 는 강등하지 않는다 | 그대로 성립한다. 이 개정은 그 강등의 대상만 넓힌다 |
| 창 RFC §13.9 둘째 항목 | 끝나지 못한 턴의 결과가 넘치는 경우는 닫혔다 | 블록으로 온 결과에서는 틀렸다. 그 항목을 고쳤다 |

#### 규칙

§3.1 의 조건은 본문 하나하나에 건다.

- 결과의 `content` 는 본문이다. `content_blocks` 가 `None` 이든 `Some` 이든 같다.
- `content_blocks = Some blocks` 면 `blocks` 안의 `Text t` 하나하나도 본문이다.
- 조건 2(`Not_marker`), 조건 3(atom < `demote_before`)은 본문마다 따로 본다.
- 끝난 턴의 2,048 바이트 문턱은 결과 하나에 건다(`result_text_bytes`). `None` 이면 `content` 의 길이, `Some` 이면 `content` 와 `Text` 합 중 긴 쪽이다. 문자열 결과와 같은 기준이다. 본문마다 걸면 작은 `Text` 여러 개로 나뉜 결과는 합이 커도 마커가 되지 않는다. 저장된 checkpoint 38개의 블록 결과 4,759개에서 두 기준이 가르는 결과는 0개였다(결과 기준 4,664, 블록 기준 4,664, `floor-hole`). 지금 자료로는 차이가 없고, 문자열 결과와 같은 기준이라 결과 기준을 쓴다.
- 본문은 그 레인의 인코더가 마커를 넣은 결과를 더 짧게 보낼 때만 바뀐다. 본문마다, 앞서 고른 본문 위에서 잰다(`shrinks_on_the_wire`). 인자(`Call_arguments`)에는 이 조건이 없다.
- 바뀐 본문은 같은 자리에서 마커가 된다. `content` 는 마커 문자열이 되고, `Text t` 는 같은 자리의 `Text <마커>` 가 된다. 다른 블록은 원래 값 그대로다(물리적으로 같은 값).
- 안쪽 블록은 exhaustive match 로 가른다. `Text` 만 본문이다. `Image`·`Document`·`Audio`·`Thinking`·`RedactedThinking`·`ReasoningDetails`·`ToolUse`·`ToolResult` 는 그대로 둔다. catch-all `_` 를 쓰지 않으므로, `content_block` 에 생성자가 늘면 컴파일러가 이 자리를 묻는다.
- 안쪽 `ToolResult` 로 내려가지 않는다. `content_blocks` 안에 결과를 넣는 producer 가 없다. MCP 결과는 `Text`·`Image`·`Audio` 로만 바뀌고(`content_block`, `keeper_lane_addon_runtime.ml:15-24`), 내장 도구는 `Text`·`Image` 로 만든다.
- 조건 4(줄어드는가)는 지금처럼 메시지 전체로 본다. 한 결과의 본문 여럿은 한 메시지 후보로 함께 정해진다.

#### 바뀌는 코드

`lib/keeper/keeper_model_input_demotion.ml`·`.mli`, 새 `lib/keeper/keeper_model_input_wire_bytes.ml`·`.mli`, 그리고 측정기를 넘기는 `keeper_turn_driver_try_provider.ml`·`.mli` 와 `keeper_official_client_host.ml` 이다.

- 본문이 놓인 자리는 닫힌 variant `payload_kind = Result_body | Result_text_block of int | Call_arguments` 다.
- 대기 항목은 placeholder 토큰으로 묶고, 블록이 그 placeholder 와 물리적으로 같은 값일 때만 찾는다(`pending_lookup`, :429). `Text` 블록의 토큰은 `f` 로 시작해 결과 전체의 토큰과 겹치지 않는다.
- address memo 는 `(occurrence, payload_kind)` 를 키로 쓴다. 물질화 기록(`capture_materialized`·`replay_materialized`)은 occurrence 를 키로 쓴다.
- `result_text_bytes`(:200) 가 결과 하나의 글 길이를 잰다. `demotable_bodies`(:210) 가 블록 하나의 본문과 그 자리를 모두 돌려준다.
- `with_result_content`(:253), `with_result_block`(:234), `with_reference`(:265) 는 그 자리가 블록에 없으면 `None` 이다.
- `plan`(:300) 은 결과 본문마다 레인 측정(`shrinks_on_the_wire`, :294)을 걸고, 그 뒤 메시지 비교(:399)를 건다.
- `Keeper_model_input_wire_bytes.measurer ~config` 가 레인 측정이다. `bounded_model_input_projection` 이 그 레인 설정으로 만든다(`keeper_turn_driver_try_provider.ml:1806`).
- 한 결과의 본문 하나가 `put` 에 실패하면 그 본문만 원래대로 남는다(§3.5, `reverted` 하나). `materialize`(:533) 는 블록을 원래 블록에서 다시 만들고, 쓴 본문 자리에만 마커를 넣는다. 같은 결과의 다른 본문은 쓴 참조를 가진다. `plan` 이 같은 원래 블록에서 자리를 읽었으므로, 자리를 다시 찾지 못하면 계획이 깨진 것이고 `invalid_arg` 로 멈춘다.
- 공식 클라이언트 레인은 바뀌지 않는다. `Keeper_official_client_host.plan_arguments` 는 `demote_before:0` 으로 결과를 강등하지 않고, 레인 측정은 늘 `None` 이다(`keeper_official_client_host.ml:831-866`).

#### `Finished_turns_as_markers` 에 생기는 일

끝난 턴의 결과(`finished_turn_results`, `aged_result_min_bytes = 2_048`, `keeper_turn_driver_try_provider.ml:1045`)도 같은 `plan` 을 지난다. 그래서 이 개정 뒤에는 블록으로 온 결과도 그 턴이 끝난 뒤 첫 요청에서 글 본문이 마커가 된다. 이후 요청에서는 같은 마커로 나간다.

- 문턱은 결과 하나에 건다(위 규칙). 작은 `Text` 여럿으로 나뉜 결과도 합이 2,048 B 를 넘으면 마커가 된다.
- prefix 는 결과마다 한 번 바뀐다. 문자열 본문 결과가 지금 치르는 비용과 같다(§3.4.1 끝 단락).
- 서명된 추론은 지금과 같게 다룬다. 결과만 강등한 기준선이 남긴 추론을 지키고(`request_view`, `keeper_turn_driver_try_provider.ml:1564`), prefix 가 바뀐 Anthropic thinking 은 요청에서 빠진다(`Reasoning_history_projection.verify_prefix_binding`).
- 덮이는 결과는 §3.1.1 의 `masc_dos_*` 결과 4,804개(실린 바이트 1.711 GB) 쪽이다. 얼마나 줄어드는지는 재지 않았다. 배포 뒤 §6 의 지표로 잰다.

#### cap·cooldown·재시도 횟수·문자열 분류가 아니다

- 판정은 블록 생성자와 바이트 비교뿐이다. 새 숫자가 없다. 2,048 은 끝난 턴의 기존 문턱이다.
- 마커인지는 `Tool_output.decode_from_agent_core` 의 typed 결과(`Not_marker | Invalid_marker | Decoded`)로 본다. 접두어 검사를 더하지 않는다.
- 도구 이름(`masc_dos_*`)으로 가르지 않는다. 블록으로 온 결과 전부가 같은 규칙을 받는다.
- 거절 뒤 재전송은 지금처럼 한 번이다(`current_turn_demotion_sequence`). 그 한 번에 줄일 것이 생길 뿐 걸음 수는 같다.

#### Hard cut 이 아니다

바뀌는 것은 전송 사본뿐이다. checkpoint, codec, 턴 기록, 끝 줄의 모양은 같다. 옮길 데이터가 없고 Fresh state 에서 지울 것도 없다. 강등이 만드는 blob 은 §3.6 의 파생 데이터다. 되돌리면 다음 요청부터 원문 블록이 다시 나간다.

#### 시험

`test/test_keeper_model_input_demotion.ml` 의 `structured_results` 묶음이다. 각 시험은 아래 변형을 넣으면 실패해야 한다.

| 시험 | 보는 것 | 잡는 변형 |
|---|---|---|
| content and each Text block are demoted | `Some [Text; Image; Text]` 결과에서 대기 항목이 셋이다. `content` 와 두 `Text` 는 마커이고, `Image` 는 같은 자리의 물리적으로 같은 값이다 | `Some` 을 다시 뺌. 안쪽 `Text` 만 바꿈. 엉뚱한 자리를 바꿈 |
| a Text block shorter than its marker stays | 긴 `content` 와 짧은 `Text` 가 있는 결과를 측정기 모양으로 잰다. 대기 항목이 둘이다. `content` 와 긴 `Text` 는 마커이고 짧은 `Text` 는 그대로다 | 레인 측정을 뺌 |
| no provider wire carries a demoted body | 이미지가 있는 결과, 글만 있는 결과, 따옴표·역슬래시가 많은 결과를 OpenAI chat·Responses·Anthropic·Gemini·Ollama·GLM 의 레인 측정으로 계획하고 그 인코더로 만든다. 레인마다 본문을 고르고, 원래 본문이 요청에 없고, 요청이 줄고, 물질화된 요청은 계획한 요청보다 크지 않다 | `content` 를 둠(Gemini·이미지가 있는 OpenAI chat 에 남음). 안쪽 `Text` 를 둠(Anthropic·두 겹 JSON 레인에 남음) |
| a short Korean block stays on lanes that escape twice | 1,299 B 한국어 `Text` 하나. 측정기 모양과 Anthropic 은 마커를 고르고, OpenAI chat·Responses·Ollama·GLM 은 본문을 남긴다. Gemini 는 그 블록을 보내지 않아 고르지 않는다. 어느 레인도 요청이 커지지 않는다 | 레인 측정 대신 한 겹 길이로 잼. 레인 측정을 뺌 |
| a body the lane does not send asks for no resend | Anthropic 레인, 긴 `content` 와 마커보다 짧은 `Text` 둘인 결과. 크기 거절 뒤 `current_turn_demotion` 이 `None` 이다. 측정기 모양으로 재면 `Some` 이다 | 레인 측정을 뺌. `shrinks_on_the_wire` 의 `<` 를 `<=` 로 바꿈 |
| markers inside the blocks are left as they are | 안쪽 `Text` 가 이미 마커(`Decoded`)거나 깨진 마커(`Invalid_marker`)면 같은 값 그대로다. 두 값 모두 자기 마커보다 길어서 길이 비교로는 남지 않는다 | 안쪽 블록에서 마커 판정을 건너뜀 |
| a failed Text write keeps the written content, a failed content write keeps the written Text block | 한 본문만 보내는 레인으로 계획해 그 본문을 먼저 쓴다. 그다음 막힌 저장소로 두 본문을 물질화한다. 실패한 본문은 원문, 다른 본문은 쓴 참조, 이미지는 같은 값이고 `reverted = 1` 이다 | 실패한 본문 때문에 블록 전체를 되돌림. `Text` 토큰의 `f` 를 뺌. `<` 를 `<=` 로 바꿈(레인이 두 본문을 고름) |
| each body is stored and replayed | 마커마다 자기 본문을 연다. `capture_materialized` → `replay_materialized` 가 같은 요청을 돌려준다 | lookup 이 안쪽 마커를 못 찾음 |
| the finished-turn floor counts the whole result | 끝난 턴에서 2,047 B 결과는 그대로, 2,048 B 결과는 마커가 된다. `content` 가 비고 1,024 B `Text` 둘로 나뉜 결과도 두 `Text` 가 마커가 된다 | 문턱을 본문마다 걺. `Text` 합을 빼먹음 |
| a refusal demotes structured results | 현재 턴 결과가 모두 블록 `Some` 인 요청이 크기 거절되면 `current_turn_demotion` 이 거절된 요청의 atom 수를 돌려준다(msx 재현) | 개정 전 규칙 |

§6 의 시험 3 은 이 표로 바뀐다.

#### 배포 순서

1. 이 절과 Librarian RFC §4.10 의 7·8 을 한 스택으로 낸다. 이 문서 층, 이 절의 코드 층, §4.10 의 7·8 코드 층 순서다. 스택은 맨 위에서 한 번에 병합한다.
2. 배포 뒤 msx 로그를 본다. `model input current turn demoted` 다음 받아들여진 요청이 있고, `prepared request requires` 거절이 멈춰야 한다.
3. `masc_dos_*` 를 쓰는 Keeper 에서 잰다. 턴이 바뀐 첫 요청의 캐시 적중(§3.4.1 표와 같은 방법), 요청 바이트, `keeper_artifact_read` 호출 수다.

### 3.2 크기 상한 — 포맷을 복제하지 않고 포화 후보로 측정한다

마커 크기는 "약 200–300 B" 가 아니다. 실측:

| 케이스 | raw | JSON |
|---|---|---|
| ASCII 200 B 프리뷰 | 321 B | 325 B |
| **한국어 200 B 프리뷰** | 867 B | **1,053 B** |
| 포화 최악 (200×0xFF, 19 자리 count) | 950 B | **1,154 B** |

`encode_for_oas` (`tool_output.ml:132-133`) 는 프리뷰를 `%S` 로 넣는다 = `String.escaped`, 0x20–0x7E 밖 모든 바이트가 `\ddd` 4 자로 팽창한다. `make_preview` (`tool_blob_store.ml:101-112`) 는 0x20 미만만 제거하므로 0x7F–0xFF 는 살아남는다. 그 뒤 Yojson 이 backslash 를 다시 2 배로 만든다 — 상위 바이트당 **5×**. **MASC 의 tool 출력은 일상적으로 한국어 UTF-8 이고, 그 모든 바이트가 0x80 이상이다.**

따라서 포맷 산술을 강등 모듈이 복제하면 안 된다. 대신:

```
upper_bound_demoted_bytes msg =
  measure_message_bytes
    (msg with content = encode_for_oas (Stored saturating_ref))
where saturating_ref = make_artifact_ref
  ~sha256:(String.make 64 'f')
  ~bytes:(String.length content)
  ~preview:(String.make Tool_blob_store.preview_max '\255')
  ~mime:(* 실제 물질화가 쓸 mime 과 동일 *)
```

**window 가 쓰는 바로 그 `measure_message_bytes`** 를 통과시킨다. 해싱 없음, I/O 없음, 포맷 지식 없음. 실제 마커는 항상 이보다 작거나 같다.

### 3.3 `preview_max` 를 export 한다

`preview_max = 200` 은 현재 `tool_blob_store.ml:99` 에 있고 `.mli` 에 없다. `make_artifact_ref` 는 프리뷰 길이를 검사하지 않는다. 강등 모듈이 `200` 을 하드코딩하면, 나중에 `preview_max` 를 올리는 변경이 상한을 조용히 하한으로 바꾼다 — CLAUDE.md 가 금지하는 silent failure 다.

`val preview_max : int` 를 `tool_blob_store.mli` 에 공개하고, 강등은 그것만 참조한다.

### 3.4 경계는 원문 cut 에 고정한다

강등 경계가 `atom_count - N` 이면 새 원자 하나가 붙을 때마다 직전 원자 하나가 원문에서 마커로 바뀐다. 두 요청의 공통 prefix 는 항상 그 이동 지점에서 끊기므로, 매 턴 새 원자 1개가 아니라 최신 원문 N개를 다시 처리하게 된다. `N = 60`이면 prompt-cache 재처리량이 1 → 61 원자로 늘어난다.

강등 자체가 별도의 나이·예산 경계를 소유하면 같은 문제가 반복된다. 권위는 이미 byte budget으로 계산되는 원문 tail-window cut 하나다:

1. 변경하지 않은 `messages`를 `project_with_drop`에 넣어 `dropped_atoms`를 얻는다.
2. `index < dropped_atoms`인 tool result만 포화 마커 후보로 바꾼다.
3. 줄어든 메시지로 최종 cut을 다시 계산한다.

따라서 demotion 경계는 원문 cut이 움직일 때만 움직인다. 양자화 cut이 60으로 유지되는 동안 새 turn을 붙여도 같은 60개만 마커이고, 60 → 120으로 뛰는 순간 새 60개가 바뀌지만 그 원자들은 원문 요청에서도 바로 그 jump에 탈락한다. demotion이 prompt-cache 변경 빈도를 늘리지 않는다. exact cut fallback에서도 동일하다. raw cut이 매 turn 움직이는 상황에서는 demotion도 움직이지만, 원문 prefix가 이미 같은 빈도로 움직인다.

### 3.4.1 개정 — 이미 보낸 메시지는 크기 거절 뒤에만 강등한다

agent_core 조립(`Keeper_turn_driver_try_provider`)은 전송 범위 안에서 이미 보낸 메시지를 다시 쓰지 않는다. tool 결과와 완료된 tool 인자(#43873)는 처음 보낸 모양 그대로 다음 요청에도 나간다. official client host 의 인자 투영(`Keeper_official_client_host.plan_arguments`)은 아직 턴 경계(`completed_before`)로 인자를 강등하며, 그 경로의 캐시 영향은 재지 않았다. 전송 사본이 줄어드는 곳은 둘이다.

1. **범위의 앞이 움직일 때.** Librarian 이 완료된 턴을 요약에 넣으면 그 원자는 범위에서 빠진다. 줄어드는 자리와 prefix 가 끊기는 자리가 같다.
2. **provider 가 요청을 크기로 거절했을 때 (#28845).** 그 시도의 재전송은 거절된 요청 끝까지의 원자 전부를 강등 범위로 잡는다(`demote_before` = 거절된 요청의 원자 수). 완료된 인자도 함께 강등한다. 같은 시도의 뒤 요청은 같은 강등을 유지하므로, 그 시도 안에서 prefix 는 다시 바뀌지 않는다. 강등할 것이 없거나 강등 뒤에도 거절되면 typed 거부가 그대로다. 재시도 루프가 아니다.

강등 경계를 현재 턴의 첫 원자로 두면 경계가 턴마다 움직인다. 직전 턴의 결과와 인자가 다음 턴 첫 요청에서 마커로 바뀌고, 공통 prefix 는 그 자리에서 끊긴다. 턴마다 한 번 움직이는 경계는 턴마다 한 번 캐시를 버린다. 2026-11-03~04 GLM lane 실측(비용 원장 `usage_scope = per_request` 행, `keepers/<name>/provider-inputs` 의 메시지별 sha256):

| 측정 | glm-5.3 | glm-5.3-flash |
|---|---|---|
| 같은 `routing_run_id` 안 요청의 캐시 적중 중앙값 | 99.5% (1,525건) | 96.4% (865건) |
| `routing_run_id` 첫 요청의 캐시 적중 중앙값 | 13~40% (145건) | 0% (200건) |
| run 첫 요청이 차지한 미적중 입력 토큰 | 86% (37.0M) | 77% (43.1M) |

만료 때문이 아니다. 턴 첫 요청이 직전 요청 끝에서 2분 안에 와도 glm-5.3 중앙값은 14.7%(65건)이고, 같은 run 안에서는 5~10분 간격도 99.6%다. 11-03 04:30Z 이후 턴 전환 186건에서 prefix 가 처음 바뀐 자리:

| 처음 바뀐 자리 | 건수 |
|---|---|
| Librarian working state (범위 앞이 움직임) | 57 |
| System | 41 |
| 직전 턴 assistant 메시지의 reasoning 제거 | 32 |
| 도구 정의 (대부분 배포로 설명이 바뀐 1회) | 24 |
| 직전 턴 tool 결과 강등 | 12 |
| 직전 턴 완료 인자 강등 | 7 |
| 그 밖 | 13 |

reasoning 제거 32건 중 25건은 바로 다음 메시지가 tool 결과 강등이다. 하나만 멈추면 prefix 는 한 메시지 뒤에서 끊긴다. 이전 요청 전체를 다시 쓸 수 있었던 것은 5건뿐이다.

비용: 강등하지 않은 이전 턴 결과가 범위에 남아 요청이 커진다. 11-04 Keeper 13명의 마지막 요청에서 16,384 B 이하 마커를 원문 크기로 되돌려 세면 메시지 바이트가 0~153% 늘어난다. 늘어난 부분은 직전 요청과 같은 prefix 라 캐시된다. 범위가 provider 한도에 닿으면 1번이나 2번이 답한다.

예외: `RFC-tool-results-age-out-of-context` 는 끝난 턴의 tool 결과 하나를 이 규칙의 예외로 둔다. 본문이 2 KB 이상인 결과는 그 턴이 끝난 뒤 첫 요청에서 마커가 되고, 이후 요청에서는 같은 마커로 나간다(`finished_turn_results`). 인자와 2 KB 보다 작은 결과는 이 절의 규칙을 그대로 따른다. Keeper 가 `artifact_read` 를 쓸 수 있을 때만 켜진다. 크기 거절 뒤 재전송은 이와 상관없이 거절된 요청의 결과 전부를 마커로 보낸다.

reasoning 제거는 이 RFC 의 조립 코드가 아니라 runtime 선언이 정한다. GLM 모델 선언이 `preserve-thinking = false` 면 `clear_thinking: true` 가 나가고, replay 정책이 최신 user 턴의 reasoning 만 남긴다(`Reasoning_dialect.apply_clear_thinking_replay_gate`). z.ai 는 Coding Plan endpoint 에서 reasoning 보존을 기본값으로 두고, 그 블록을 고치거나 순서를 바꾸면 캐시 적중이 떨어진다고 적는다(https://docs.z.ai/guides/capabilities/thinking-mode, 2026-11-04 확인). 이 개정의 이득은 선언이 reasoning 을 보존할 때 나온다.

### 3.4.2 측정 — 모델이 강등된 호출 인자를 호출 모양으로 따라 한다 (2026-11-05)

강등된 인자는 `{"_blob": {"sha256","bytes","mime","preview"}}` 로 나간다(`with_reference` 의 `ToolUse.input`). 모델이 보는 지난 호출이 도구 스키마에 없는 모양이 된다. 이슈 #47642 가 센 것이 이 모양으로 들어온 호출이다.

`docs/evidence/blob-input-2026-11/measure_blob_inputs.py` 로 10-19 ~ 11-04T19:10Z 를 쟀다. 정의와 한계는 그 폴더의 README 에 있다. "저장된 강등"은 강등된 인자 중 `sha256` 이름의 blob 이 같은 크기로 저장소에 있는 것이다. 모델이 지어낸 `_blob` 호출이 기록에 되돌아온 것은 이 blob 이 없어서 가려진다.

| 측정 | 값 |
|---|---|
| 저장된 요청 중 저장된 강등이 있는 요청 | 4,371 / 5,244 (83.4%) |
| 강등된 인자의 서로 다른 해시 | 12,855개, 이 중 12,313개(95.8%)는 blob 이 같은 크기로 있다 |
| 입력이 `_blob` 하나뿐인 호출 | 2,464건, 이 중 2,463건이 실행 전에 거절됐다 |
| 그중 네 필드가 다 있는 봉투 | 1,344건, `sha256` 의 blob 이 저장소에 있는 것은 7건 |
| 그중 진짜 인자를 `_blob` 아래에 넣은 호출 | 784건 |
| 그중 객체가 아닌 값 | 336건 |

한 Keeper 의 저장된 요청 두 개 사이에 든 호출은 뒤쪽 요청이 끝낸 턴의 호출로 세었다. 모델은 그 뒤쪽 요청의 `wire.model` 이다.

| 모델 | 저장된 강등이 있는 턴 | 호출 | 호출이 있던 턴 | 저장된 강등이 없는 턴 | 호출 |
|---|---:|---:|---:|---:|---:|
| deepseek-v4.1-flash | 1,093 | 951 | 502 (45.9%) | 388 | 0 |
| deepseek/deepseek-v4.1-flash-1017 | 668 | 23 | 15 (2.2%) | 19 | 0 |
| nvidia/nemotron-3.5-super-vl:free | 14 | 3 | 2 (14.3%) | 14 | 0 |
| glm-5.3 | 1,089 | 0 | 0 | 110 | 0 |
| glm-5.3-flash | 1,369 | 0 | 0 | 295 | 0 |
| kimi-k3.1-pro | 138 | 0 | 0 | 3 | 0 |
| mimo-v2.6-flash, minimax-m3.1-flash, qwen3.8-flash | 0 | 0 | 0 | 16 | 0 |

모델마다 따라 하는 정도가 다르다. GLM 두 모델은 저장된 강등이 있는 2,458턴에서 호출이 없고, deepseek-v4.1-flash 는 1,093턴 중 502턴에 호출이 있다. 저장된 강등이 없는 845턴에서는 어느 모델도 호출하지 않았다. 이 표는 같이 나타난다는 것까지만 보인다. 모델마다 Keeper 가 달라서 모델 차이만으로 읽을 수 없고, 턴을 끝낸 요청은 그 턴 앞쪽 호출의 강등된 인자도 담아서 호출이 많은 턴에 저장된 강등이 더 보일 수 있다. 호출 2,464건 중 표에 든 것은 977건이다. 나머지 1,487건은 10-28T11:08Z 까지의 호출이라 그 Keeper 의 저장된 요청이 아직 없었다.

저장된 강등이 마지막으로 보인 시각은 deepseek-v4.1-flash 11-04T01:50Z, glm-5.3 08:09Z, nemotron 08:39Z, glm-5.3-flash 08:59Z 다. 11-04T09:00Z 부터 19:10Z 까지는 저장된 요청 531개에 저장된 강등이 없다. §3.4.1 개정의 문서(#48123)와 코드(#48124)는 11-04T08:53Z 에 병합됐다. 서버를 언제 다시 띄웠는지는 기록에서 찾지 못했다. `_blob` 하나뿐인 호출의 마지막은 11-04T03:54Z 다(deepseek-v4.1-flash 는 00:21Z, 마지막 3건은 nemotron). 호출이 병합보다 5시간 먼저 멈췄으므로, 이 개정이 호출을 멈췄다고 볼 수 없다.

이 측정으로 정해지지 않는 것이 둘이다.

- 큰 쓰기를 하는 Keeper 가 deepseek 로 다시 돌 때 호출이 돌아오는지. 11-04T09:00Z 뒤 deepseek-v4.1-flash 의 저장된 요청은 294개이고 호출은 0건이지만, 그 요청이 큰 인자를 쓰는지는 보지 않았다.
- 모양을 지키는 강등(긴 문자열 값만 줄임)은 이 거절을 실행으로 바꾼다고 본다(추론, 재지 않았다). 모델이 지난 호출을 베끼면 줄어든 값이 그대로 실행된다. 지금의 실행 전 거절은 안전한 실패다.

이 절은 측정이고 결정이 아니다. 강등된 인자를 요청에 다시 넣는 설계는 이 표를 기준으로 삼는다. 표현을 바꾸는 일은 모델이 `keeper_artifact_read` 로 원문을 읽을 때 쓰는 `sha256` 참조와 prompt cache 에 닿으므로 이 RFC 를 고쳐서 정한다.

### 3.5 물질화와 실패

1단계는 포화 후보로 측정만 한다. 2단계는 cut 을 살아남은 강등 메시지에 대해서만 `Tool_blob_store.put` 한다.

`put` 실패 시 해당 메시지는 인라인으로 되돌린다. 그러면 실제 크기가 추정보다 **커지므로**, 물질화 후 반드시 재측정하고 초과 시 `project` 를 다시 돌린다. 조용한 통과 금지 — 실패는 typed 결과로 올라오고 카운터가 아니라 재조립으로 대응한다.

### 3.6 blob 수명 — 강등 blob 은 파생 데이터다

강등이 만드는 blob 은 durable 참조를 갖지 않는다 (전송 사본은 영속되지 않는다). `tool_blob_maintenance.mli` 의 계약상:

- GC 는 **startup 경계에서만** 돌고, `Delete_previous_candidates` 는 **이전 스냅샷의 후보였고 새 완전 스캔에서도 미참조인** 해시만 지운다 — 삭제까지 **연속 2 회 startup 스캔**이 필요하다.
- 그 사이 강등은 매 턴 같은 내용을 다시 `put` 한다. content-addressed 이므로 같은 sha 로 복원된다.

즉 강등 blob 은 **체크포인트에 원문이 살아 있는 파생 캐시**다. 지워져도 다음 강등이 되살린다.

알려진 한계: 모델이 **이전 턴의 마커 sha** 를 현재 전송 집합 밖에서 읽으려 하면 startup 2 회 이후 not-found 가 될 수 있다. `keeper_artifact_read` 가 typed not-found 를 반환해야 하며, 모델이 행동할 수 있는 신호여야 한다. 현행 window 는 그 내용을 상수 스텁으로 **회수 시도조차 불가능**하게 버리므로, 강등은 엄격한 개선이다.

`durable_consumer_basenames` 에 추가할 소비자는 없다 — 참조를 영속하지 않기 때문이다.

## 4. 검토한 대안

### 안 B — 쓰기 임계 인하 + 최근 구간 재수화

`default_externalize_threshold_bytes` 를 65,536 → 약 4,096 으로 낮추고, projection 에서 최신 유지 구간의 마커만 blob 에서 인라인으로 되돌린다.

- **유일하게 checkpoint 28.2 MB 도 줄이는 안이다.** 본 RFC 채택 후에도 durable 히스토리는 계속 자란다.
- 매 턴 해싱 없음 (blob 은 생성 시 1 회).
- 대신 durable 포맷이 바뀌고, **모델이 자기 턴의 tool 출력을 마커로 받으면 안 된다**는 보장이 새로 필요하다. 그 보장이 깨지면 모델이 자기 출력을 읽으려 `keeper_artifact_read` 를 호출하는 낭비가 매 턴 발생한다.
- ~~`Common.max_tool_output_bytes` 의 다른 소비자 blast radius 조사가 선행되어야 한다 (본 RFC 범위 밖, 미조사).~~ 2026-09-03 조사 완료: 프로덕션 소비자는 keeper status tail 하나뿐이었고, 그 자리는 자기 값을 갖도록 바뀌었다. 상수는 제거됐다.

채택하지 않는 이유는 롤백 비용이다. 본 RFC 는 projection 단계 제거로 되돌아가고, 안 B 는 durable 포맷을 되돌려야 한다. 다만 **checkpoint 크기 문제는 본 RFC 가 풀지 않는다**는 사실을 기록한다 — 후속 RFC 로 남긴다.

## 5. 비목표

- durable 히스토리 재작성.
- checkpoint 크기 축소 (안 B 의 영역).
- 중요도 점수 · 문자열 분류 · 휴리스틱 임계값 — RFC-0351 §2 원칙 2.

## 6. 검증

| 지표 | 현재 | 목표 |
|---|---|---|
| 인라인 tool 바이트 / 전송 바이트 | 71% (durable 기준) | 전송 기준 측정 후 확정 |
| 같은 예산에서 전송되는 원자 수 | 실측 필요 | 증가 |
| byte-cap bind rate | 8.3% (GLM 24.5%) | 감소, 그리고 **단조 증가 중단** |
| **prefix 안정성** | cut 이 바뀔 때만 변경 | **불변** |

필수 회귀 테스트:

1. **prefix 불변식** — 원자를 1 개씩 늘리며 전송 리스트의 *머리*가 `drop` 이 바뀔 때만 바뀌는지. 턴 경계가 움직여도 이미 보낸 tool 결과와 완료 인자가 그대로인지(끝난 턴의 결과를 마커로 보내는 Keeper 는 예외다. 그 결과가 한 번만 바뀌고 마커가 이후 요청에서 같은 바이트로 남는지를 본다). 초안의 "60 원자 경계에서만 바뀌는지"는 **잘못된 불변식**이었다: 오늘 그 경계에서는 prefix 가 아예 안 바뀌므로 버그가 있어도 통과한다.
2. **상한 건전성** — 임의 payload(ASCII / 한국어 / 0x00–0xFF 전 범위)에 대해 `upper_bound_demoted_bytes ≥ measure_message_bytes (물질화된 마커 메시지)`.
3. **블록으로 온 결과** — `content` 와 안쪽 `Text` 가 각자 마커가 되고 다른 블록은 그대로다. 어느 공급자 요청에도 원래 본문이 남지 않는다. 시험과 잡는 변형은 §3.1.2 의 「시험」 표다.
4. **`Invalid_marker` 제외** — 손상된 마커 모양 payload 는 그대로 둔다.
5. **`put` 실패 경로** — 인라인 복귀 후 재측정이 실제로 일어나고, 요청이 예산을 넘지 않는다.

## 7. 리스크

| 리스크 | 완화 |
|---|---|
| 상한이 하한이 되어 요청 초과 | §3.2 포화 후보를 실제 측정기로 통과. §6 테스트 2 |
| 블록으로 온 결과에서 측정기 감소와 레인의 감소가 다름 | §3.1.2 (가): 측정기는 "작아지는가"에만 답하고, 본문은 마커가 더 짧을 때만 바뀐다. §6 테스트 3 |
| 블록으로 온 결과가 끝난 턴마다 마커가 되어 모델이 다시 읽는 호출이 는다 | §3.1.2 배포 순서 3 에서 `keeper_artifact_read` 호출 수를 잰다 |
| prompt-cache 회귀 | §3.4.1 크기 거절 뒤에만 강등. 끝난 턴의 결과는 한 번만 바뀐다(§3.4.1 끝 단락). §6 테스트 1. 실패 시 머지 금지 |
| `preview_max` 변경이 상한을 깸 | §3.3 export 후 단일 참조 |
| `put` 실패 후 조용한 초과 | §3.5 재측정 필수. §6 테스트 5 |
| 강등 blob GC 후 not-found | §3.6 — 파생 데이터, 다음 강등이 복원. typed not-found 필요 |
| checkpoint 는 계속 자람 | 본 RFC 비목표. 안 B 후속 RFC |
