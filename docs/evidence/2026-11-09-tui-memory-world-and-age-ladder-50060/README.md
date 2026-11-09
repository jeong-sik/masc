# Memory 개요의 사다리 줄 · 월드 줄과 Keepers 둘째 줄의 facts 칸 (#50017, #50060)

Memory 개요 머리에 줄 둘이 있고 Keepers 목록 Detailed 둘째 줄 끝에 칸 하나가 있어요. 사다리 줄(`일반: 처음 본 뒤 █▄▃▂ …`)과 `facts` 칸은 #50017(D2)이, 월드 줄(`월드: 공유 주장 42건 …`)은 #50060(D2c)이 그려요. 합성 서버를 띄우고 #50060 head 의 증명 빌드를 80x24 · 120x35 · 200x45, 색 있음과 `NO_COLOR=1`, 한국어와 영어로 찍었어요. 화면 글과 배치는 시험으로 고정하지 않아서(헌법 354-355행) 이 폴더의 화면과 표가 근거예요.

## 방법

찍은 빌드는 하나예요. 줄과 칸이 없는 전 화면은 찍지 않았어요. 전은 "없음"이고, 읽는 곳이 `bin/` 에 0곳이라는 근거는 아래 질문 표에 있어요.

- 증명 빌드: Minimal manual checks run 42535404917(성공). 입력 `native-tui-source-sha` 는 #50060 head 커밋 `3f8feac46b5ca6e9f351ea1d6160c7051dd0e386` 예요. `masc-tui` sha256 은 `83ad0e35bcc973e1ff9c9fa80ec507cc828d24b69fe58c86c5febeb6ae2e6a9d` 이고, `--build-commit` 이 같은 커밋을 말해요. #50017 이 이미 main 에 있어서 이 빌드 하나에 사다리와 월드가 같이 들어 있어요.
- main 과의 차이: #50060 은 main 에 `fc5b36b3eb99` 로 병합됐어요. 증명 빌드 커밋과 이 병합 커밋에서 아래 열다섯 파일이 같아요(`git diff --quiet 3f8feac46b5c fc5b36b3eb99 -- <파일>`). `bin/masc_tui_memory_world.ml` · `.mli`, `bin/masc_tui_render_memory.ml`, `bin/masc_tui_keeper_age_ladder.ml` · `.mli`, `bin/masc_tui_render_keepers.ml`, `bin/masc_tui_keeper_axis.ml`, `bin/masc_tui_keeper_memory_reading.ml`, `bin/masc_tui_workspace_read.ml`, `bin/masc_tui_http.ml`, `bin/masc_tui_loader.ml`, `lib/tui_decode_workspace_memory.ml`, `lib/tui_decode_memory_health.ml`, `lib/workspace/workspace_utils_paths_backend.ml`, `lib/server/server_auth.ml`.
- 같은 두 커밋에서 다른 `bin/` 파일은 여섯 곳이고 Memory 와 Keepers 를 그리는 줄이 아니에요. main 은 `bin/masc_tui.ml` 과 `bin/masc_tui_render.ml` · `.mli` 에서 안 쓰는 별칭 `json_assoc_member_opt` 를 지웠고, `bin/masc_tui_observer.ml` · `.mli` 에서 이벤트 이름 상수 대신 문자열을 쓰고, `bin/main_eio.ml` 의 도움말 글 한 줄을 고쳤어요.

서버와 실행이에요.

