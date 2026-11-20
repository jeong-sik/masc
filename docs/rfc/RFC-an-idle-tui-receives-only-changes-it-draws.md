---
rfc: "an-idle-tui-receives-only-changes-it-draws"
title: "쉬는 TUI 는 화면에 그리는 값이 바뀔 때만 받는다"
status: Draft
created: 2026-11-18
updated: 2026-11-18
author: claude
related: ["0480", "0481", "0474", "0477", "tui-one-screen-grammar"]
---

# 쉬는 TUI 는 화면에 그리는 값이 바뀔 때만 받는다

- 상태: 초안 3판. 독립 리뷰를 두 번 받았다. 두 번 모두 코드 인용, 설계, 문장을 나눠 봤고 설계 지적은
  반박 검증을 거쳤다.
- 운영자 결정(2026-11-18): 받는 데이터 줄이기를 TUI btop 작업에 넣고 RFC 부터 쓴다. 방향은 셋이다.
  - `execution_snapshot` 은 바뀐 것만 보낸다.
  - turn 조각은 그 키퍼 채팅을 연 client 에게만 간다.
  - 1초마다 다시 읽는 `keepers/turns` 는 바뀐 것이 있을 때만 몸통을 받는다.
- 코드 좌표는 `origin/main` `0a0a961b480f` 에서 읽었다.
## 0. 결정

1. 알림에는 무엇이 바뀌었는지만 싣는다. 값은 GET 이 준다.
2. observer 알림은 workspace 의 읽기 모델이 바뀐 것을 알린다. 한 turn 의 글처럼 한 대상의 흐름은 그
   대상을 보는 reader 가 직접 따라간다.
3. `execution_snapshot` 준비 알림은 투영 대신 게시 번호를 싣는다. web 은 그 게시를 GET 으로 읽는다.
   서버는 게시한 몸통을 그대로 돌려준다. 읽기 때문에 투영을 다시 계산하지 않는다.
4. backlog 가 바뀌면 `Backlog` dataset 알림이 따로 나간다. TUI 는 backlog 를 싣는 읽기를 이 알림으로 한다.
5. turn 조각 알림을 지운다. 채팅을 연 TUI 만 그 turn 의 journal 을 기다리며 읽는다.
6. `keepers/turns` 몸통에서 읽는 시각으로 센 값과 요청하지 않은 preview 를 뺀다. 같은 값이면 304 가 온다.
7. TUI 는 `keepers/turns` 를 그 값을 쓰는 동안에만 읽는다. 같은 주소를 따로 읽던 두 읽기를 합친다.
8. 옛 client 가 새 모양을 잘못 읽는 wire 변경은 hard cut 이다. 옛 모양을 읽는 reader 와 converter 를
   두지 않는다. 필드나 이름을 더하기만 하는 변경은 hard cut 이 아니다.
9. execution 투영의 뜻이 바뀔 때만 알리는 일은 따로 RFC 로 낸다(§9). 이 RFC 뒤에도 투영의 바이트가
   바뀌면 게시가 나간다.

운영자가 정한 세 방향은 결정 3·9(execution), 5(turn 조각), 6(turns)이 맡는다. 결정 4 와 7 은 세 방향
밖에서 더했다. 4 는 측정에서 나왔다. TUI 는 execution 알림마다 backlog 를 싣는 읽기를 모두 다시
한다(§2.1). 7 은 §3 의 넷째 규칙과 이미 죽은 전제(§2.3)에서 나왔다.

## 1. 지금 무엇이 오나

운영 서버 앞에 읽기 전용 중계를 두고 쟀다(2026-11-17). 중계는 쓰기 요청을 거절한다. TUI 는 main
`c43fd13` 이다. Overview 화면(탭 이름 "운영")에 두고 키를 누르지 않았다.

observer 알림(SSE 연결 하나), 25.7초:

| 알림 종류 | 건수 | 바이트 | TUI 가 하는 일 |
|---|---:|---:|---|
| `execution_snapshot` | 5 | 4,874,250 | 몸통은 버린다. backlog 를 싣는 읽기를 모두 다시 한다 |
| `keeper_turn_stream_event` | 9,647 | 1,710,224 | 채팅 화면과 Acting 의 Everything 보기에서만 쓴다 |
| `keeper_chat_operation_event` | 563 | 296,172 | 이 RFC 밖 |
| `workspace_dataset_changed` | 1,268 | 263,265 | 이 RFC 밖 |
| `project_snapshot` | 13 | 105,038 | 이 RFC 밖 |
| `keeper_turn_preview_changed` | 280 | 34,769 | 이 RFC 밖 |
| 나머지 19종 | 179 | 74,223 | 이 RFC 밖 |
| 알림 합계 | 11,955 | 7,357,941 | |

스트림 전체는 7,359,205 바이트, 초당 약 286 KB 다.

같은 구간에 TUI 는 `GET /api/v1/keepers/turns` 를 20번 보냈다. 20번 모두 200 이었다. 몸통은 한 번에
186~193 KB, 합계 3,798,972 바이트(초당 약 148 KB)다. 20번 중 다섯 번은 바로 앞 요청과 0.01초 안에
나갔다.

연구 노트 표와 숫자가 다른 곳이 둘 있다.

- turns: 연구 노트는 12초 구간에서 12번, 2,291,207 바이트를 셌다. 이 RFC 는 SSE 와 같은 25.7초 구간으로
  다시 셌다.
- 알림 종류: 연구 노트의 "나머지 20종 넘음" 행에는 preview 알림이 들어 있다. 이 RFC 는 그 행을
  preview 와 나머지 19종으로 나눴다. 연구 노트의 "넘음"은 L0 에서 다시 센 값으로 고친다.

중계 원본 기록은 측정한 세션의 임시 폴더에 있었고 지금은 없다. 위 숫자는 그때 계산한 값이다. L0 은
같은 도구(`artifacts/tui-btop-expressiveness/harness/readonly_proxy.py`)로 다시 잰다.

Overview 화면에서 TUI 는 CPU 16.3%, RSS 426 MB 를 썼다. 화면 15개를 하나씩 20초 잰 값은 CPU
8.1~26.7%, RSS 421~659 MB 다. Overview 화면 `sample` 에서 기다림과 PTY 쓰기를 뺀 표본의 66% 가 JSON
해석이었다. 어느 읽기의 몫인지는 아직 나누지 못했다(§8 L0).

## 2. 원인

### 2.1 execution_snapshot

