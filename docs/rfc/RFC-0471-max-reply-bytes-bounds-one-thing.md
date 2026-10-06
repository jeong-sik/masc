---
rfc: "0471"
title: "max_reply_bytes 는 worker 가 보낸 메시지 한도 하나만 뜻한다"
status: Draft
created: 2026-10-06
updated: 2026-10-06
author: vincent + claude
supersedes: []
superseded_by: null
related: ["#41259", "#41260", "#41262", "#41269", "#41197"]
implementation_prs: []
---

# RFC-0471 — max_reply_bytes 는 worker 가 보낸 메시지 한도 하나만 뜻한다

## 1. 문제

매니페스트의 `max_reply_bytes` 하나가 서로 다른 일을 11가지나 한다. 이름은 "worker 응답 한도"인데,
README(`addons/README.md`)는 그중 3가지만 적어 두었다. 아래는 코드를 읽어서 정리한 것이고, 실행해서 잰 값은 아니다.

| # | 쓰이는 곳 | 막는 것 | 맞는 쓰임인가 |
|---|---|---|---|
| 1 | `lane_addon_worker.ml` → `Mcp.connect ~max_response_bytes` | worker 가 보낸 메시지 읽기, host 가 worker 에게 보내는 응답 프레임 | 맞다. 이름이 뜻하는 일이다 |
| 2 | `lane_addon_store.ml` `retained_read_limit` (`2*max + 24`) | 저장된 관측 기록을 다시 읽을 때 | 맞다. 입력 한도와 출력 한도의 합에서 나온다 |
| 3 | `lane_addon_runtime.ml` 의 action 입력 검사 | host 가 worker 에게 주는 action 입력. 같은 입력이 영수증으로 디스크에 저장된다 | 절반만 맞다. 보내는 쪽 한도로는 아니지만, 보관 한도의 구실은 있다 |
| 4 | `lane_addon_sources.ml` 의 소스 수집 예산 | host 가 worker 에게 주는 입력 | 아니다 |
| 5 | `lane_addon_sampling.ml` 의 요청·결과 blob | host 가 직접 저장하는 모델 요청과 결과 | 아니다. worker 에게 보내는 응답이 아니다 |
| 6 | `lane_addon_sampling.ml` `with_observation` 의 읽기 예산 | 한 관측에 붙은 증거 blob 전체를 다시 읽는 합계 | 아니다. 소스 스냅샷과 모델 요청이 합쳐서 한도를 넘으면, 문제가 없는데도 관측 전체가 실패할 수 있다. 코드를 읽고 추정한 것이고 재현하지는 못했다 |
| 7 | `lane_addon_worker.ml` 의 Docker `inspect`·`create` 출력 | host 가 실행한 docker CLI 출력 | 아니다. 값이 작으면 `create` 가 실패한다 |

7번은 실제 버그다. 코드 주석(`lane_addon_worker.ml` 약 293행)이 "create 가 효과를 내고 나서 stdout 을 못 받을 수 있다"고
적었고, 이 상황을 치우려고 `recover_stop` 이 따로 있다. 한 값이 11가지 일을 하면, 그 값을 한 번 올릴 때
나머지 10가지의 노출도 같이 커진다. `fusion-report` 가 8 MiB 로 올린 이유가 보고서 크기인데, 그 값이
입력·저장·Docker 출력에도 똑같이 적용된다.

## 2. 다른 제품은 어떻게 하나

받는 쪽, 보내는 쪽, 저장 쪽 한도를 따로 둔다.

