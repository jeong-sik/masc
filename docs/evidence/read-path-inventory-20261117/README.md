# 읽기 경로 전수 검사 근거 (2026-11-17, 리뷰 반영 2026-11-18)

분석은 [docs/research/2026-11-17-read-path-inventory.md](../../research/2026-11-17-read-path-inventory.md) 에 있다. 이 디렉터리는 그 숫자를 다시 만드는 스크립트와 그 결과다.

## 기준

- 코드: origin/main `0542d471eedf5`
- 환경: macOS(Darwin 27.2), Python 3.14.4
- 운영 데이터: `/Users/dancer/me/.masc` 를 2026-11-18 10:26:59~10:35:59 KST 에 훑었다. 파일 내용은 열지 않고 `lstat` 만 했다.
- 로그: 서버 로그 `masc-start-20261117T131957Z.log`(22:19:59 재시작본)와 `masc-start-20261117T122217Z.log`(21:22:17 기동본), TUI 로그 `masc-tui-28494.log`. 원문에는 Keeper 이름이 있어 여기 두지 않았다. `log_numbers.py` 가 집계만 낸다.

## 파일

| 파일 | 무엇 |
|---|---|
| `data_families.py` | 상태 디렉터리를 저장소·파일 묶음별로 센다. 파일 경로는 쓰지 않는다. Keeper 이름이 남은 행이 있으면 아무것도 쓰지 않고 멈춘다 |
| `data-stores.tsv` | 저장소별 개수·크기·24시간 변화 |
| `data-families-keeper-screen.tsv` | 화면이 Keeper 마다 읽는 파일 묶음(`data-families.tsv` 에서 거른 것) |
| `code_read_sites.py` | `lib/`·`bin/` 의 읽기 호출을 모두 찾는다. 한 줄에서 같은 함수를 두 번 불러도 한 곳이다 |
| `code-read-sites.tsv` | 2,264곳: 위치, 감싼 binding, 함수, 모양, 막히는 방식(mech), tree(lib·bin), layer(call·wrapper) |
| `route_reach.py` | 이름 기반 호출 그래프로 진입점에서 닿는 읽기를 센다(깊이 30) |
| `site-triggers.tsv` | 읽기 호출마다 닿는 진입점 수와 가장 가까운 진입점 |
| `focus-routes.txt` | TUI 가 부르는 route 아홉 개. `summarize.py` 와 아래 거르기가 같이 읽는다 |
| `loop-entries.txt` | 진입점으로 넣은 주기 루프 binding 7개 |
| `route-reads-focus.tsv` | focus route, Keeper turn, 주기 루프에서 닿는 내용 읽기와 최단 경로 |
| `gate-keepers-keeper-list-branch.tsv` | `/gate/keepers` 가 실제로 도는 갈래와 관리자 확인만 진입점으로 센 내용 읽기 |
| `summarize.py` | 위 표에서 분석 문서의 표를 만든다 |
| `summary.md` | `summarize.py` 출력(표 A~E) |
| `tui-paths.txt` | TUI 코드에 적힌 `/api/v1/...` 경로 172개 |
| `log_numbers.py` | 서버·TUI 로그에서 분석 문서 1절·6절 숫자를 센다 |
| `log-numbers.txt` | `log_numbers.py` 를 두 창으로 돌린 출력 |

## 다시 만들기

이 디렉터리에서 시작한다. 스크립트를 새 디렉터리에 복사해서 그 안에서 돌린다. 이 디렉터리의 결과는 덮어쓰지 않는다. `route_reach.py` 는 `code_read_sites.py` 를 import 하고, `summarize.py` 는 자기 옆의 TSV 와 `focus-routes.txt` 를 읽는다.