- 서버는 execution 캐시가 바뀔 때마다 게시한다. 완료 다섯 갈래가 모두 `enqueue ()` 로 이어진다
  (`lib/server/server_dashboard_http_execution_surfaces.ml:201-207, 1568-1571`).
  - 배경 계산: `Cache_installed Observation_read`(`:1584-1586`)
  - actor 없는 HTTP 읽기가 한 계산: `Cache_installed Request_read`
  - 키퍼 lifecycle patch: `Cache_patched`
  - 실패 두 갈래: `Cache_failed`
  - shell 캐시 갱신: `Shell_installed`(`:343-347`)
- 보내기 직전에 같은 종류의 앞 글과 바이트가 같으면 건너뛴다(`:52-130`, 비교는 `:86-97`). 그런데
  투영에는 다시 만들 때마다 바뀌는 값이 있어서 거의 건너뛰지 않는다.
  - 만든 시각: `generated_at`(`lib/dashboard/dashboard_execution.ml:855`), 캐시의 마지막 성공·시도
    시각(`lib/server/server_dashboard_http_cache.ml:50-63`)
  - 키퍼마다 읽는 시각으로 센 나이: `last_turn_ago_s`, `last_proactive_ago_s`, `last_activity_ago_s`
    (`lib/operator/operator_control_snapshot.ml:297-316, 402-404`)
  - `execution_publication_generation`: 무효화와 lifecycle patch 에서만 오른다. patch 는 행이 그대로여도
    올린다(`:1447-1475`). 배경 계산은 같은 generation 으로 다시 게시한다.
  - Candle 덧씌우기: 시각에 따라 줄어드는 잔액, 다른 화면이 Candle 을 읽어도 오르는
    `candle_observation_sequence`(`lib/dashboard/dashboard_projection_cache.ml:40-70`)
- 측정 구간에서 약 1 MB 가 약 5초마다 갔다. 다섯 건이 어느 완료에서 나왔는지는 L0 에서 센다.
- backlog 커밋과 키퍼 lifecycle 요청은 같은 종류로 작은 무효화 알림을 낸다(`:637-675`,
  `lib/server/server_dashboard_http_keeper_api_lifecycle_post.ml:92`). 두 모양은 `execution_invalidated` 로
  갈린다.
- 서버의 관찰 입력은 무효화 모양만 읽는다(`lib/server/server_observation_input.ml:139-156`).
- 몸통을 쓰는 곳은 web 하나다(`dashboard/src/sse-store.ts:363-385`). web 은 HTTP 없이 SSE 몸통으로
  그린다. web 이 직접 GET 할 때는 actor 를 싣는다. actor 가 있는 GET 은 게시가 바뀔 때마다 투영을 새로
  계산하는 길을 탄다(`:1957-2001`). 미리 만든 몸통을 주는 길은 actor 가 없을 때만 탄다(`:1632-1645`).
- TUI 는 두 모양을 가리지 않는다(`bin/masc_tui.ml:25882`). 어느 쪽이 와도 backlog 를 싣는 읽기 여섯을
  다시 한다. 주석은 이유를 "task 쓰기가 `execution_snapshot` 으로 알린다"고 적는다.
  - Work: 캐시를 버리고 디스크에서 읽는다(`:25963-25967` → `:19148-19154`, `fresh:true`).
  - Verification, Goal: `:26048-26050`
  - 고른 키퍼의 도구 목록: `:26051-26052`, `:26114-26121`
  - Planning(그 화면일 때): `:26089-26093`
  - 열린 원본 Task 본문: `:26122-26125`

### 2.2 turn 조각

- 자율 turn 의 조각이 journal 에 붙을 때마다 서버는 모든 observer 에게 알린다
  (`lib/keeper/keeper_autonomous_stream.ml:44-59`). 알림에는 키퍼 이름, turn ref, seq, 시각만 있다. 읽는
  쪽은 journal 을 다시 읽는다(같은 파일 `:48-50` 주석).
- TUI 는 이 알림을 그 키퍼의 채팅 화면이 열려 있을 때 쓴다(`bin/masc_tui.ml:25690-25699`). seq 가 늘면
  `GET /api/v1/keepers/<k>/turns/<turn_ref>/events` 로 읽는다(`bin/masc_tui_keeper_chat_log.ml:503-512`).
- Acting 기록은 조각마다 한 줄을 남긴다. Everything 보기만 그 줄을 그린다
  (`bin/masc_tui_acting.ml:60-63`). 그 밖의 화면과 web 은 이 알림을 버린다.
- 초당 약 375건, observer 알림 건수의 81% 다.

### 2.3 keepers/turns

- `GET /api/v1/keepers/turns` 는 키퍼마다 도는 turn, preview, 대기 목록(waiting)을 싣는다
  (`lib/server/server_routes_http_keeper_control.ml:144-231`).
- waiting 에는 읽는 시각으로 센 값이 둘 있다.
  - `current_execution` 의 `ts`, `idle_seconds`: 도는 turn 이 있는 키퍼
    (`lib/server_keeper_waiting_inventory.ml:1211-1243, 1303-1305`, 값은
    `lib/keeper/keeper_composite_observer.ml:336, 416-419`)
  - `queue_residence.oldest_age_seconds`: 이벤트 큐에 항목이 있는 키퍼(`:600-605`)
- 그래서 키퍼 하나만 일해도 몸통이 매번 다르다. ETag 는 몸통 해시다(`lib/http_server_eio.ml:168-178,
  215-223`). TUI 는 이미 `If-None-Match` 를 보낸다(`bin/masc_tui_kept_reads.ml:41`, turns 는
  `bin/masc_tui_http.ml:771-777, 3104-3109` 를 지난다). 몸통이 매번 달라서 304 가 나올 수 없다.
- TUI 가 읽는 waiting 필드는 여섯이다(`lib/tui_decode.ml:5054-5062`). 위의 값은 읽지 않는다. web 의 turns
  읽기는 waiting 과 preview 를 읽지 않는다(`dashboard/src/api/dashboard-keeper-turns.ts`).
- TUI 는 `keeper_turn_changed` 를 받으면 어느 화면에서든 turns 를 읽는다. 주석이 든 이유는 "답변 중
  배지를 모든 화면이 그린다"다(`bin/masc_tui.ml:9050-9054`). 이 배지는 #41703(2026-10-10)에서 공통
  하단줄과 함께 빠졌다. RFC-0481 §3.4 에도 같은 전제가 있다. 그 RFC 가 적은 몸통 크기(약 2 KB)도 지금은
  186~193 KB 다.