- 세션마다 합성 서버를 `127.0.0.1` 의 빈 포트(18980~19229 범위)에 새로 띄웠어요. 8935 와 사용자의 서버는 쓰지 않았고, TUI 는 `env -i` 로 환경을 비우고 빈 HOME 으로 띄워서 실제 서버 주소나 자격 증명을 읽지 않았어요.
- 서버가 답하는 경로는 `/health`(TUI 의 빌드 커밋을 돌려줘요), roster(`/api/v1/gate/keepers`), 빈 턴 목록(`/api/v1/keepers/turns`), TUI 환경설정(`/api/v1/tui/preferences`, 언어만 달라요), memory-health(`/api/v1/dashboard/keeper-memory-health`), 월드 인벤토리(`/api/v1/dashboard/workspace-memory-inventory`), 빈 SSE 흐름이에요. 나머지는 404 라서 머리줄에 `HTTP [partial] · operator quiz read failed +3` 이 보이고 Memory 화면 아래쪽에 `Memory input: HTTP 404: fake server: no such route` 가 보여요. 두 글은 #50017 · #50060 과 상관없어요.
- memory-health 응답은 PR head 의 디코더(`lib/tui_decode_memory_health.ml`)와 합계 규칙(`lib/keeper/keeper_memory_health_totals.ml`)을 읽고 맞췄어요. 디코더가 합계와 행이 어긋나면 읽기를 거부해서, 행 8개와 합계가 그려지는 것이 모양이 맞는다는 확인이에요.
- 월드 인벤토리는 TUI 가 `expected_base_path` 와 `expected_masc_root` 를 붙여 불러요. 응답에 `x-masc-workspace-read: matched-v1` 헤더가 한 번 있어야 TUI 가 읽기를 받아들여요(`bin/masc_tui_workspace_read.ml`). 합성 서버는 2xx 응답에 이 헤더를 달고, `fail-nohdr` 상태의 인벤토리만 달지 않아요. **이 헤더 규칙은 코드를 읽어서 옮겼고 실제 서버에서 확인하지 않았어요.** 이번에 돌린 모든 세션의 인벤토리 요청 166건이 요청 로그에서 모두 두 키만 실었어요(값은 경로라서 로그에 안 남겼어요).

tmux 3.6a 안에서 `TERM=xterm-256color` 로 띄웠고 색 없음은 `NO_COLOR=1` 이에요. 크기는 80x24, 120x35, 200x45 이고, 머리가 접히는 조건을 보려고 80x35, 120x24, 200x24 를 더했어요. 단계는 이래요.

1. TUI 를 띄우고 머리줄에 `HTTP [connected|partial]` 이 나올 때까지 기다려요. 터미널이 묻는 색 질문에 답해요.
2. `:` 로 팔레트를 열고 `go Memory` 를 쳐서 Memory 화면을 열어요(키 11번). 월드 줄이 그 상태의 글을 낼 때까지(최대 40초) 기다리고, 화면이 멈춘 것을 확인한 뒤 찍어요. 읽는 중 상태는 요청 1.5초 뒤에, 값을 읽은 뒤의 실패는 둘째 읽기가 끝난 뒤에 찍어요.
3. Keepers 는 Memory 화면을 먼저 연 뒤 `3` 으로 열고 `v` 로 레이아웃을 돌려 Detailed 를 찍어요. Compact 와 Grouped 도 찍어 봤지만 폴더에는 넣지 않았어요.

## 합성 Keeper

이름은 모두 지어낸 이름이에요. 나이 구간은 오래된 쪽부터 7일 이상 · 1일~7일 · 1시간~1일 · 1시간 미만이고, 구간 합이 `facts` 예요.

| keeper | facts | 나이 구간 | 확인하려는 것 |
| --- | --- | --- | --- |
| alpha-failing | 12 | 2 · 3 · 4 · 3 | 실패 중. 구간이 모두 차 있는 작은 값. 80칸에서 DETAIL 이 가장 많이 잘려요 |
| beta-unrecorded | 5 | 0 · 0 · 2 · 3 | 비어 있는 구간은 `0` |
| gamma-skewed | 0 | 측정 없음 | 스냅샷이 없는 keeper. `facts ?`, 머리의 `미측정 키퍼 1명` |
| delta-mixed | 340 | 120 · 90 · 80 · 50 | 세 자리 합계 |
| epsilon-busy | 1204 | 700 · 300 · 150 · 54 | 네 자리 합계. 가장 넓은 `facts` 칸 |
| zeta-unseeded | 27 | 0 · 0 · 0 · 27 | 1시간 미만에만 몰림 `000█` |
| eta-quiet | 8 | 8 · 0 · 0 · 0 | 7일 이상에만 몰림 `█000` |
| theta-idle | 61 | 10 · 20 · 21 · 10 | idle |

