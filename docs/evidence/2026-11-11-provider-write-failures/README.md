# provider 요청이 쓰는 도중 끊긴 사이클의 측정 (2026-11-11)

[RFC-0492](../../rfc/RFC-0492-provider-connections-are-reused-from-one-process-cache.md) §1.6 의 측정 기록이다. 정정이나 재측정으로 이 폴더를 바꾸지 않는다. 새 측정은 새 폴더에 둔다.

- 날짜와 시각은 UTC 다. 스크립트는 2026-11-11T13:52Z 에 돌렸고, 캐시 통계도 같은 시각에 읽었다.
- 입력은 한 장비의 서버 하나가 남긴 `<base-path>/.masc/logs/system_log_2026-11-11.jsonl` 과 `<base-path>/.masc/keepers/<keeper>/runtime-manifests/` 다. 대상 Keeper 는 쓰기 실패가 있었던 11개다.
- 쓰기 실패 49건의 구간은 01:08Z~10:49Z 다. 이 구간에 서버가 여러 번 재시작돼서 실행 binary 의 commit 하나로 묶지 못한다. 이 폴더가 든 branch 의 base 는 `origin/main` `2fa106d7ba3f` 다.
- 캐시 통계의 서버는 uptime 3시간 7분이라 10:46Z 쯤 부팅했다. 쓰기 실패 49건 중 그 뒤의 것은 10:49:42Z 의 `ollama_cloud` 1건뿐이다.

## 재현

```
python3 -I provider_write_failure_join.py <base-path>/.masc/logs/system_log_2026-11-11.jsonl <base-path>/.masc/keepers
```

스크립트는 읽기만 한다. 서버가 오래된 로그와 manifest 를 지우고 로그는 계속 자라서 같은 입력을 다시 못 받는다. 보존한 것은 [result-2026-11-11T1352Z.txt](result-2026-11-11T1352Z.txt) 다. 캐시 통계는 서버의 `/health?full=1` 에서 읽은 `provider_connection_cache` 이고 같은 파일 끝에 있다.

## 읽은 값

| 값 | 결과 |
|---|---|
| 그날 실패한 Keeper 사이클 | 380건 |
| 그중 `Broken pipe, "writev"` 로 끝난 사이클 | 49건. `glm-coding` 47, `ollama_cloud` 2 |
| 49건 중 실패 전에 도구 결과 주입이 있던 턴 | 49건 |
| 같은 Keeper 들의 기준선, 도구 결과 주입이 있던 턴 | 성공한 턴 45%(190/426), 실패한 턴 전체 42%(88/210) |
| 49건 중 같은 turn id 에 run 단위 재연결 이벤트가 있던 것 | 2건. 둘 다 재연결 뒤에 새 run(`turn_started`)이 시작됐고 실패는 그 새 run 에서 났다. 실패한 run 이 재연결 run 이던 것은 0건. 재연결은 실패보다 6,146초와 9,325초 앞이다. 두 실패는 07:18:33Z 와 07:18:34Z 다 |
| 마지막 도구 결과 주입부터 `runtime_failed` 까지 | 중앙값 112초. 5초 미만 3, 5~15초 2, 15~25초 2, 25~60초 6, 60초 이상 36 |
| 다른 Keeper 의 쓰기 실패가 가까이 있던 쓰기 실패 | 30초 안 10건(실패가 구간에 고르게 퍼졌다면 8%), 120초 안 32건(28%) |
| 캐시(부팅 약 10:46Z 부터 3시간 7분) | 재사용 608번, 새로 연 것 43번. 실패로 닫은 연결(`request_failed`) 3개는 모두 재사용한 연결, 새 연결은 0개 |

## 읽을 때의 한계

- 쓰기 실패는 로그 문구(`Broken pipe, "writev"`)로 가렸다. 지나간 로그를 재는 방법이고, 제품 코드가 문구를 읽어도 된다는 근거가 아니다.
- 사이클 줄과 manifest 의 `runtime_failed` 는 사이클 줄 직전 120초(뒤로 2초의 시계 차) 안에서 가장 늦은 것끼리 짝지었다. 49건이 모두 짝지어졌다. 3건은 사이클 줄의 runtime 이 아니라 같은 턴의 다음 attempt(`claude_code_b6e72ff9`, `outsiders`)의 `runtime_failed` 에 짝지어져서, `glm-coding`·`ollama_cloud` 의 쓰기 실패로 확실한 것은 46건이다.
- 도구 결과 주입이 있는 턴은 요청이 더 많아서 노출이 늘어난 효과를 나누지 못했다. 기준선은 턴 단위이고 실패는 요청 단위라 49건 전부가 주입 뒤라는 값은 정보가 적다. 마지막 주입부터 실패까지의 간격에는 permit 대기와 다른 요청이 섞여 있을 수 있다.
- 재연결 이벤트가 있는 2건에서 재연결한 run 은 취소 이벤트(`preparation_observed` `cancelled`, 05:58Z)로 끝났고, 06:02Z 에 새 run(`turn_started`, `runtime_execution_built`)이 시작됐다. 07:18Z 의 실패는 그 새 run 에서 났다. 재연결로 캐시를 끄는 binding 은 fiber 안에 있어서(`Provider_connection_cache_ref.with_fresh_connections`) 새 run 에 닿지 않는다. 그래서 49건 모두 실패한 run 에는 재연결이 없었다. run 경계를 `turn_started` 로 본 것은 이 두 턴의 이벤트 순서로만 확인했다.
- 49건 모두 재사용한 연결에서 났는지 새로 연 연결에서 났는지는 로그에 없다. 캐시의 `request_failed` 는 응답 전과 후를 나누지 않는다.
- 캐시 통계는 10:46Z 이후의 값이고, 쓰기 실패 49건 중 48건은 그 전이다. 이 통계는 그 48건에 대해 아무것도 말하지 않는다. 같은 통계의 `request_failed` 3개는 쓰기 실패가 아닌 다른 실패일 수 있다.
- 쓰기 실패 사이의 간격은 실패가 구간에 고르게 퍼졌다는 가정과 견줬다. Keeper 의 활동은 고르지 않아서 이 가정은 거칠다. 같은 시각의 두 실패(07:18:33Z, 07:18:34Z)는 같은 원인일 수 있다는 단서일 뿐 원인은 아니다.
- 서버가 요청을 다 받기 전에 거절 응답을 보내고 닫은 경우가 이 49건에 있는지 모른다.