- 대기 목록 읽기(`launch_keeper_waiting_load`, `bin/masc_tui.ml:3977`)도 같은 주소를 읽는다. 이 읽기는
  빚을 거치지 않고 바로 나간다. `keeper_waiting_inventory_changed`, 확인 대기, 일정 알림이 부른다.
  붙잡힌 일정은 runner tick 마다 알린다(`:26031-26044`). turns 읽기(`launch_keeper_turns_load`, `:3996`)와
  따로 나가서 0.01초 안에 이어 나간 다섯 번과 맞는다.
- Overview 화면은 turns 의 어느 값도 그리지 않는다. 그리는 곳은 이렇다.
  - 도는 turn: 채팅 화면, 키퍼 목록 화면의 행, Metrics, `@` 창
  - 대기 목록: 키퍼 목록 화면의 행과 Activity 칸(`bin/masc_tui_types.ml:13356-13360`,
    `bin/masc_tui_render_prim.ml:1568-1600`)

## 3. 규칙

`docs/SYSTEM-EVENT-AND-SNAPSHOT-INVENTORY.md` 의 읽기 모델 규칙은 "SSE 는 신선도를 전하는 길이지 정본
읽기 모델이 아니다"다. RFC-0480 은 이 규칙을 TUI 가 읽는 쪽에 적용했다. 이 RFC 는 같은 규칙을 서버가
보내는 쪽에 적용한다.

1. 알림에는 무엇이 바뀌었는지(종류, 대상, cursor)만 싣는다. 값은 GET 이 준다.
2. 알림 이름은 바뀐 것의 이름이다. reader 는 자기가 읽는 값이 바뀌었다는 알림에만 다시 읽는다.
3. observer 알림은 workspace 의 읽기 모델이 바뀐 것을 알린다. 한 대상의 흐름(turn 하나의 글)은 그
   대상을 보는 reader 가 직접 따라간다.
4. reader 는 화면에 그리거나 동작에 쓰는 값을, 쓰는 동안에만 읽는다.
5. 같은 값을 다시 읽으면 GET 은 몸통 없이 304 로 답한다. 시각이 흐른 것만으로 몸통이 바뀌면 304 가
   나올 수 없다. 그래서 읽는 시각으로 센 값은 쓰는 곳이 없으면 몸통에서 뺀다.

이 다섯 규칙이 §4 의 설계가 된다. 규칙 1 은 E1, 규칙 2 는 E2, 규칙 3 은 T1~T3, 규칙 4 는 K3, 규칙 5 는
K1·K2·K4 다. 읽기를 숫자로 막는 gate, cap, cooldown 은 없다. 기다리는 읽기의 서버 상한(T1)은 자원
경계다(`docs/constitution.xml` `budget_gate`).

## 4. 설계

### 4.1 execution_snapshot

**E1. 준비 알림은 게시 번호만 싣고, web 은 그 게시를 읽는다.**

- 서버는 마지막 게시를 workspace 의 execution owner 에 둔다. 게시 번호, 투영 몸통, 압축본이다.
  몸통은 지금 준비 알림에 싣는 몸통 그대로다. 계산이 실패해 실패 몸통을 게시할 때도 같다(`:532-553`).
- 새 투영이 나오면 둔 몸통과 바이트를 견준다. 다를 때만 번호를 올리고, 몸통을 바꾸고, 압축본을 한 번
  만들고, 알림을 낸다. 같으면 아무것도 하지 않는다. 지금의 같은 바이트 건너뛰기(`:86-97`)를 알림 글
  대신 이 몸통에 거는 것이다.
- 견주는 것을 알림 글로 두면 안 된다. 투영을 뺀 알림은 같은 generation 안에서 바이트가 모두 같다.
  generation 은 무효화와 lifecycle patch 에서만 오른다(§2.1). 그러면 배경 계산이 만든 새 투영의 알림이
  모두 버려진다.
- 준비 알림(`execution_invalidated` 가 false)에는 `observer_instance_id`, `execution_publication_epoch`,
  `execution_publication_generation`, `execution_invalidated`, 그리고 새 `execution_publication`(게시
  번호)만 싣는다.
- 새 경로 `GET /api/v1/dashboard/execution/publication` 은 마지막 게시의 몸통을 그대로 돌려준다. 투영을
  계산하지 않는다.
  - ETag 는 epoch 와 게시 번호로 만든다. 같은 번호면 304 다.
  - 게시가 없으면 404 다.
  - 권한과 workspace scope 는 지금 execution 경로와 같다.
- web 은 준비 알림의 epoch 와 게시 번호가 가진 것보다 새로우면 이 경로를 읽는다. 읽은 몸통은 지금처럼
  `hydrateExecutionSnapshot` 에 넘긴다(`dashboard/src/sse-store.ts:381-385`). 지금 SSE 로 받던 것과 같은
  게시라 web 이 그리는 값은 그대로다.
- 이 읽기는 계산을 부르지 않는다. 그래서 알림, 읽기, 계산, 알림으로 도는 고리가 없다. 계산이 실패하는
  동안에도 같다.
- web 이 준비 알림 뒤에 지금 execution 경로를 읽지 않는 이유는 §10 에 있다.
- 무효화 알림과 그 force 읽기는 그대로다. 서버 관찰 입력도 지금처럼 무효화 알림만 읽는다.
- 준비 알림은 지금처럼 모든 observer 에게 간다. execution 은 workspace 의 읽기 모델이다(§3 의 규칙 3).
  TUI 는 받고 버린다.
- `docs/SYSTEM-EVENT-AND-SNAPSHOT-INVENTORY.md:41` 의 행을 고친다.

**E2. backlog 를 싣는 TUI 읽기는 `Backlog` 알림으로 한다.**

- `Workspace_dataset_event.dataset` 에 `Backlog` 를 더한다.
- 알리는 곳은 backlog 와 goal link 커밋 경계다(`lib/workspace/workspace_backlog.ml:477-480, 569-574`,
  `lib/workspace/workspace_goal_index.ml:420-421`). RFC-0480 결정 4(알림은 저장 함수 안에서 낸다)와 같다.
  - 이 파일들은 `Workspace_dataset_event` 보다 아래 라이브러리에 있다. 그래서 base_path 를 받는 관찰자를
    하나 둔다. `install_store_observers` 가 그것을 `announce ~base_path Backlog` 로 잇는다. `Repo_store` 가
    같은 선례다(`lib/workspace_dataset_event.ml:356-361`).
  - `Workspace_hooks.on_task_mutation_fn` 은 쓰지 않는다. base_path 를 받지 않고
    (`lib/workspace/workspace_hooks.mli:89`), execution 캐시 무효화가 그 자리를 쓴다.