플릿 합계는 행에서 더해서 만들었어요. 일반 기억 1657개 = 840 + 413 + 257 + 147 이고, 원본 4개와 합쳐 전체 1661개예요. 인벤토리 값은 claim 42, conflict 3 이에요.

## 결과

### Memory 개요 머리

머리의 줄 순서는 합계 → `일반:` 구성 → `일반:` 사다리 → `원본:` → `Librarian:` → `월드:` 예요. 120x35 색 있음에서 옮겼고, 200x45 · 색 없음에서도 글이 같아요. 줄바꿈 자리만 달라요(비교는 `memory-lines.txt`).

한국어:

```text
   전체 기억 1661개 · 일반 1657 + 원본 4 · 저장 ≈115.1k tok · 키퍼 8명 · 저장 추정량, 턴 입력 아님
   일반: 관측 1497 / 파생 160 · 근거 무효화 5건
   일반: 처음 본 뒤 █▄▃▂ · 7일 이상 840개 · 1일~7일 413개 · 1시간~1일 257개 · 1시간 미만 147개 · 미측정 키퍼 1명
   원본: 무효화 1건
   Librarian: 미읽은 턴 19개 · 연속성 지연 원자 0개 (미측정 키퍼 0명) · 서버 시작 후 실패 0건
   월드: 공유 주장 42건 · 충돌 3건 · 브리핑 current
   정렬 [s]: 기억 많은 순  ·  [u]: 토큰  [/]: 필터
```

영어:

```text
   Total 1661 facts · 1657 ordinary + 4 source · stored ≈115.1k tok · 8 keepers · stored estimate, not turn input
   Ordinary: 1497 observed / 160 derived · 5 support invalidations
   Ordinary: since first seen █▄▃▂ · 7d or older: 840 · 1d to 7d: 413 · 1h to 1d: 257 · under 1h: 147
             1 keeper not measured
   Source: 1 invalidation
   Librarian: 19 turns unread · 0 atoms behind in continuity (0 keepers not measured) · 0 failures since server start
   World: 42 claims · 3 conflicts · briefing current
   Sort [s]: Facts (Most)  ·  [u]: tokens  [/]: Filter
```

읽는 법이에요.

- 사다리 줄의 막대 네 칸은 왼쪽이 가장 오래된 구간(7일 이상)이고 오른쪽이 1시간 미만이에요. 높이는 같은 줄 안에서 가장 큰 구간에 대한 비율이고, 빈 구간은 `0`, 재지 못한 것은 `?` 예요(증명 빌드 키 문서의 `facts` 항목).
- `미측정 키퍼 1명` 은 스냅샷이 없는 gamma-skewed 예요. 영어는 120칸에서 사다리 줄이 두 줄이 되어 `1 keeper not measured` 가 아랫줄로 내려가요.
- 월드 줄은 인벤토리를 읽은 값이에요. claim · conflict 건수는 curator 가 기록한 개수이고 주장이 사실인지 확인한 값이 아니에요. briefing 상태는 서버가 보낸 말 그대로예요(증명 빌드 키 문서 `Memory marks` 절, 키 문서 sha256 `b115618e…`).

### 월드 줄의 상태

서버가 이렇게 답했을 때 월드 줄이 이렇게 그려져요. 표의 글은 120x35 색 있음에서 옮겼어요. 같은 상태를 120x35 · 200x45 의 색 있음 · 색 없음으로 찍은 화면과 글이 같고, 비교한 화면 수는 오른쪽 열이에요(한국어와 영어 각각).

