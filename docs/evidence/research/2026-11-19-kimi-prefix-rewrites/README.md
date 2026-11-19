# Kimi Coding Plan 사용량과 요청 앞부분 다시 쓰기 (2026-11-19)

[RFC-a-sent-request-prefix-changes-only-when-the-window-moves](../../../rfc/RFC-a-sent-request-prefix-changes-only-when-the-window-moves.md)의 측정 근거다.

질문: masc 가 Kimi Coding Plan(`kimi_coding`)을 런타임으로 쓰면 사용량이 빨리 오른다. Kimi 쪽 버그인가, masc 쪽 원인인가.

## 데이터

모두 운영 런타임 기록을 읽기만 했다. 경로는 `<base-path>/.masc/` 기준이다.

| 기록 | 경로 | 쓴 칸 |
|---|---|---|
| 요청별 토큰 | `costs/2026-11/<DD>.jsonl` | `usage_projection=raw_observation` 행만. `input_tokens`, `cache_read_tokens`, `cache_miss_input_tokens`, `output_tokens` |
| Kimi 사용량 창 | `provider_usage_history/2026-11/<DD>.jsonl` | `kimi_coding` 의 `five_hour` 창과 주간 창(`provider:usage (provider resetTime)`). 10분마다 읽은 `used/limit`(limit 100) |
| 턴의 요청 모양 | `keepers/<k>/provider-inputs/2026-11/<DD>.jsonl` | 턴마다 요청 하나. system 프롬프트, 도구 schema, 메시지마다 sha256 참조 |
| 참조한 본문 | `tool_blobs/<sha[:2]>/<sha>` | system 프롬프트의 `### ` 제목과 도구 이름만 읽었다 |

- 확인 시각: 2026-11-19 03:00Z 무렵. 기간을 고정하지 않은 스크립트는 다시 돌리면 값이 조금 달라진다.
- source head: `e76a4891be836`(main). 운영 서버 빌드는 이 head 보다 앞이다.
- `outputs/` 는 정제본이다. Claude 계정 provider 이름 넷은 `claude_account_A` ~ `claude_account_D` 로 바꿨다. 스크립트를 다시 돌리면 원래 이름이 나온다.

## 실행

```
cd docs/evidence/research/2026-11-19-kimi-prefix-rewrites/scripts
python3 -I quota_regression.py <base-path>/.masc
python3 -I first_request_causes.py <base-path>/.masc
python3 -I within_turn_prefix_loss.py <base-path>/.masc
python3 -I stable_prefix_hits.py <base-path>/.masc <keeper> ...
python3 -I turn_pair_changes.py <base-path>/.masc
python3 -I prefix_change_sources.py <base-path>/.masc
python3 -I weekly_window.py <base-path>/.masc
```

출력은 `outputs/<script>.txt` 에 있다.

## 결과

1. **Kimi 사용량은 미적중 입력과 출력이 올린다** (`quota_regression.txt`).
   11-18 10:00Z~11-19 01:40Z 의 10분 구간 102개를 회귀했다.
   5시간 창 증가 % ≈ 2.25 × 미적중 입력(M) + 25 × 출력(M) + 0.01 × 적중 입력(M), R²=0.868.
   적중 계수를 0 으로 두면 2.5 / 25, R²=0.855 다. 0.05 로 두면 R²=0.651, 0.1 이면 음수다.
   계수는 거친 격자에서 고른 값이다. 적중 입력은 미적중의 1/200 이하로 센다.
2. **Kimi 서버 캐시는 정상이다** (`within_turn_prefix_loss.txt`).
   같은 턴 안 연속 요청 1,729쌍(11-17~19) 중 앞 요청 입력의 절반도 못 읽은 것은 9쌍(0.5%)이다.