- 서버 관찰 입력은 dataset 이름을 빠짐없이 나눠 읽는다(`lib/server/server_observation_input.ml:78-90`).
  `Backlog` 는 어느 서버 표면도 다시 계산하게 하지 않는다. 같은 커밋이 이미 무효화 알림을 낸다.
- TUI 는 §2.1 의 여섯 읽기를 `Backlog` 알림으로 한다. 읽는 방법은 그대로다. Work 는 지금처럼 캐시를
  버리고 읽는다. 읽는 횟수가 backlog 커밋 수로 줄기 때문이다.
- `Verification_requests`, `Goals`, `goal_projection_changed` 로 하던 읽기는 그대로다.
- TUI 는 execution 알림으로 아무것도 읽지 않는다.
- Work 읽기 결과에는 backlog 밖 입력도 있다.
  - `task_flow` 는 읽는 시각으로 24시간 구간을 센다(`bin/masc_tui_loader.ml:281`). 지금은 약 5초마다
    다시 읽어 구간이 움직였다. E2 뒤에는 그릴 때의 시각으로 센다. 한 화면 문법 RFC §8 의 "시간이 흘러
    바뀌는 글자"와 같은 규칙이다.
  - agenda 의 "키퍼 대기열 없음" 줄(`lib/operator_task_attention.ml:51`)은 담당자 이름이 키퍼로 있는지를
    본다. §2.3 의 대기 목록과는 다른 값이다. 키퍼가 생기거나 없어지는 알림에도 Work 를 읽는다.
  - 나머지 입력은 L0 에서 모두 찾아 그 입력의 알림에 건다.
- 서버 밖에서 backlog 파일을 고치면(CLI 직접 쓰기, 손 편집) 알림이 없다. 피드가 다시 열리거나 `[r]` 을
  누르면 보인다. Runtime config 가 같은 선례다(`lib/workspace_dataset_event.mli:52-56`). 지금은 약
  5초마다 오는 execution 알림이 이 빈틈을 가린다(§11 의 2).

### 4.2 turn 조각

**T1. journal 읽기가 기다릴 수 있다.**

- `GET /api/v1/keepers/<k>/turns/<turn_ref>/events` 에 `follow=true` 를 더한다.
- turn 마다 깨움 신호를 하나 둔다. 메모리에만 있다. journal 에 붙이는 곳과 turn 을 끝내는 곳이
  신호를 울린다. 한 turn 을 여러 읽기가 기다려도 신호는 하나다. 저장 상태는 더하지 않는다. journal 이
  유일한 저장소로 남는다.
- 기다리는 읽기는 이 순서로 돈다.
  1. turn 이 도는지 본다(`Keeper_autonomous_stream.current`, `lib/keeper/keeper_autonomous_stream.ml:30-31`).
  2. 깨움 신호를 구독한다. 그래야 page 를 읽는 사이에 붙은 항목을 놓치지 않는다.
  3. page 를 읽는다. 커서 뒤에 항목이 있으면 바로 답한다.
  4. 항목이 없고 1 에서 turn 이 돌았으면, 신호와 서버 상한 가운데 먼저 오는 것까지 기다린다. 신호가
     오면 3 으로 간다.
- 답에 turn 상태(`running`, `ended`)를 싣는다. `ended` 는 1 에서 turn 이 이미 없었을 때만 답한다.
  - turn 을 끝낼 때 서버는 끝 항목을 먼저 붙이고 그다음 표에서 지운다(`:190-202`).
  - 그래서 1 에서 없던 turn 의 page 에는 끝 항목이 다 들어 있다.
  - page 를 읽은 뒤에 상태를 보면 끝 항목 없이 `ended` 를 답할 수 있다.
- 지금 답에는 `schema`, `turn_ref`, `events`, `has_more`, `next_since_seq`, `next_since_offset` 이 있다
  (`lib/server/server_dashboard_http_keeper_chat_operations.ml:328-351`). 커서는 seq 와 byte 위치의
  짝이다. 짝이 맞지 않으면 서버가 거절한다(`bin/masc_tui_keeper_chat_log.ml:503-512, 535`).
- 서버 상한은 TUI 의 요청 시간 제한보다 짧다. journal 읽기는 10초 제한을 쓴다
  (`bin/masc_tui_http.ml:36-37, 606-618`). 상한에 닿으면 빈 page 와 `running` 으로 답한다. 조용한 turn 의
  읽기는 이렇게 정상으로 끝난다. 두 상한의 관계는 시험으로 고정한다.
- 상한이 있어야 하는 이유: serving domain 은 기본으로 꺼져 있다
  (`lib/config/env_config_runtime.ml:200-201`). 그러면 handler 는 연결의 fiber 에서 돈다
  (`lib/server/server_http_ingress.ml:300-333`). 기다리는 동안 그 연결은 다음 바이트를 읽지 않는다.
  client 가 떠나도 handler 는 모른다. 상한이 버려진 읽기의 수명을 정한다.

**T2. 채팅 화면은 도는 turn 하나를 따라간다.**

- 채팅 화면의 키퍼에 도는 turn 이 있으면 TUI 는 그 turn 을 따라가는 읽기를 하나 둔다. 답을 받으면
  `next_since_seq` 와 `next_since_offset` 으로 다음 읽기를 낸다.
- 따라가는 읽기는 RFC-0480 결정 3 의 알림 뒤 읽기다. 실패하면 성공할 때까지 백오프로 다시 읽는다.
  지금은 실패한 journal 읽기를 기억하지 않는다. 다음 조각 알림이 다시 부르기 때문이다
  (`bin/masc_tui.ml:29902-29907`). T3 뒤에는 다음 조각 알림이 없다.
- 따라가는 읽기는 대상 하나짜리 일로 돈다. 지난 turn 들을 차례로 읽는 일(`bin/masc_tui.ml:11286-11356`)
  에 넣지 않는다. 넣으면 지난 turn 읽기가 서버 상한만큼 밀린다.