| 상태 | 합성 서버의 답 | 한국어 | 영어 | 비교한 화면 수 |
| --- | --- | --- | --- | --- |
| reading | 정상 답을 6초 붙잡아요. 요청 1.5초 뒤에 찍었어요 | `월드: ?` | `World: ?` | 4 |
| current | `available`, claim 42, conflict 3, briefing `current` | `월드: 공유 주장 42건 · 충돌 3건 · 브리핑 current` | `World: 42 claims · 3 conflicts · briefing current` | 4 |
| pending | 같은 값, briefing `pending` | `월드: 공유 주장 42건 · 충돌 3건 · 브리핑 pending` | `World: 42 claims · 3 conflicts · briefing pending` | 4 |
| stale | 같은 값, briefing `stale` | `월드: 공유 주장 42건 · 충돌 3건 · 브리핑 stale` | `World: 42 claims · 3 conflicts · briefing stale` | 4 |
| unavailable | 같은 값, briefing `unavailable`(`building` 키 없음) | `월드: 공유 주장 42건 · 충돌 3건 · 브리핑 unavailable` | `World: 42 claims · 3 conflicts · briefing unavailable` | 4 |
| building | briefing `pending`, building `target 40 remaining 17` | `월드: 공유 주장 42건 · 충돌 3건 · 브리핑 pending · building, 40개 중 17개 남음` | `World: 42 claims · 3 conflicts · briefing pending · building, 17 of 40 left` | 4 |
| zero | claim 0, conflict 0, briefing `current` | `월드: 공유 주장 0건 · 충돌 0건 · 브리핑 current` | `World: 0 claims · 0 conflicts · briefing current` | 2 |
| no-ledger | `status: missing` | `월드: 장부 없음` | `World: no ledger` | 4 |
| fail-401 | 401, 본문 `unauthorized` | `월드: ? · 읽기 실패` | `World: ? · read failed` | 4 |
| fail-nohdr | 200 과 올바른 본문, `x-masc-workspace-read` 헤더만 없음 | `월드: ? · 읽기 실패` | `World: ? · read failed` | 2 |
| value-then-fail 전 | 첫 읽기는 `current` 값 | `월드: 공유 주장 42건 · 충돌 3건 · 브리핑 current` | `World: 42 claims · 3 conflicts · briefing current` | 4 |
| value-then-fail 후 | 둘째 읽기부터 401 | `월드: 공유 주장 42건 · 충돌 3건 · 브리핑 current · 읽기 실패` | `World: 42 claims · 3 conflicts · briefing current · read failed` | 4 |

읽는 법이에요.

- `?` 는 아직 못 읽었거나 읽는 중이라서 아는 것이 없다는 뜻이고 0 이 아니에요. 처음 읽기가 실패하면 `? · 읽기 실패` 예요. 401 과 헤더 없는 200 이 같은 글로 그려져요.
- `zero` 의 `0` 건은 값이고 `장부 없음`도 값이에요(서버가 장부 파일을 못 찾았다고 말한 것). 둘 다 `?` 와 달라요.
- `briefing` 뒤 낱말은 서버가 보낸 말 그대로예요. 한국어 화면에서도 `current` `pending` `stale` `unavailable` 을 번역하지 않아요.
- `building, 17 of 40 left` 는 briefing 을 만드는 한 번의 작업에서 남은 항목 수예요. 모델이 지금 돌고 있다는 뜻은 아니에요(증명 빌드 키 문서).
- value-then-fail 은 값을 읽은 뒤 다시 읽다가 실패한 경우예요. 값은 그대로 두고 뒤에 `읽기 실패` 만 붙어요. TUI 는 Memory 개요가 열려 있는 동안만 인벤토리를 읽고, 답을 받으면 성공이든 실패든 `memory_world_read_interval_s` 동안 다시 읽지 않아요(`bin/masc_tui.ml` 의 `launch_owed_memory_world`). 요청 로그에서 잰 첫 읽기와 둘째 읽기 사이는 60초였어요(8번 세션).