- **gRPC**: 받는 한도와 보내는 한도가 별도 인자다. 받는 한도(`GRPC_ARG_MAX_RECEIVE_MESSAGE_LENGTH`)의 기본값은
  4 MiB이고, 보내는 한도(`GRPC_ARG_MAX_SEND_MESSAGE_LENGTH`)는 `-1`(제한 없음)이 기본이다.
  [gRPC core 인자 문서](https://grpc.github.io/grpc/core/group__grpc__arg__keys.html).
  받는 쪽 한도가 메모리를 지킨다. 자기가 만드는 메시지에는 같은 한도를 걸지 않는다.
- **MCP Go SDK**: `MaxMessageBytes` 는 "자식 프로세스 stdout 에서 읽는 프레임"만 막고, 기본값은 제한 없음이다.
  이유는 메모리 고갈 방지다. JSON 디코딩 전에 크기를 본다
  ([go-sdk #985](https://github.com/modelcontextprotocol/go-sdk/pull/985), 같은 기능이 #1205 로 합쳐졌다고 PR 에 적혀 있다).
- **MCP TypeScript, Python SDK**: 검색 결과 요약으로만 봤다. TypeScript stdio 읽기 버퍼는 10 MiB 로 넘으면 연결을 닫고,
  Python streamable-http 는 4 MB 를 코드에 고정했다
  ([python-sdk #1012](https://github.com/modelcontextprotocol/python-sdk/issues/1012)). 둘 다 받는 방향 한도 하나다.
- **MCP sampling 규격**: 결과 크기 한도가 없다. 정해진 상한은 `maxTokens` 이고 client 가 반드시 지켜야 한다
  ([sampling](https://modelcontextprotocol.io/specification/2026-07-28/client/sampling)).
  에러 메시지 크기에 대한 규칙도 없다. 이 규격에서 sampling 은 2026-07-28 판부터 deprecated 다.
- **LSP**: 기본 프로토콜에 최대 메시지 크기가 없다. 구현마다 따로 정한다. 검색 결과 요약으로만 봤다.
- **Kubernetes**: 컨테이너 cpu/memory 한도와 로그 크기(`containerLogMaxSize` 기본 10Mi, `containerLogMaxFiles` 기본 5)는
  따로 설정한다. 로그는 kubelet 설정이다. 컨테이너마다 선언하지 않는다
  ([logging architecture](https://kubernetes.io/docs/concepts/cluster-administration/logging)).

### 에이전트 제품 (Hermes Agent, OpenClaw)

masc 와 가장 가까운 제품이라 설정 문서를 직접 읽었다. 둘 다 한도마다 이름이 있고, 이름이 막는 대상을 말한다.

| 막는 대상 | Hermes Agent | OpenClaw |
|---|---|---|
| 명령 출력 | `tool_output.max_bytes` 50000 (넘으면 앞 40%, 뒤 60% 를 남긴다) | `toolResultMaxChars` (모델 context 크기에서 자동 계산) |
| 파일 읽기 | `file_read_max_chars` 100000, `tool_output.max_lines` 2000 | `memoryGetMaxChars` 12000 |
| MCP 도구 결과 | `tool_budget.mcp_result_size_chars` 50000 (넘으면 "spillover") | — |
| 이미지, 첨부 | — | `imageMaxDimensionPx` 1200, `mediaMaxMb` 5, `pdfMaxBytesMb` 10 |
| 컨테이너 자원 | `container_cpu` 1, `container_memory` 5120 MB, `container_disk` 51200 MB | `docker.cpus` 1, `docker.memory` 1g, `docker.pidsLimit` 256 |

출처: [Hermes 설정](https://hermes-agent.nousresearch.com/docs/user-guide/configuration),
[OpenClaw 설정](https://openclaw.cc/en/gateway/config-agents). 값은 각 제품의 기본값이고, 그 값이 어떻게 정해졌는지는 문서에 없다.

masc 에 쓸 만한 것은 값이 아니라 모양이다.

- 한도 하나가 한 가지만 막는다. 명령 출력, 파일 읽기, MCP 결과, 이미지가 각자 이름을 가진다.
- 컨테이너 자원은 제품 전체의 기본값이다. 패키지마다 적지 않는다. OpenClaw 는 에이전트별 덮어쓰기를 허용한다.
  masc 는 `cpus`, `memory_bytes`, `pids` 를 11개 매니페스트에 모두 적게 하고, 그중 10개가 같은 값이다.
- 한도를 넘으면 거절하지 않고 줄이거나 따로 둔다(앞뒤만 남기기, 파일로 spillover). 이 점은 masc 에 그대로 쓸 수 없다.
  masc 는 결과를 증거로 남기고 다른 패키지가 그 증거를 검증한다. 일부만 남기면 증거가 바뀐다. 줄이는 쪽이 아니라
  "거절하거나 별도 증거 blob 으로 두는" 쪽이 맞다(열린 질문 5).
- 두 제품은 에러 메시지가 프레임에 들어가는지 재지 않는다.

공통점(인프라와 에이전트 제품 모두): 한도는 **받는 방향의 메모리 보호**에 걸고, 자기가 만드는 데이터와 저장에는 같은
숫자를 쓰지 않는다. 저장과 자원은 별도의 운영 설정이 맡는다.

## 3. 제안

`max_reply_bytes` 는 **worker 가 보낸 메시지를 읽을 때의 한도**(위 표 1번)와, 거기서 파생된 값(2번)만 뜻한다.

| 쓰이는 곳 | 바꾼 뒤 |
|---|---|
| 3. action 입력 | worker 에게 보내는 쪽 한도로는 쓰지 않는다. 다만 입력 전체가 `receipt.action` 으로 호스트 디스크에 저장되므로(`lane_addon_action.ml` 의 `receipt`) 보관 한도는 필요하다. 이름이 막는 대상을 말하는 호스트 설정 하나(열린 질문 1 의 안전선과 같은 종류)로 옮긴다. 입력 검증은 package 가 선언한 스키마가 계속 맡고, worker 메모리는 `memory_bytes` 가 지킨다 |
| 4. 소스 수집 | 같다. 소스마다 "수집 못 함" 항목을 남기는 동작은 그대로 둔다 |
| 5. 모델 요청·결과 blob | 이 한도를 쓰지 않는다. 텍스트 응답은 `maxTokens` 가 이미 상한이다. 이미지 응답을 얼마나 남길지는 아래 열린 질문 |
| 6. 증거 읽기 합계 | 디스크에서 다시 읽어 대조하지 않는다. 한 관측 안에서 broker 가 발급한 요청 참조를 메모리에 두고 대조한다 |
| 7. Docker 출력 | 한도를 걸지 않거나 host 고정 상수 하나로 둔다. host 가 직접 실행한 CLI 이고 출력이 몇십~몇 KB 다. `recover_stop` 에 `max_reply_bytes` 를 넘기는 배선도 같이 사라진다 |

이 표와 별개로 하나 더 있다. `cpus`, `memory_bytes`, `pids` 는 host 기본값을 하나 두고 매니페스트는 바꿀 때만 적게 한다
(위 두 제품과 같은 모양). 지금은 4개 필드가 모두 필수라서 10개 패키지가 같은 값을 복사해 둔다. 이 값들은 매니페스트와 함께
revision 해시에 들어가므로, 기본값을 바꾸면 해시가 바뀐다. 따로 판단한다.

저장된 바인딩에는 이미 `max_reply_bytes` 가 들어 있다. 이 변경은 값의 의미를 줄이기만 하고 필드는 바꾸지 않는다.
따라서 호환 코드는 필요 없다. 필드 이름을 `max_message_bytes` 로 바꾸는 일은 이 RFC 범위가 아니다. 이름 변경은 revision
해시가 바뀌므로 따로 판단한다.

## 4. 열린 질문

1. 모델 응답(특히 이미지)을 디스크에 얼마나 남기나? **안전선으로 둔다는 방향으로 정리했다**(사용자 확인 필요).
   - `maxTokens` 는 텍스트에만 상한이라, 이미지에는 상한이 없다. 그래서 안전선 하나는 둔다.
   - 안전선은 매니페스트가 아니라 host 설정 하나이고, 이름이 막는 대상을 말한다(예: 보관하는 모델 응답 크기).
   - 기본값은 지금 실제로 적용되는 값(대부분의 패키지에서 4 MiB)을 그대로 쓴다. 새 숫자를 정하지 않으므로 기존 패키지의
     동작이 바뀌지 않는다. 다른 제품의 기본값(Hermes 50000자, OpenClaw 5 MB)은 근거가 문서에 없어서 가져오지 않는다.
   - 넘으면 줄이지 않고 거절한다(`invalid_response`로 남기고 증거는 그대로). 증거를 바꾸면 안 되기 때문이다(5번).
2. 성공 응답이 한도 가까이에 있을 때 host 는 `answered` 로 저장하는데 transport 가 에러로 바꿔 보내는 불일치(#41262)는
   이 RFC 로 사라지지 않는다. 저장 쪽 측정을 걷어내면 측정 자 하나(transport)만 남지만, transport 의 대체를
   host 가 알지 못하는 문제는 그대로다. 별도 결정이 필요하다.
3. sampling 이 MCP 에서 deprecated 라서, 이 기능에 계속 투자할지는 이 RFC 밖의 결정이다(`docs/design/lane-addon-model-boundary.md`
   에 이미 적혀 있다). 대안은 host 가 모델 접근을 직접 제공하는 쪽이다. 이 RFC 는 어느 쪽을 택하든 `max_reply_bytes` 의
   의미를 좁히는 것이 맞다는 가정만 둔다.
4. #41197 의 매니페스트 최소값: 이 RFC 의 입장에서는 필요하지 않다. 값이 너무 작으면 첫 사용 지점
   (`lane_addon_sources.ml`, `lane_addon_runtime.ml`, `addons/protocol.py`)이 이미 명확한 에러로 거부한다.
   실제 하한은 소스 개수와 식별자 길이에 달려 있어서 고정 숫자가 추측값이 된다.

5. 한도를 넘는 결과를 거절할지, 별도 증거 blob 으로 두고 참조만 줄지. Hermes 의 spillover 와 같은 모양이다. 증거가 바뀌면 안 되므로
   일부만 남기는 방식은 쓸 수 없다. 모델 응답과 소스 스냅샷에 적용할 수 있는지 정해야 한다.

## 5. 검증

- 3번: 한도보다 큰 action 입력이 스키마만 통과하면 worker 에게 전달되는지.
- 5번: 한도 근처의 모델 응답이 `invalid_response` 로 바뀌지 않고 저장되는지.
- 6번: 소스 스냅샷 + 모델 요청 여러 개가 합쳐서 한도를 넘어도 관측이 실패하지 않는지. 다른 관측의 요청 참조는 거부되는지.
- 7번: `max_reply_bytes` 를 작게 둬도 컨테이너 `create` 가 실패하지 않는지.
- 1, 2번: worker 가 한도를 넘는 메시지를 보내면 지금처럼 거부되는지(바뀌지 않아야 한다).

## 6. 구현 순서

한 번에 하나씩 쪼갠다. 각각 독립적으로 되돌릴 수 있다.

1. 7번 Docker 출력(실제 버그, 영향 범위가 가장 좁다).
2. 3번 action 입력과 4번 소스 수집.
3. 6번 증거 읽기 합계.
4. 5번 모델 요청·결과. 열린 질문 1 이 정해진 뒤에.

## 7. 하지 않는 것

- 한도를 없애는 것이 목적이 아니다. 받는 방향 한도(1번)는 그대로이고, 메모리 보호의 근거도 그대로다.
- 매니페스트 필드 이름과 기존 설치 데이터는 건드리지 않는다.
- 같은 무리의 중복 검사 제거(#41269)와, 에러 경로 예산 삭제(#41259, #41260)는 이 RFC 와 별개로 진행됐다.
