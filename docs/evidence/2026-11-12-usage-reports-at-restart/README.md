# 재시작 시점에 저장된 사용량 보고가 말하던 것 (2026-11-12)

`docs/rfc/RFC-a-restarted-server-reads-the-stored-usage-reports.md` 1.1 절의 근거다.

- `count.py`: 저장 기록(`<base-path>/.masc/provider_usage_history`)에서 재시작 전 행을 계정·source·창 종류별 최신으로 접고, 계정마다 재시작 뒤 첫 보고까지 걸린 시간을 낸다.
- `result.txt`: 2026-11-12 한 설치에서 돌린 결과. 재시작 시각은 `1794443183.037357`(`/api/v1/runtime/resolved` 의 `provider_usage_windows_since`), 계정 목록은 2026-11-12T01:18:00Z 에 읽은 같은 응답이다.

한계

- 설치 하나, 재시작 한 번이다.
- 저장 기록과 응답 원본은 저장소 밖에 있어 여기 싣지 않았다. `result.txt` 는 `scope` 라벨과 provider id 만 담는다.
- "재시작 뒤 첫 보고"는 응답을 읽은 시각이 아니라 저장 기록의 `observed_at` 으로 셌다.