### 어느 크기에서 보이나

머리는 Memory 개요 제목 줄 아래 첫째와 둘째 구분선 사이의 줄이에요. 화면 높이에 안 맞으면 한 줄로 접어요(`memory_compact_fleet_row`). 접히면 사다리 줄과 월드 줄은 둘 다 안 그려져요. 24줄 화면은 머리 7줄까지 그렸고, 8줄이 되는 영어 120칸에서는 접었어요. 폭도 줄 수를 바꿔요. 영어는 120칸에서 사다리 줄이 두 줄이 되고 200칸에서 한 줄이에요. 접힌 크기는 있는 그대로 찍었어요.

| 크기(색 있음) | 한국어 | 영어 |
| --- | --- | --- |
| 80x24 | 접혀요 `v:전체 · 미읽은 턴 19개` | 접혀요 `v:details · 19 unread turns` |
| 120x24 | 그려져요, 머리 7줄 | 접혀요 `v:details · 19 unread turns` |
| 200x24 | 그려져요, 머리 7줄 | 그려져요, 머리 7줄 |
| 80x35 | 그려져요, 머리 10줄 | 그려져요, 머리 11줄 |
| 120x35 | 그려져요, 머리 7줄 | 그려져요, 머리 8줄 |
| 200x45 | 그려져요, 머리 7줄 | 그려져요, 머리 7줄 |

120칸에서 가장 긴 월드 줄(`building`, 한국어)은 78칸이라 한 줄에 들어가요. 80x35 에서는 이 줄이 두 줄로 나뉘고 아랫줄이 윗줄의 `월드:` 뒤에 맞춰 들여써져요(`memory-building-80x35-color-ko`).

### Keepers 둘째 줄의 facts 칸

Detailed 둘째 줄 오른쪽 칸이에요. 왼쪽 DETAIL 글(`task task-0001 · health failing` 등)은 빼고 칸만 옮겼어요. 세 크기 · 색 있음과 없음 · 한국어와 영어 12조합에서 칸의 글이 같아요. Keepers 화면은 한국어 설정에서도 영어로 그려져요.

| keeper | 둘째 줄 오른쪽 칸(그려진 대로) | `facts` 칸 너비 | 칸 전체 너비 |
| --- | --- | --- | --- |
| alpha-failing | `failing 3h05m  ◷ ?  lag 4  +13m02s +2 -1  ··✓··⊘✓··✓✗✗  facts 12 ▄▆█▆` | 13 | 69 |
| beta-unrecorded | `failing ?  ◷ ?  lag 0  +47s +1 -0  ········✓··✗  facts 5 00▅█` | 12 | 61 |
| gamma-skewed | `failing ?  ◷ ?  lag 0  ··········✗·  facts ?` | 7 | 44 |
| delta-mixed | `◷ ?  lag 12  +9m02s +14 -6  stale ×1  ✓⊘··✓··✓·⊘✓✓  facts 340 █▆▅▃` | 14 | 66 |
| epsilon-busy | `◷ ?  lag 2  +4m02s +31 -12  ????✓✓✓✓✓✓✓✓  facts 1204 █▄▂▁` | 15 | 57 |
| zeta-unseeded | `◷ ?  lag 1  +35m02s +27 -0  ????????????  facts 27 000█` | 13 | 55 |
| eta-quiet | `◷ ?  lag 0  +8d02h +0 -0  facts 8 █000` | 12 | 38 |
| theta-idle | `◷ ?  lag 0  +25m02s +4 -2  ✓✓✓✓✓✓✓✓✓✓✓✓  facts 61 ▄▇█▄` | 13 | 54 |

읽는 법이에요.

