# Jev 판정 요청 첫 시험: won-chik, 2026-10-28

[RFC-keeper-recall-reaches-the-turn](../../rfc/RFC-keeper-recall-reaches-the-turn.md) 층 0 의 측정 1(Jev 용량)과 2(반복 일치)를 한 Keeper 로 처음 해 본 결과다.

## 무엇을 했나

- `scripts/keeper-recall-jev-probe.py` 로 `won-chik` 의 현재 사실 56개(claim 66KB)를 RFC §4.2 모양의 요청으로 Jev 에 보냈다. 운영자가 04:1xZ 무렵 직접 실행했다. 정확한 시각은 기록하지 않았다.
- 명령:

  ```bash
  python3 -I scripts/keeper-recall-jev-probe.py ~/me/.masc/config/keepers/won-chik.memory-current.json \
    --send --allow-send-for won-chik --runtime-toml ~/me/.masc/config/runtime.toml --timeout 60 --repeat 3
  ```

- 후보는 실제 사실이고 목적(turn input)은 합성 문장이다("리뷰어가 열린 PR 의 판정을 요청한다"). 실제 턴 입력이 아니다.
- 출력 원문은 [won-chik.txt](won-chik.txt) 다. `won-chik` 는 이미 Jev 로 기억 판정 요청을 보내는 20명 중 하나다.

## 결과

| 조각 | 후보 | 요청 본문 | `state` | 입력 토큰 | 걸린 시간 |
|---|---|---|---|---|---|
| 1 | 42 | 81.4KB | 59.5KB | 27,451 | 0.34~0.52초 |
| 2 | 14 | 23.1KB | 15.8KB | 7,937 | 0.24~0.31초 |

- 세 번 모두 HTTP 200 이었다. 두 조각을 동시에 보낸 전체 시간은 0.34~0.53초다.
- 요청에 `jev-latest` 를 썼고 응답한 모델은 `jev-1.14.0` 이다.
- 입력 토큰당 요청 본문은 조각 1이 2.97바이트, 조각 2가 2.91바이트다. 이미 보낸 작은 판정 요청 1,623건의 중앙값은 2.04바이트였다(`store-report.txt`). 같은 Jev 라도 요청 모양과 내용에 따라 다르다.
- 답 168개(56개 × 3회)의 라벨은 `needed` 17(10%), `maybe_needed` 18(11%), `not_needed` 133(79%)이다.
- 같은 입력으로 세 번 보냈을 때 56개 중 2개(3.6%)의 라벨이 바뀌었다. 평균 확신도는 0.56 이다. 어느 후보가 바뀌었는지는 이번 실행에 출력되지 않았다. 스크립트를 고쳐서 다음 실행부터 후보 id 와 회차별 라벨, 확신도를 출력한다.

## 읽는 법과 한계

- 한 Keeper, 합성 목적, 3회다. 라벨이 바뀐 2개는 경계에 있는 후보일 수 있고, 회차를 늘리면 비율이 달라진다.
- 확인한 것: 본문 81KB, 입력 27k 토큰 요청을 받아들이고 0.5초 안에 응답한다. 10초 제한과 비교해 여유가 크다.
- 확인하지 못한 것:
  - 한도 가까이나 한도를 넘는 요청이 어떻게 거절되는지(오류 본문).
  - 다른 Keeper 의 토큰 밀도. 조각 크기를 60KB 에서 얼마까지 키울 수 있는지는 이에 달렸다.
  - 여러 Keeper 가 동시에 보낼 때의 지연과 429.
  - 실제 턴 입력으로 판정했을 때의 라벨.
- 다음 시험은 RFC §5 층 0 의 1, 2 를 Keeper 몇 명으로 넓히는 것이다.