```bash
EVIDENCE="$PWD"
R=<masc 저장소, 0542d471eedf5>
OUT="$R/artifacts/read-path-inventory-<날짜>"
LOGS=/Users/dancer/me/.masc/logs
mkdir -p "$OUT" && cp "$EVIDENCE"/*.py "$EVIDENCE"/loop-entries.txt "$EVIDENCE"/focus-routes.txt "$OUT"/ && cd "$OUT"
nice -n 19 taskpolicy -d utility python3 data_families.py /Users/dancer/me/.masc --out data-families.tsv --stores-out data-stores.tsv
awk -F'\t' 'NR==1 || $1 ~ /^keepers\/<keeper>\.(json|decisions\.jsonl|decisions\.jsonl\.1)$/ || $1 ~ /^keepers\/<keeper>\/(metrics|execution-receipts|turn-records)\/<ym>\/<dd>\.jsonl$/ || $1 ~ /^keepers\/<keeper>\/event-queue-(v19\.json|transitions-v11\.jsonl)$/ || $1 == "schedules.json"' data-families.tsv > data-families-keeper-screen.tsv
python3 code_read_sites.py "$R" --out code-read-sites.tsv
python3 route_reach.py "$R" --sites code-read-sites.tsv --route-out route-reads.tsv \
  --site-out site-triggers.tsv --entry Keeper_agent_run.run_turn \
  $(sed 's/^/--entry /' loop-entries.txt) \
  --edge Dashboard_projection_cache.operator_snapshot_json_ref=Operator_control.snapshot_read
python3 summarize.py > summary.md
{ cat focus-routes.txt loop-entries.txt; echo Keeper_agent_run.run_turn; } > focus-entries.txt
awk -F'\t' 'NR==FNR {keep[$0]=1; next} FNR==1 || (($1 in keep) && $5 != "meta" && $5 != "open" && $5 != "dir" && $5 != "db")' \
  focus-entries.txt route-reads.tsv > route-reads-focus.tsv
python3 route_reach.py "$R" --sites code-read-sites.tsv --route-out gate-route-reads.tsv \
  --site-out gate-site-triggers.tsv --no-routes \
  --entry Keeper_tool_surface.handle_keeper_list \
  --entry Dashboard_projection_cache.with_current_gate_keeper_observations \
  --entry Server_auth.authorize_token_bound_permission_request
awk -F'\t' 'NR==1 || ($5 != "meta" && $5 != "open" && $5 != "dir" && $5 != "db")' \
  gate-route-reads.tsv > gate-keepers-keeper-list-branch.tsv
(cd "$R" && rg -o --no-filename '"/api/v1/[^"?%]*' bin -g 'masc_tui*.ml' | tr -d '"' | sort -u) > tui-paths.txt
python3 log_numbers.py --server-log "$LOGS/masc-start-20261117T131957Z.log" --tui-log "$LOGS/masc-tui-28494.log" \
  --since '2026-11-17 22:22:00' --until '2026-11-17 22:56:33'
python3 log_numbers.py --server-log "$LOGS/masc-start-20261117T122217Z.log" \
  --since '2026-11-17 21:27:00' --until '2026-11-17 21:39:59'
```

`/gate/keepers` 는 따로 센다. 그 route 는 `Keeper_tool_surface.dispatch` 로 도구 하나만 부르는데, 이름 그래프는 dispatch 의 모든 갈래로 이어진다. 그 진입점들을 첫 실행에 넣으면 `site-triggers.tsv` 의 분류가 바뀌어서 `--no-routes` 로 따로 돌린다.

`route-reads.tsv`(약 20 MB)와 `data-families.tsv` 전체(약 21만 행)는 크기 때문에 넣지 않았다. 둘 다 위 명령으로 다시 만든다. 상태 디렉터리 한 번 훑기는 위 명령으로 9분 걸렸다(2026-11-18, 파일 약 406만 개). `taskpolicy -b` 로 디스크 우선순위를 더 낮추면 3시간쯤 걸렸다.

`route_reach.py` 출력은 Python hash seed 와 상관없이 같다. `PYTHONHASHSEED=1` 과 `2` 로 돌린 `route-reads.tsv`·`site-triggers.tsv` 의 sha256 이 같았다.

## 한계

- 그래프의 선은 호출이 아니라 참조다. 닿는다는 것은 읽을 수도 있다는 위 한계다. 캐시는 모른다.
- `match` 디스패치는 모든 갈래로 이어진다. `/gate/keepers` 는 그래서 202곳으로 세지고, 실제 갈래만 따라가면 15곳이다.
- record 필드와 functor 를 거친 호출은 놓친다. ref 에 담긴 함수는 `--edge` 로 하나만 이었다(`operator_tool.ml:438` 이 `operator_snapshot_json_ref` 에 `Operator_control.snapshot_read` 를 넣는다).
- route 등록 429곳 중 24곳은 경로가 한 줄 문자열 상수가 아니어서 이름으로 남겼다(로그인·계정·초대 화면 22곳, 경로를 계산하는 2곳). 같은 경로를 두 파일이 등록하면 `@파일모듈` 을 붙여 나눴다.
- mech 는 기준 커밋의 구현을 읽고 붙였다. `Systhread_host` 와 `Dated_jsonl` 끝 읽기는 부른 쪽이 풀 작업인지에 따라 도는 곳이 다르다(분석 문서 4절). 이 표는 부른 쪽을 모른다.
- `Unix.openfile` 114곳 중 36곳은 쓰기·만들기 플래그로 연다. SQLite 84곳에도 쓰기가 섞여 있다. 그래서 2,264곳은 읽기만 센 수가 아니다.