- 따라가기마다 switch 를 하나 둔다.
  - 지금 TUI 읽기는 모두 root switch 에서 돌아 하나만 끊을 수 없다(`bin/masc_tui_async_read.mli:8-11`).
  - 채팅 화면을 닫거나 다른 키퍼로 옮기면 그 switch 를 닫는다. 요청 fiber 도 취소된다
    (`bin/masc_tui_io_domain.mli:36-38`). 그 뒤에 온 답은 그리지 않는다.
  - 서버에서 기다리던 읽기는 상한에서 끝난다.
- 답이 `ended` 면 따라가기를 멈춘다.
- 새 turn 은 지금처럼 `keeper_turn_changed` 와 turns 읽기로 안다. 채팅 화면은 turns 를 쓰므로 이 읽기는
  남는다(K3).

**T3. 조각 알림을 지운다.**

- `keeper_autonomous_stream.ml:51` 의 `Sse.broadcast_to` 와 TUI observer 의 `Keeper_turn_stream_frame` 을
  같은 배포에서 지운다. Acting 의 Everything 보기에도 조각 줄이 더 들어오지 않는다.
- 채팅 operation 알림(`keeper_chat_operation_event`)은 그대로 둔다. web 이 모든 키퍼의 내용을 쓴다
  (`dashboard/src/sse.ts:518`).

### 4.3 keepers/turns

**K1. turns 의 waiting 에는 TUI 가 그리는 것만 싣는다.**

- 2026-11-18 운영에서 잰 키퍼 목록의 turns 몸통은 약 585 KB 다(키퍼 31). 그 가운데 559 KB(96%)가
  waiting 항목 목록이다.
  - 항목은 1,270개다. 1,204개가 `event_queue_pending` 이고, 키퍼 하나에 876개가 몰려 있다.
  - 읽는 시각으로 센 값(`queue_residence`, `current_execution`)은 약 3 KB 다.
  - TUI 가 해석하지 않는 항목 필드(`detail`, `since_iso`, `due_at_iso`, 항목의 `keeper_name`)가 218 KB 다.
- TUI 가 그리는 것은 출처마다 첫 항목, 위임 결과 항목, 개수다. 모든 항목을 그리는 곳은 없다.
  - 키퍼 목록 행: 위임 결과 항목이나 첫 항목 하나와 "외 N"(`bin/masc_tui_render_keepers.ml`)
  - 행의 활동·배지: 출처가 있는지와 그 출처의 첫 항목(`bin/masc_tui_keeper_list_model.ml`)
  - acting pane: 첫 일정, 일정 수, 위임 결과가 있는지, 읽기 오류가 있는지(`bin/masc_tui_acting_pane.ml`)
- 그래서 turns 행의 waiting 은 일곱 필드만 싣는다: `keeper_name`, `state`, `waiting_count`,
  `sources`(출처마다 행 수), `since`, `due_at`, `waiting_heads`.
  - `waiting_heads` 는 (source, wake producer) 짝마다 첫 행이다. inventory 순서를 지킨다.
  - 항목도 일곱 필드다: `source`, `waiting_on`, `what`, `wake_producer`, `since`, `due_at`,
    `next_action`.
- 읽는 시각으로 센 값은 싣지 않는다. 같은 inventory 는 같은 바이트가 된다.
- 몸통은 대기 종류 수만큼 자라고, 큐 길이만큼 자라지 않는다. 같은 시각의 운영 답을 이 모양으로 바꾸면
  27~28 KB 다. 30초 동안 연달아 읽은 다섯 쌍 가운데 넷은 바꾼 몸통이 같았다.
- 모든 행과 `detail` 은 대기 목록을 싣는 다른 응답(`dashboard_json`, MCP 도구)이 그대로 싣는다.

**K2. preview 는 요청한 만큼만 싣는다.**

- 질의 `preview` 는 `none`, `one`, `all` 가운데 하나다. 없으면 `none` 이다.
- `one` 이면 `preview_keeper=<이름>` 을 같이 보낸다. 그 키퍼의 준비 기록이 필요하면
  `preview_preparation=true` 도 보낸다.
- 지금 있는 `preparation_details_for=<이름>` 은 지운다. TUI 는 채팅 화면이 열려 있고 접히지 않았을 때만 이
  값을 보낸다(`bin/masc_tui.ml:4009-4011`). 이 경우가 `one` 과 `preview_preparation=true` 가 된다.
- 서버는 세 질의를 닫힌 합타입 하나로 읽는다. 맞지 않는 조합(`one` 에 이름이 없음, `none` 에 이름이 있음
  등)은 400 이다.
- 그리지 않는 preview 가 움직여도 몸통은 그대로다.
- web 의 turns 읽기는 lane, 시작 시각, status 만 쓴다(`dashboard/src/api/dashboard-keeper-turns.ts`).
  질의 없이 읽으므로 고칠 것이 없다.

**K3. turns 는 그 값을 쓰는 동안에만 읽는다.**

- turns 주소를 읽을 이유는 셋이다. 도는 turn, preview, 대기 목록이다.
- 화면에 그리는 곳:
  - 도는 turn: 채팅 화면, 키퍼 목록 화면의 행, Metrics, `@` 창
  - preview: 키퍼 목록 화면, 채팅 화면, `@` 창. 지금 `preview_on_screen`(`bin/masc_tui.ml:9061`)은 `@` 창을
    보지 않는다. K3 에서 더한다.
  - 대기 목록: 키퍼 목록 화면의 행과 Activity 칸. 읽는 조건은 Activity 칸이 보이는지가 아니라 키퍼 목록
    화면인지다. 칸을 숨겨도 행은 대기 목록을 쓴다.
- 화면과 상관없이 쓰는 곳:
  - 줄 선 채팅: 보내지 않은 줄이 있는 키퍼. turns 답이 control token 을 주고 그 줄을 보낸다
    (`bin/masc_tui.ml:29191-29195, 29226-29227`). token 은 다른 client 의 멈춤, 재개, 끊기에도 바뀐다.
    그 변화는 `keeper_turn_changed` 로만 온다.
  - 그리기 시계: `anything_running` 이 모든 화면에서 turns 를 본다(`bin/masc_tui.ml:44862-44866`).
    읽기를 멈출 때 turns 를 읽지 않은 것으로 표시한다. 그래야 시계가 옛 running 행을 보고 계속 돌지 않는다.
- 쓰는 곳이 없을 때 온 알림은 RFC-0480 §3.1 의 "읽을 빚"으로 남긴다. 쓰는 곳이 생기면 한 번 읽는다.
- 대기 목록 읽기와 turns 읽기를 하나로 합친다. 대기 목록을 부르던 알림(대기 목록 변화, 확인 대기,
  일정)도 같은 규칙을 따른다.
