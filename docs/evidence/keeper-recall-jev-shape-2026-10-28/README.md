# Jev 판정 요청 모양 시험: 코덱이 만드는 요청, 합성 후보, 2026-10-28

[RFC-keeper-recall-reaches-the-turn](../../rfc/RFC-keeper-recall-reaches-the-turn.md) §4.2 의 요청을 코덱(`keeper_memory_recall_jev_codec`)이 만드는 모양 그대로 Jev 에 보내 본 결과다. 층 0 은 12자 질문 키와 질문 56개 이하 요청만 보냈다([층 0 시험](../keeper-recall-jev-probe-2026-10-28/README.md)). 코덱은 71자 `sha256:` memory id 를 질문 키로 쓰고 한 요청에 질문을 100개 넘게 싣는다. Jev 가 이 모양을 받는지 알 수 없었다.

## 한눈에 보기

후보는 모두 합성 문장이다. 후보 하나의 claim 은 60바이트다. 본문 크기의 1KB 는 1000바이트다.

| 시험 | 질문 키 | 후보(질문) 수 | 요청 본문 | 결과 | 입력 토큰 | 걸린 시간 |
|---|---|---|---|---|---|---|
| 1 | 12자 digest | 120 | 79.2KB | HTTP 200 | 27,243 | 0.52초 |
| 2 | 71자 `sha256:` | 120 | 100.5KB | HTTP 200 | 39,334 | 0.53초 |
| 3 | 71자 `sha256:` | 300 | 250.8KB | HTTP 400, `max_tokens_exceeded` | 없음 | 0.30초 |
| 3 의 반쪽 | 71자 `sha256:` | 150, 150 | 125.5KB 둘 | 둘 다 HTTP 200 | 49,032 둘 | 0.67초, 0.57초 |

응답은 모두 `jev-1.14.0` 이 냈다. 시험 1, 2 는 질문 120개 모두 답이 왔다.

## 읽는 법

- 71자 `sha256:` 질문 키(콜론 포함)와 한 요청의 질문 120개를 받아들였다. 150개짜리 요청도 받아들였다. 질문 수에 따로 상한이 있는지는 보지 못했다. 300개 요청이 거절된 이유로 응답이 알린 것은 크기(`max_tokens_exceeded`)다.
- 300개 요청의 거절은 HTTP 400 이고 `detail` 이 `{"error_type": "max_tokens_exceeded"}` 였다. 클라이언트가 용량 거절로 인정하는 모양이다. `Typesafeai_client.failure_kind` 는 400 이고 본문의 `detail.error_type` 이 `max_tokens_exceeded` 인 시도만 용량 거절로 센다(`lib/typesafeai/typesafeai_client.ml`). 프로브는 `detail` 만 출력해서 본문 전체는 남지 않았다.
- 거절된 300개를 150개씩 둘로 나누자 둘 다 받아들여졌다. RFC §4.6 의 반으로 나누는 규칙이 이 모양에서 쓸 수 있다. 요청 수는 1에서 3으로 늘었다(거절 1, 수락 2).
- 입력 토큰당 바이트가 키 모양에 따라 달랐다. 후보 120개 요청에서 12자 키는 2.91, 71자 키는 2.56 이다. 후보 하나당 입력 토큰은 227개와 328개다. 키를 12자에서 71자로 바꾸면 후보마다 177바이트가 늘고(id 59자를 세 곳에 쓴다: `state` 의 후보 줄, 질문 키, 질문 지시문) 입력 토큰이 101개 는다. 늘어난 바이트만 보면 토큰 하나에 1.76바이트다.
- 이 합성 후보(claim 60바이트)로는 요청당 64k 토큰에 닿는 후보 수가 약 195개다(64,000 / 328). 150개는 받아들여졌고 300개는 거절됐다. 후보 줄이 짧고 후보가 많은 Keeper 는 `STATE_BYTES_PER_PIECE` 이내의 조각도 이 한도에 닿을 수 있다. 조각 크기는 후보 줄만 세기 때문이다(RFC §4.2).

## 무엇을 했나

- `scripts/keeper-recall-jev-probe.py` 의 합성 모드(`--synthetic`, `--claim-bytes`, `--key-shape`)로 후보를 만들어 보냈다. 후보는 채움 문장이고 Keeper 의 데이터는 나가지 않는다(출력의 `synthetic filler only`). 합성 모드는 파일을 읽지 않는다. `--turn-input-file` 을 함께 쓰면 파일을 읽기 전에 사용법 오류로 멈춘다. 질문은 층 0 에서 잰 두 선택지 모양이다.
- 운영자가 자기 셸에서 직접 실행했다. 2026-10-28 16:08Z 이후이고 정확한 시각은 기록하지 않았다. 명령:

  ```bash
  cd .worktrees/keeper-recall-jev-shape
  for k in digest12 memory-id; do
    python3 -I scripts/keeper-recall-jev-probe.py --synthetic 120 --claim-bytes 60 --key-shape $k --shape two --piece-kb 1000 --send
  done
  python3 -I scripts/keeper-recall-jev-probe.py --synthetic 300 --claim-bytes 60 --key-shape memory-id --shape two --piece-kb 1000 --send
  ```

- 출력 원문은 [synthetic-shape.txt](synthetic-shape.txt) 다.

## 이 시험이 보여 주지 못하는 것

- 후보가 채움 문장이라 입력 토큰당 바이트가 실제 claim 과 다를 수 있다. 층 0 의 실제 claim 은 12자 키에서 2.91~3.07 이었다. 실제 Keeper 의 71자 키 요청은 층 1c 에서 `capacity` 거절 수로 잰다.
- 질문은 (a) 두 선택지 하나뿐이다. (b)와 (c)의 문구는 보내지 않았다.
- 같은 요청을 되풀이하지 않았다. 라벨이 바뀌는 정도는 이 시험으로 알 수 없다.
- 요청마다 목적(purpose)이 합성 문장이다. 실제 턴 입력이 아니다.
- 여러 Keeper 가 동시에 보낼 때의 한도와 지연은 보지 않았다.