- `facts 12 ▄▆█▆` 는 일반 기억 12개를 나이 구간으로 센 막대예요. 막대 규칙은 Memory 개요의 사다리 줄과 같고 높이는 그 keeper 안에서의 비율이에요. `facts ?` 는 스냅샷이 없는 keeper 예요.
- `facts` 칸 너비는 `facts ` 6칸 + 합계 숫자 + 빈칸 1칸 + 막대 4칸이에요. 합계가 두 자리면 13칸, 세 자리면 14칸, 네 자리면 15칸이고 `facts ?` 는 7칸이에요(캡처에서 잰 값).
- `lag` · `+13m02s +2 -1` 은 이미 있던 기억 칸이에요. 이 칸들과 `facts` 는 Memory 화면이 memory-health 를 읽은 뒤에만 나와요. Compact 와 Grouped 에는 `facts` 칸이 없어요(두 레이아웃의 24개 화면을 열어 봤어요).

### DETAIL 자리

둘째 줄은 칸이 DETAIL 글보다 먼저 자리를 가져가요(증명 빌드 커밋의 `bin/masc_tui_render_keepers.ml` 532-545행, `fit_cells` 와 `detail_space`). 캡처에서 잰 둘째 줄 폭(들여쓰기 6칸 제외)은 80칸에서 73, 120칸에서 113, 200칸에서 137이고 모든 줄이 같은 폭에서 끝나요. `DETAIL 에 남는 자리 = 줄 폭 - 칸 너비 - 1` 은 코드에서 읽은 셈이고, 아래 표의 잰 값은 캡처에서 DETAIL 글의 칸 수를 센 거예요.

| keeper (80칸) | 칸 너비(잰 값) | 남는 자리(셈) | 그려진 DETAIL(잰 값) | DETAIL 전체 너비 | `facts` 칸이 없었다면 남는 자리(셈) |
| --- | --- | --- | --- | --- | --- |
| alpha-failing | 69 | 3 | `ta…` (3칸) | 31 | 18 |
| beta-unrecorded | 61 | 11 | `task task-…` (11칸) | 31 | 25 |
| gamma-skewed | 44 | 28 | `task task-0001 · health fai…` (28칸) | 31 | 37 |
| delta-mixed | 66 | 6 | `task …` (6칸) | 14 | 22 |
| epsilon-busy | 57 | 15 | `task task-0001` | 14 | 32 |
| zeta-unseeded | 55 | 17 | `task task-0001` | 14 | 32 |
| eta-quiet | 38 | 34 | `task task-0001` | 14 | 48 |
| theta-idle | 54 | 18 | `task task-0001 · …` (18칸) | 28 | 33 |

잘린 줄 5개(alpha-failing, beta-unrecorded, gamma-skewed, delta-mixed, theta-idle)는 남는 자리의 셈과 그려진 DETAIL 칸 수가 모두 같아요. `facts` 칸이 없었다면 남는 자리는 칸 너비와 칸 사이 빈칸 2칸을 더해 셌고 코드를 돌린 값은 아니에요.

120칸과 200칸에서는 DETAIL 이 8줄 모두 끝까지 그려졌어요. 남는 자리가 가장 좁은 줄이 120칸에서 43칸, 200칸에서 67칸이에요(셈). DETAIL 하한 논의는 #50022 에 있어요. 위 표는 그 논의에 쓸 수 있는 잰 값이에요.

### Memory 화면을 열지 않았을 때

Memory 화면이 memory-health 를 읽기 전에 Keepers 를 먼저 열면 `facts` 칸이 안 나와요. 같은 합성 서버에서 Memory 를 거치지 않고 `3` 만 눌러 Detailed 를 찍었어요(120x35 색 있음).