- `@` 창의 "방금 끝남"은 지금 이어진 두 읽기를 견줘 만든다. 끝난 시각은 읽은 시각으로 적는다
  (`bin/masc_tui.ml:29206-29215`). 읽지 않는 동안이 생기면 틀린다. 그래서 끝난 시각을 서버에서 받는다.
  - Keeper Owner 가 도는 turn 자리가 비는 시각을 메모리에 적는다. 그 자리도 메모리에 있다
    (`lib/server/server_routes_http_keeper_control.ml:185-205`).
  - turns 행에 그 시각을 싣는다. 서버를 다시 켜면 비어 있다. TUI 는 빈 값을 "최근에 끝난 turn 없음"으로
    읽는다.
  - `last_turn_ts` 는 쓰지 않는다. turn 없이 지나간 heartbeat 도 그 값을 바꾼다
    (`lib/keeper/keeper_heartbeat_loop.ml:1187`, `lib/keeper/keeper_registry.ml:161`).
- 죽은 배지("answering now")를 전제로 적은 주석과 문서를 고친다. 지금 찾은 곳은 아래와 같다. L0 에서 빠진
  곳을 더 찾는다.
  - `bin/masc_tui.ml:9050-9054`
  - `bin/masc_tui_types.ml:9830-9832, 10727-10730`
  - `bin/masc_tui_loader.ml:1218`
  - `bin/masc_tui_http.ml:3101-3103`
  - `lib/server/server_routes_http_keeper_control.ml:136-139`
  - RFC-0481 §3.4

**K4. 304 면 다시 해석하지 않는다.**

- `kept_reads` 는 304 에 앞의 값을 그대로 돌려준다(`bin/masc_tui_kept_reads.ml`). `memo_keeper_turns` 는
  같은 값을 알아보고 해석을 건너뛴다(`bin/masc_tui_loader.ml:1219-1224`). 지금은 304 가 없어서 이 길을
  쓰지 않는다.

## 5. 바뀌는 소비자

| 소비자 | 지금 | 바뀐 뒤 | 층 |
|---|---|---|---|
| web execution 화면 | 몸통이 실린 준비 알림으로 그린다 | 준비 알림의 게시를 GET 으로 읽어 같은 함수로 그린다 | L3 |
| 서버 관찰 입력 | 무효화 알림만 읽는다 | 그대로. `Backlog` 는 어느 표면도 다시 계산하지 않는다 | L2 |
| TUI 의 backlog 읽기 여섯 | execution 알림마다 | `Backlog` 알림, 피드 다시 열림, `[r]` | L2 |
| TUI 채팅 화면(자율 turn) | 모든 키퍼의 조각 알림을 받아 거른다 | 도는 turn 을 따라가는 읽기 하나 | L5 |
| TUI Acting 의 Everything 보기 | 조각마다 한 줄 | 조각 줄 없음 | L5 |
| TUI turns·대기 목록 | 화면과 상관없이 알림마다 200 | 쓰는 동안만 읽고, 같으면 304 | L1, L4 |
| TUI 줄 선 채팅 | turns 답마다 보내 본다 | 그대로. 보낼 줄이 있으면 화면과 상관없이 읽는다 | L1 |
| `@` 창의 방금 끝남 | 두 읽기를 견준다 | 서버가 준 끝난 시각 | L1 |
| web 의 turns 읽기 | preview 와 시계 값을 받고 버린다 | preview 가 빠지고 waiting 은 짝마다 첫 항목인 몸통 | L4, L4b |
| 대기 목록을 싣는 다른 응답 | 그대로 | 그대로 | |
| 성능 하네스 둘(`scripts/harness/perf/server_artifact_session.py`, `compare_server_artifacts.py`) | GET 몸통의 `execution_invalidated` 를 본다 | 그대로 | |

## 6. 시험

판정, 요청, 저장 상태만 시험한다. 문구와 배치는 시험하지 않는다.

- 판정: 준비 알림에 투영 필드가 없고 게시 번호가 있다. 무효화 알림의 모양은 그대로다.
- 판정: 같은 generation 에서 몸통이 다른 투영 둘은 게시 둘과 알림 둘을 낸다. 몸통이 같으면 둘째는
  아무것도 내지 않는다.
- 판정: 게시 읽기는 투영 계산을 부르지 않는다. 같은 번호의 `If-None-Match` 에는 304 다.
- 요청: web 은 준비 알림 하나에 게시 읽기 하나를 한다. 이미 가진 번호면 읽지 않는다.
- 저장: backlog 커밋 한 번에 `Backlog` 알림 한 번.
- 요청: TUI 는 execution 알림에 아무것도 읽지 않는다. `Backlog` 알림 하나에 §2.1 의 읽기를 한 번씩 한다.
- 판정: 기다리는 읽기는 신호를 구독한 뒤 page 를 읽는다. 그 사이에 붙은 항목에 바로 깨어난다.
- 판정: turn 끝을 page 읽기 앞뒤 어디에 끼워도 `ended` 답에는 끝 항목이 있다.
- 판정: 상한에 닿으면 빈 page 와 `running` 으로 답한다. 서버 상한은 TUI 요청 시간 제한보다 짧다.
- 판정: 조각을 journal 에 붙여도 observer 알림이 나가지 않는다.
- 요청: 채팅 화면의 도는 turn 하나에 따라가는 읽기가 하나다. 실패하면 백오프로 다시 읽는다. 채팅
  화면을 닫으면 그 switch 가 닫히고, 그 뒤에 온 답은 그리지 않는다. 다른 화면에서는 0개다.
- 판정: 시계만 다른 두 turns 몸통의 ETag 가 같다. `preview=none` 이면 preview 가 움직여도 같다. 질의가
  없으면 `none` 과 같다. 맞지 않는 질의 조합은 400 이다.
- 요청: 보낼 줄이 없으면, Overview 화면에서 `keeper_turn_changed`, 대기 목록 변화, 일정, 확인 대기
  알림을 받아도 turns 주소 읽기가 0개다. 보낼 줄이 있으면 1개다. 키퍼 목록 화면에 들어가면 1개다.
  대기 목록과 도는 turn 이 같이 바뀌어도 읽기는 하나다.
