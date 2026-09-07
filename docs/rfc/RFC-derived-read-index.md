---
rfc: "0436"
title: 원장은 그대로 두고 읽는 길만 색인으로 — 게이트 없이
status: Draft
created: 2026-09-07
author: vincent + claude
supersedes: []
superseded_by: null
related: ["0398"]
---

## 0. 한 줄 요약

masc 의 운영 데이터는 JSONL 원장에 쌓이고, **읽을 때마다 훑는다**. 그래서 대시보드 새로고침이
테이블 스캔이다. 이 문서는 원장을 authority 로 그대로 두고 **읽는 길에만 파생 색인**을 놓자고
제안한다.

새 기술은 필요 없다. `sqlite3` 은 이미 `dune-project` 의존성이고 이미 네 라이브러리가 쓴다.
`Tool_metrics_store` 는 **정확히 이 모양의 문제를 이미 SQLite 로 풀어놨다**(§2.2).

그리고 이건 성능 이야기만이 아니다. 지금 오버스캔하는 읽기는 **답이 틀린다**(§1.2).

## 1. 무엇이 문제인가

### 1.1 읽기는 전부 주사(scan)다

`Dated_jsonl` 은 월/일로 나뉜 append-only JSONL 이다. 질의는 네 가지뿐이다.

| 질의 | 지금 구현 |
|---|---|
| 최근 N행 | 파일 꼬리에서 N행 읽고 전부 파싱 |
| keeper X 의 최근 N행 | 전체의 배수를 읽고 파싱한 뒤 필터 |
| stimulus S 의 증거 | 원장 전수 주사 |
| 개수 + 최초/최신 | 10만 행 파싱 |

넷 다 색인이 있으면 상수~로그 시간이고, 지금은 전부 선형이다.

2026-09-07 조용한 창 memprof(부팅 후 83.4 GB 할당) 기준 **JSONL 저장소 읽기가 15.1%** 였다.

### 1.2 오버스캔은 느린 게 아니라 틀린다

`Keeper_tool_call_log.read_recent ?keeper_name ~n` 은 keeper 필터를 위해 fleet 행의 배수를 읽는다.
`server_dashboard_http_keeper_api.ml:38` 주석이 실측을 적어놨다.

> asking for 500 of one keeper's calls returned 454 on 2026-08-24 and asking for 5,000
> returned 1,409 — and a caller cannot tell a keeper that made no more calls from a scan
> that stopped short.

**호출자가 "그 keeper 가 더 안 불렀다" 와 "주사가 도중에 멈췄다" 를 구분할 수 없다.** 같은 주석이
결론까지 적어놨다 — *"wants an index, not a wider scan."*

09-07 11:17 memprof 에서 이 자리가 단일 최대 할당(3.84 GB, 4.4%)이다.

### 1.3 캐시를 덧대는 것으로는 안 끝난다