3. **턴 첫 요청이 미적중이 되는 까닭** (`first_request_causes.txt`).
   턴마다 요청 하나를 남긴 기록에서 연속한 두 턴의 요청을 견줬다. 앞에서부터 처음 달라진 곳으로 나눴다.
   `first_request_causes.py` 의 2.5 / 20 / 0.01 가정으로 2026-11-18 10:00Z ~ 2026-11-19 01:40Z 를 셌다. 추정 합계는 58.6% 다. 별도 회귀에 포함된 102개 구간의 관측 증가 합은 57.0% 다. 회귀와 비용 추정에 포함된 요청 집합은 다르다. 다른 두 계수를 고정하고 출력만 회귀 적합값 25로 두면 출력 몫은 약 18.0%p, 추정 합계는 약 62.2% 다.

   | 처음 달라진 곳 | 턴 | 5시간 창 % | 그 턴 첫 요청 적중 |
   |---|---|---|---|
   | 이력 첫 메시지(창 시작이나 하던 일 변경) | 45 | 7.8 | 29.2% |
   | 이력 가운데(끝난 턴의 결과·인자가 마커로 바뀜) | 31 | 5.2 | 40.4% |
   | system 프롬프트 | 17 | 5.0 | 17.1% |
   | 도구 배열 | 9 | 2.4 | 23.9% |
   | 런타임이 바뀜 | 3 | 0.9 | 25.4% |
   | 덧붙기만 함 | 4 | 0.4 | 62.5% |
   | 짝 없음 | 2 | 0.2 | 44.2% |

   나머지는 턴 안 미적중 18.4%, 출력 14.4%, 적중 읽기 4.0% 다.
4. **무엇이 바뀌었나** (`prefix_change_sources.txt`). 같은 시간 범위로 자른 provider 입력 기록의 연속 110쌍이다. `turn_pair_changes.txt`의 121쌍은 11-18~19 UTC 일별 파일을 시간 범위로 자르지 않고 견준 별도 탐색이다.
   - system 프롬프트가 바뀐 20쌍은 모두 `### Admitted Request Source` 절이 붙거나(10) 떨어졌다(10).
   - 도구 배열이 바뀐 29쌍 중 20쌍은 `keeper_tool_search` 설명의 held-back 이름 목록에 `keeper_receipt_wait` 가 들고 났다. 그중 5쌍은 `keeper_memory_write` 나 일정 도구도 같이 들고 났다.
   - 이 20쌍은 system 이 바뀐 20쌍과 같은 쌍이다. 채팅 요청을 받은 턴은 출처 절과 `keeper_receipt_wait` 를 함께 받고, 스스로 깬 턴은 둘 다 없다.
   - 나머지 9쌍은 다른 도구 한두 개가 붙거나 떨어졌다.
5. **앞부분이 그대로였던 턴** (`stable_prefix_hits.txt`).
   system·도구가 같고 이력이 덧붙기만 한 턴의 첫 요청 적중이다.
   Claude(`claude_account_A`) 91~92%(138턴), GLM 68~80%(30분 안 78턴), Kimi 76~79%(10분 안 3턴)다.
   Kimi 는 표본이 셋이라 Kimi 캐시가 턴 사이에 얼마나 오래 남는지는 말하지 못한다.
6. **주간 창** (`weekly_window.txt`).
   11-11 주는 11-15 20:38Z 에 100% 가 됐다. 리셋(11-18 10:10Z) 2.6일 전이다.
   11-04 주는 리셋 1.2일 전(11-10 06:31Z)에 100% 였다. 그 주 앞쪽 11-04~07 에는 masc 장부에 Kimi 요청이 없었다.
   11-18 주는 16시간 만에 27% 다(11-19 02:24Z).

## 하지 않은 것과 한계

- Kimi 의 사용량 계산식은 공개되어 있지 않다. 공식 문서는 「actual token consumption」까지만 적는다. 위 식은 회귀로 얻은 값이고, 신뢰도는 Medium 이다. 사용량 창의 해상도는 1% 이고 masc 밖 사용이 섞인다.
- 주간 창 회귀는 R²=0.29 로 약해서 결론에 쓰지 않았다.
- `prompt_cache_key` 는 보내 보지 않았다. 턴 안 손실이 0.5% 라 주원인이 아니다.
- 턴 사이 간격별 Kimi 캐시 수명은 재지 못했다(표본 셋).
- 요청 본문의 내용은 읽지 않았다. system 프롬프트는 제목만, 도구는 이름만 셌다.
- provider 입력 기록은 턴의 마지막 요청이다. 요청마다 `Keeper_attempt_request_evidence.observe_wire` 가 앞 기록을 바꾼다. 그래서 결과 3·4 는 앞 턴의 마지막 요청과 다음 턴의 마지막 요청을 견줬다.
  - 다음 턴 가운데 불러온 도구(도구 배열만 바뀐 9쌍 중 붙은 6쌍)는 턴 경계를 깨지 않았을 수 있다. 그러면 결과 3 의 도구 배열 줄 일부는 다른 줄의 몫이다.
  - 첫 요청 미적중 합계는 사용량 기록에서 셌으므로 바뀌지 않는다.