| keeper | 둘째 줄 오른쪽 칸(Memory 를 거치지 않았을 때) |
| --- | --- |
| alpha-failing | `failing 3h05m  ◷ ?  mem ?  ··✓··⊘✓··✓✗✗` |
| beta-unrecorded | `failing ?  ◷ ?  mem ?  ········✓··✗` |
| gamma-skewed | `failing ?  ◷ ?  mem ?  ··········✗·` |
| delta-mixed | `◷ ?  mem ?  ✓⊘··✓··✓·⊘✓✓` |
| epsilon-busy | `◷ ?  mem ?  ????✓✓✓✓✓✓✓✓` |
| zeta-unseeded | `◷ ?  mem ?  ????????????` |
| eta-quiet | `◷ ?  mem ?` |
| theta-idle | `◷ ?  mem ?  ✓✓✓✓✓✓✓✓✓✓✓✓` |

### 색 없음과 언어

색 있음과 `NO_COLOR=1` 에서 Memory 머리의 글이 같고(세 크기 · 두 언어), Keepers 목록 줄의 글도 같아요. 200칸의 오른쪽 패널은 목록 글 밖이라 비교에서 뺐어요. 인물 그림(`▀` 8줄)은 색 있음의 120칸 이상에서만 그려지고 색 없음에서는 그려지지 않아서, 색 없음은 목록이 그만큼 위에 있어요. 한국어와 영어는 Memory 머리의 글이 다르고(`일반:` · `Ordinary:`, `월드:` · `World:`) Keepers 목록은 같아요.

## 질문 표

층이 답하는 운영자 질문이에요. 전은 읽는 곳을 센 값이고 후는 캡처에서 본 값이에요.