2026-09-06~07 에 여덟 조각을 넣어 main 도메인 지연을 정리했다(RFC main-domain-scheduler-latency).
그중 마지막 두 개는 이 문제에 캐시를 덧댄 것이다 — reaction ledger 증분 읽기(#33806), 도구 이름
게으른 파싱(#33813). 둘 다 효과가 있었지만 **색인 없는 저장소에 캐시를 붙이는 일**이었다.
계속 덧대면 색인으로 갈 때 그 캐시들이 전부 걷어낼 짐이 된다.

## 2. 왜 지금 할 수 있나

### 2.1 헌법이 이미 허락한다

`docs/constitution.xml` 과 `instructions/projects.md`:

> 파생 상태는 SSOT 위반이 아니며, authority 로 재저장하지 않고 blast radius 를 분명히 한다.

원장이 authority 다. 색인은 **버리고 다시 만들 수 있는 파생물**이다. 이 구분을 코드가 지키는 한
새 SSOT 가 생기지 않는다.

### 2.2 선례가 둘 있다

**`Tool_metrics_store`** — SQLite, WAL, `synchronous=NORMAL`, `busy_timeout=5000`, `ts` 색인.
읽기 표면이 `read_recent ~since_ts ~until_ts ~n` 이다. 우리가 원하는 그 모양이 이미 돌고 있다.

**`Dated_jsonl.save_count_cache`** — `.mli` 가 이렇게 선언한다.

> The cache is never an authority: every entry is still validated against the file's
> current size when it is used, so a stale or hand-edited cache cannot corrupt a count.

파생물을 authority 로 승격시키지 않는 규율이 이미 이 모듈 안에 있다.

## 3. 설계 — 게이트를 만들지 않는다

### 3.1 읽을 때 따라잡는다 (catch-up-on-read)

색인이 원장보다 뒤처져 있을 수 있다는 사실 자체를 **없앤다**.

읽기는 항상 두 단계다. 먼저 색인을 원장의 현재 끝까지 전진시키고, 그 다음 질의한다. 전진은
`Dated_jsonl.fold_range_appended ~cursors` 가 하던 그것이다 — 날짜 파일마다 어디까지 읽었는지
커서를 들고, 새로 붙은 줄만 넣는다. #33806 이 이미 이 패턴으로 돈다.

그래서 없는 것:

- "색인이 최신인가" 를 묻는 상태나 필드
- 색인을 기다리는 대기 상태
- 색인 갱신을 예약하는 백그라운드 작업과 그 실패 처리
- 색인을 켜고 끄는 플래그

**질의 시점에 색인은 정의상 최신이다.** 그러므로 게이트가 존재할 자리가 없다.

### 3.2 대체 경로를 만들지 않는다

색인 파일이 없거나, 스키마 버전이 다르거나, 열리지 않으면 → **지우고 원장에서 다시 만든다.**
"색인이 없으면 원장을 훑는다" 는 fallback 을 두지 않는다. 경로가 둘이면 둘 다 유지해야 하고,
둘이 갈라지면 어느 쪽이 맞는지 아무도 모른다.

스키마 변경도 같다. 마이그레이션 코드를 쓰지 않는다. 버전이 다르면 파일을 버리고 다시 만든다
(hard cut = fresh-state contract).

### 3.3 색인이 쥐는 것

원장 행 전체가 아니라 **질의에 필요한 열만** 넣는다. 본문이 필요하면 원장에서 읽는다.
`keeper_tool_call_log` 의 경우:

```
CREATE TABLE rows (
  ledger_path TEXT NOT NULL,     -- 어느 날짜 파일
  ledger_offset INTEGER NOT NULL,-- 그 파일 안 위치
  ts REAL NOT NULL,
  keeper_name TEXT NOT NULL,
  PRIMARY KEY (ledger_path, ledger_offset)
);
CREATE INDEX rows_keeper_ts ON rows(keeper_name, ts);
CREATE TABLE cursors (ledger_path TEXT PRIMARY KEY, boundary INTEGER NOT NULL);
```

`(keeper_name, ts)` 색인 하나로 §1.2 의 질의가 정확해진다. **500개를 물으면 500개가 있으면
500개가 온다.** 없으면 없는 만큼 오고, 그건 "더 없다" 는 사실이다.

### 3.4 범위 — 하나로 시작한다

`keeper_tool_call_log` 만 한다.

- 지금 단일 최대 할당 자리다(3.84 GB, 4.4%)
- 답이 틀리는 유일한 자리다(§1.2)
- 작동하는 선례가 바로 옆에 있다(`Tool_metrics_store`)

성공하면 reaction ledger·telemetry 로 넓힌다. 넓히는 것은 이 RFC 가 결정하지 않는다.

## 4. 검증

색인의 답과 원장 주사의 답이 같아야 한다. 그게 유일한 정답 기준이다.

1. **동치 테스트** — 같은 질의를 색인과 원장 주사로 각각 답하고 비교한다. 임시 원장에 행을
   넣고, keeper 별·시각 범위별로 돌린다.
2. **개수 테스트** — §1.2 가 틀렸던 그 질의. keeper 하나에 600행을 넣고 500을 물어 500이 오는지.
   이게 회귀 테스트의 핵심이다.
3. **재구축 테스트** — 색인 파일을 지우고 다시 물으면 같은 답이 오는지. 스키마 버전을 바꿔도
   같은지.
4. **커서 전진 테스트** — 읽고, 원장에 붙이고, 다시 읽으면 새 행이 답에 들어오는지. 두 번 세지
   않는지.

## 5. 하지 않는 것

- 원장 형식을 바꾸지 않는다. JSONL append-only 가 증거 저장소로 옳다 — 크래시에 강하고, 사람이
  읽을 수 있고, 부분 손상이 전체를 못 망친다.
- 색인을 authority 로 쓰지 않는다. 색인만 보고 답할 수 있는 질의라도, 색인은 원장에서 만들어진
  것이다. 원장에 없는 사실이 색인에 있으면 그건 버그다.
- 게이트를 만들지 않는다(§3.1).
- 마이그레이션 코드를 쓰지 않는다(§3.2).
- 다른 저장소로 넓히지 않는다(§3.4).

## 6. 근거 기록

| 항목 | 값 | 출처 |
|---|---|---|
| JSONL 저장소 읽기 할당 비중 | 15.1% | 09-07 10:46 memprof, 83.4 GB |
| `Keeper_tool_call_log` 읽기 | 3.84 GB (4.4%) | 09-07 11:17 memprof, 87.2 GB |
| 오버스캔 부정확 | 500 → 454, 5,000 → 1,409 | `server_dashboard_http_keeper_api.ml:38` (2026-08-24 실측) |
| SQLite 선례 | WAL·NORMAL·busy_timeout 5s·ts 색인 | `lib/tool_metrics_store/tool_metrics_store.ml:121-160` |
| 파생물 규율 선례 | "never an authority ... validated against the file's current size" | `lib/dated_jsonl/dated_jsonl.mli:333` |
| 커서 전진 패턴 | 이미 두 곳에서 동작 | `keeper_tool_call_log.ml:1133`, PR #33806 |