- 판정: `@` 창을 닫은 동안 끝난 turn 도 창을 열면 서버가 준 끝난 시각으로 보인다.
- 고칠 기존 시험: `test/test_tui_task_event.py`, `test/test_tui_autonomous_journal.ml`,
  `test/test_keeper_turns_route.ml`, `test/test_tui_decode.ml`, `test/test_server_observation_input.ml`,
  `dashboard/src/sse-store.test.ts`, `dashboard/src/projection-partial-observation.test.ts`.

## 7. 측정과 목표

연구 노트와 같은 중계로 층마다 잰다. Overview 화면에 두고 키를 누르지 않는다.

| 값(25초 안팎) | 지금 | 목표 |
|---|---:|---|
| `execution_snapshot` 바이트 | 4,874,250 | 알림 수 × 수백 바이트 |
| `keeper_turn_stream_event` 건수 | 9,647 | 0 |
| observer 알림 전체 | 초당 약 286 KB | 초당 약 30 KB(다른 종류가 그대로일 때) |
| `keepers/turns` 읽기 | 20번, 3,798,972 바이트 | 0번(보낼 채팅 줄이 없을 때) |
| TUI CPU, RSS | 16.3%, 426 MB | L0 에서 몫을 나눈 뒤 정한다 |

- 초당 약 30 KB 는 지금 값에서 두 종류를 뺀 계산이다. (7,359,205 − 4,874,250 − 1,710,224) ÷ 25.7.
- 서버 쪽은 게시 읽기가 투영 계산을 하나도 부르지 않는지 잰다. 같은 구간의 execution 계산 횟수가 L3 앞뒤로
  같아야 한다.
- 키퍼 목록 화면에서는 turns 읽기의 초당 횟수와 304 비율을 잰다. RFC-0480 §7 은 그 화면의 초당 요청
  수가 0.5번을 넘으면 타입 스트림으로 옮기라고 한다. 304 도 요청으로 센다. 넘으면 타입 스트림 RFC 를 쓴다.
- 채팅 지연은 늘지 않아야 한다. journal 항목의 시각과 TUI 가 그 항목을 그린 시각의 차이를 L5 앞뒤로 잰다.

## 8. 넣는 순서

| 층 | 내용 | 배포 | 확인 |
|---|---|---|---|
| L0 | 측정 도구를 `scripts/` 로 올린다. PTY 캡처와 화면별 대기 측정은 한 화면 문법 RFC §9 의 8 이 올리는 도구와 같다. 읽기 전용 중계는 이 층이 올린다. 기준선을 다시 잰다. JSON 해석 몫을 읽기별로 나눈다. 조사 넷: execution 알림 다섯 건의 완료 종류, turns·대기 목록·control token 을 쓰는 곳, Work 읽기 결과의 backlog 밖 입력, 죽은 배지 주석 | 없음 | 기준선 표, 조사 결과 |
| L1 | K3 전부: 읽는 때, 두 읽기 합치기, 끝난 시각. 질의는 지금 것 그대로 | 서버, TUI. hard cut 이 아니다 | Overview 화면의 turns 읽기 0번 |
| L2 | E2 | 서버 먼저, 그다음 TUI. hard cut 이 아니다 | backlog 읽기 수가 backlog 커밋 수와 같다 |
| L3 | E1 | 서버와 web 한 묶음. hard cut | execution 바이트 = 알림 수 × 수백 바이트, 서버 계산 횟수 그대로 |
| L4 | K1 | 서버와 TUI 한 묶음. hard cut | 키퍼 목록의 turns 바이트, 304 비율 |
| L4b | K2 | TUI 먼저, 그다음 서버. hard cut | preview 바이트 |
| L5 | T1~T3 | 서버 먼저, 그다음 TUI. hard cut | 조각 알림 0, 채팅 지연 그대로 |
| L6 | 다시 잰다 | 없음 | §7 표 |

- 한 배포에는 hard cut 을 하나만 넣는다.
- 서버와 TUI 는 따로 도는 프로그램이다. 판이 섞였을 때 일어나는 일과 받아들이는 것을 아래에 적는다.

| 층 | 새 서버와 옛 client | 옛 서버와 새 TUI |
|---|---|---|
| L1 | 옛 TUI 는 끝난 시각 필드를 모르고 지금처럼 돈다 | 끝난 시각이 오지 않는다. "방금 끝남"이 보이지 않는다. 받아들인다 |
| L2 | 옛 TUI 는 `Backlog` 를 풀지 못한 알림으로 세고 넘어간다(`bin/masc_tui.ml:25952-25954`). execution 알림으로 지금처럼 읽는다 | `Backlog` 가 오지 않는다. backlog 읽기가 `[r]` 전까지 멈춘다. 그래서 서버를 먼저 올린다 |
| L3 | 이미 열린 옛 web 탭은 몸통 없는 알림을 그리지 못한다. 다시 열 때까지 execution 화면이 멈춘다. 받아들인다. web bundle 은 서버가 내려 준다(`lib/server/server_routes_http_routes_frontend.ml:187`) | TUI 와 상관없다 |
| L4 | 옛 TUI 는 `waiting_on` 이 없는 waiting 행을 풀지 못한다. turn 행은 그대로 읽고, 대기 칸만 조회 불가로 보인다(`Keeper_waiting_invalid`). 그래서 서버와 TUI 를 한 묶음으로 올린다 | `waiting_heads` 와 `sources` 가 없다. 같은 일이 새 TUI 에서 생긴다 |
| L4b | 옛 TUI 는 질의를 보내지 않아 preview 를 잃는다(`lib/tui_decode.ml:5144-5146`). 그래서 TUI 를 먼저 올린다 | 옛 서버는 새 질의를 모르고 지금 몸통을 준다. 새 TUI 는 그대로 읽는다 |
| L5 | 옛 TUI 는 자율 turn 의 글을 실시간으로 못 본다. 채팅 화면을 다시 열면 journal 에서 읽는다. 받아들인다 | 옛 서버는 `follow` 를 모르고 바로 답한다. 상태 필드도 없다. 새 TUI 의 따라가기가 돌지 않는다. 그래서 서버를 먼저 올린다 |

## 9. 하지 않는 것