| 질문 | 전 | 후 |
| --- | --- | --- |
| 플릿 전체의 일반 기억이 1시간 · 1일 · 7일을 기준으로 얼마나 오래됐나 | 답할 수 없어요. 나이 구간(`age_bins`)을 읽는 곳이 `bin/` 에 0곳이에요(#50017 병합 직전 `21588e51e632`) | Memory 개요 머리의 `일반:` 사다리 줄. 머리가 화면 높이에 안 맞으면 접혀요 |
| 이 keeper 의 기억이 어느 나이에 몰려 있나 | 답할 수 없어요. 같은 이유예요 | Keepers Detailed 둘째 줄의 `facts` 칸. Memory 화면을 한 번 연 뒤에만 나와요 |
| 공유 주장과 충돌이 몇 건이고 briefing 이 현재 상태인가 | 답할 수 없어요. 월드 인벤토리 경로와 디코더를 읽는 곳이 `bin/` 에 0곳이에요(#50060 병합 직전 `ef98039ac562`) | Memory 개요 머리의 `월드:` 줄. 머리가 화면 높이에 안 맞으면 접혀요 |

`git grep -c age_bins 21588e51e632 -- bin` 은 일치가 없고 `git grep -c -e workspace-memory-inventory -e Tui_decode_workspace_memory ef98039ac562 -- bin` 도 일치가 없어요. Memory 화면은 이 캡처들에서 `:` `go Memory` Enter(키 11번)로 열었어요. 더 짧은 길은 찾지 않았어요. 다른 화면으로 답할 수 있는지는 세지 않았어요.

## 이 폴더가 말하지 않는 것

- 실제 서버에서 찍은 것이 아니에요. 건수 · 시각 · briefing 상태는 합성 값이고, 인벤토리 응답의 `x-masc-workspace-read` 헤더 규칙은 코드를 읽어서 옮겼어요. 실제 서버가 같은 헤더를 보내는지는 확인하지 않았어요.
- `? · 읽기 실패` 는 합성 서버의 401 과 헤더 없는 200 두 가지로만 만들었어요. 실제 서버의 401 본문이 같은 모양인지는 확인하지 않았어요. 읽기를 미루는 경우(작업공간 확인 전)는 만들지 않았어요.
- 값을 읽은 뒤의 `읽기 실패` 는 첫 읽기 정상, 둘째 읽기 401 한 경로만 찍었어요. `장부 없음` 뒤에 실패하는 경우와 실패가 여러 번 이어지는 경우는 찍지 않았어요.
- 머리가 접히면 사다리 줄과 월드 줄이 안 그려져요. 80x24 와 120x24 영어에서 접혀요. 접힌 한 줄은 `v:details` 로 전체 요약을 읽으라고만 해요. 24줄과 35줄 사이, 23줄 이하 높이는 찍지 않았어요.
- `facts` 칸은 Memory 화면이 memory-health 를 읽기 전에는 없어요. 이 선행 조건이 의도인지는 이 폴더가 판단하지 않아요.
- 80칸에서 `facts` 칸이 DETAIL 을 `ta…` 까지 줄이는 줄이 있어요. 이 합성 데이터에서 잰 값이고, 실제 keeper 들의 일정 · 기억 칸 길이가 어떤지는 재지 못했어요.
- 머리줄의 `HTTP [partial] · operator quiz read failed +3`, Memory 화면의 `Memory input: HTTP 404`, 200칸 오른쪽 패널의 `feed closed: MCP initialize: HTTP 404` 는 합성 서버가 그 경로를 답하지 않아서 생겨요. #50017 · #50060 의 변경이 아니에요.
- 이 빌드에 없는 동작은 말하지 않았어요. 합성 서버와 캡처 스크립트는 저장소에 넣지 않았어요.

## 파일

이번에 돌린 세션은 134개이고 화면 170장을 찍었어요. 그중 49장을 이 폴더에 넣었어요.

`<화면>-<상태>-<크기>-<색>-<언어>` 이름에 파일이 셋씩 있어요. `.png` 는 화면이고 32색으로 줄였어요. `.ansi.gz` 는 같은 화면의 ANSI 원문이고 `.txt` 는 글만 옮긴 거예요.

- `memory-<상태>-…`: Memory 개요. 상태는 `current`(세 크기 · 색 · 언어 12조합), `reading` `pending` `stale` `unavailable` `building` `zero` `no-ledger` `fail-401` `fail-nohdr` `value-then-fail-before` `value-then-fail-after`(120x35 색 있음, 한국어와 영어)예요. `memory-current-80x35-…` `memory-current-120x24-…` `memory-current-200x24-…` `memory-building-80x35-…` 는 접힘이 높이와 폭 중 무엇에 달렸는지 보려고 더한 크기예요(색 있음만 찍었어요).
- `keepers-detailed-<크기>-<색>-en`: Memory 화면을 거친 Keepers Detailed, 6조합이에요. Keepers 화면은 한국어 설정에서도 글이 같아서 영어만 넣었어요(한국어 6조합과의 비교는 `keepers-second-rows.txt`). `keepers-detailed-unread-120x35-color-en`: Memory 를 거치지 않은 경우예요.
- `memory-lines.txt`: 이번에 돌린 모든 세션의 사다리 줄과 월드 줄이에요(그려지지 않았으면 그렇게 적었어요). `keepers-second-rows.txt`: 모든 세션의 Keepers 둘째 줄이에요. 폴더에 넣지 않은 캡처의 근거예요.

파일 검사예요. 이번에 돌린 세션의 글 파일(`.txt`, `.ansi`) 340개를 절대 경로, 토큰, 사용자 이름, 이메일 패턴으로 훑었고 나온 것이 없어요. 이 README 도 같은 패턴으로 훑었어요. 이미지는 8장을 열어서 확인했어요(`memory-current-200x45-nocolor-ko`, `memory-current-120x24-color-en`, `memory-building-80x35-color-ko`, `memory-fail-nohdr-120x35-color-en`, `memory-value-then-fail-after-120x35-color-ko`, `keepers-detailed-80x24-color-en`, `keepers-detailed-200x45-nocolor-en`, `keepers-detailed-unread-120x35-color-en`). 나머지는 같은 화면의 글 파일로 대조했어요. 이 머신에서는 `dune build` 와 `dune runtest` 를 돌리지 않았어요.