- execution 투영의 뜻이 바뀔 때만 알리기(결정 9). 따로 RFC 로 낸다. 리뷰에서 나눠야 할 값이 네 부류로
  나왔다.
  - 저장된 사실
  - 기한이 지나면 바뀌는 분류: `quiet_reason`, `recent_done` 의 24시간 구간 등. 서버가 `next_deadline`
    에 다시 계산한다.
  - 계산·게시 기록: `build_ms`, `payload_bytes`, `execution_publication_generation`
  - 읽는 시각으로 센 나이
  - 여기에 Candle 덧씌우기가 투영 함수 밖에서 여러 길로 붙는다. web 은 서버가 보낸 나이를 그대로
    그린다. 뜻이 바뀔 때만 몸통을 받으면 나이가 멈춘다. 그래서 web 이 시각에서 나이를 세게 바꾸는 일도
    같이 해야 한다.
- 읽기를 숫자로 막는 gate, cap, cooldown.
- execution 투영을 행 단위 차이로 보내기. 몸통을 쓰는 곳이 web 하나다(§10).
- web 의 actor 있는 execution 읽기 비용 줄이기. 처음 열 때와 force 읽기는 지금 길 그대로다.
- 채팅 operation 알림 바꾸기. web 이 내용을 쓴다.
- `workspace_dataset_changed`(초당 약 49건) 줄이기. 구성을 먼저 잰다(§12).
- `keepers/turns` 를 키퍼 하나씩 읽거나 타입 스트림으로 옮기기. L6 측정 뒤에 정한다.
- 서버가 turns 몸통을 만드는 비용 줄이기. 304 도 몸통을 만들어 해시를 낸다.

## 10. 고르지 않은 길

| 길 | 고르지 않은 이유 |
|---|---|
| 준비 알림 뒤 web 이 지금 execution 경로를 읽는다 | 로그인한 web 은 actor 를 실어서, 게시가 바뀔 때마다 투영을 새로 계산하는 길을 탄다(`:1957-2001`). 약 5초마다 web actor 하나당 계산이 한 번 는다. 지금 web 은 SSE 몸통으로 그려서 이 계산이 없다 |
| 준비 알림도 무효화 알림처럼 force 로 읽는다 | 열린 탭마다 서버가 투영을 다시 계산한다. 그 완료가 또 알림을 낸다 |
| 알림 글의 바이트로 중복을 거른다 | 투영을 뺀 알림은 같은 generation 안에서 바이트가 같다. 새 투영의 알림이 버려진다 |
| 무효화와 준비를 한 모양으로 합친다 | 서버 관찰 입력이 둘을 가를 수 없다. 자기 알림으로 다시 계산하는 고리가 생긴다 |
| execution 투영을 행 단위 차이로 보낸다(RFC-0477 의 타입 스트림 방식) | 바뀐 행만 간다. 대신 codec, 서버의 차이 계산, 다시 연결할 때의 snapshot, web reducer 가 새로 생긴다. 몸통을 쓰는 곳이 web 하나라 얻는 것이 작다 |
| 시계 필드 이름 목록을 빼고 해시해서 알릴지 정한다 | 이름으로 거르는 분류기다. 새 시계 값이 생기면 조용히 깨진다. 기한 분류와 Candle 덧씌우기도 다루지 못한다 |
| observer 에 종류별로 받지 않는 설정을 둔다 | TUI 바이트만 줄인다. backlog 읽기를 잘못 다시 하는 문제가 남는다. 연결마다 상태가 생긴다 |
| `on_task_mutation_fn` 으로 `Backlog` 를 알린다 | base_path 를 받지 않는다. execution 캐시 무효화가 이미 그 자리를 쓴다 |
| observer 세션에 따라갈 키퍼를 등록한다 | 지금 SSE 연결을 그대로 쓴다. 대신 세션마다 키퍼 표, 등록 route, 다시 연결한 뒤의 재등록이 생긴다. 알림과 읽기 두 단계도 남는다 |
| 채팅마다 SSE 연결을 연다 | 새 SSE codec 과 연결 수명 관리가 생긴다 |
| 서버 상한 없이 기다린다 | handler 가 client 가 떠난 것을 모른다. 버려진 읽기가 쌓인다 |
| 조각 알림을 시간 구간으로 묶는다 | cooldown 이다. 여전히 모든 observer 에게 간다 |
| turns 에 서버 revision 을 두고 몸통 전에 304 를 답한다 | RFC-0474 는 turns 를 캐시로 감싸는 안을 받지 않았다. 대기 목록 원본이 회복되면 다음 읽기에서 오류가 사라져야 해서다. 미리 304 를 답하면 같은 문제가 생긴다 |
| `last_turn_ts` 를 끝난 시각으로 쓴다 | turn 없이 지나간 heartbeat 도 그 값을 바꾼다. 쉬는 키퍼에 "방금 끝남"이 켜진다 |
| TUI 가 zstd 로 받는다 | 바이트만 줄인다. 해석 CPU 와 읽는 횟수는 그대로다 |

## 11. 운영자에게 묻는 것

1. 「바뀐 것만 보낸다」를 둘로 나눴다. 이 RFC 는 「몸통 없이 바뀌었다는 알림만 보낸다」를 넣는다. 「뜻이
   바뀔 때만 보낸다」는 따로 RFC 로 낸다(§9).
   - 권장: 이대로. TUI 가 받는 바이트는 이 RFC 만으로 줄어든다(§7).
   - 대가: web 은 지금처럼 게시마다 몸통을 받는다. SSE 대신 압축된 GET 으로 받는다. 시각 값이 바뀌면
     게시가 나가므로 약 5초마다다.
2. 서버 밖에서 고친 backlog 는 피드가 다시 열리거나 `[r]` 을 눌러야 보인다.
   - 권장: 이대로. Runtime config 와 같다.
   - 대가: 지금은 약 5초 안에 보이던 손 편집이 `[r]` 전까지 안 보인다.
3. L0 와 층마다 운영 서버 앞 읽기 전용 중계로 다시 잰다.
   - 권장: 허락. 연구 노트와 같은 조건이다. 중계는 쓰기를 거절하고 주소, 바이트, 알림 종류만 남긴다.
   - 대가: 재는 동안 TUI 하나가 운영 서버에 더 붙는다.

## 12. 따로 남길 것

- `workspace_dataset_changed` 가 초당 약 49건이다. 알림 하나가 다른 알림 여럿을 낳는지 구성을 잰다.
- turn 조각은 이번 측정에서 초당 약 375건이다. RFC-0481 §1.5 는 2026-11-02 에 초당 약 27건을 적었다
  (60초 한 번, 신뢰 낮음). 도는 키퍼 수가 달라 두 값을 바로 견주지 않는다. 조각 한 건이 토큰 몇 개인지,
  그때 도는 turn 이 몇 개였는지 같이 잰다.
