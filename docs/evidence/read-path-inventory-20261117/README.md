# 읽기 경로 전수 검사 근거 (2026-11-17)

분석은 [docs/research/2026-11-17-read-path-inventory.md](../../research/2026-11-17-read-path-inventory.md) 에 있다. 이 디렉터리는 그 숫자를 다시 만드는 스크립트와 그 결과다.

## 기준

- 코드: origin/main `0542d471eedf5`
- 환경: macOS(Darwin 27.2), Python 3.14.4
- 운영 데이터: `/Users/dancer/me/.masc`, 2026-11-17 22~23시 KST. 파일 내용은 열지 않고 `lstat` 만 했다.
- 서버 로그: `/Users/dancer/me/.masc/logs/masc-start-20261117T131957Z.log`(22:19:59 재시작본), TUI 로그 `masc-tui-28494.log`. 로그 원문은 여기 두지 않았다. 숫자는 분석 문서 6절에 있다.

## 파일

| 파일 | 무엇 |
|---|---|
| `data_families.py` | 상태 디렉터리를 저장소·파일 묶음별로 센다 |
| `data-stores.tsv` | 저장소별 개수·크기·24시간 변화. 스크립트가 쓰는 `max_path`(가장 큰 파일 경로) 칸은 뺐다 |
| `code_read_sites.py` | `lib/`·`bin/` 의 읽기 호출을 모두 찾는다 |
| `code-read-sites.tsv` | 읽기 호출 2,383곳: 위치, 감싼 binding, 함수, 모양, 막히는 곳 |
| `route_reach.py` | 이름 기반 호출 그래프로 진입점에서 닿는 읽기를 센다(깊이 30) |
| `site-triggers.tsv` | 읽기 호출마다 닿는 진입점 수와 가장 가까운 진입점 |
| `route-reads-focus.tsv` | TUI 가 읽는 route, Keeper turn, 주기 루프에서 닿는 내용 읽기와 최단 경로 |
| `gate-keepers-keeper-list-branch.tsv` | `/gate/keepers` 가 실제로 부르는 갈래(`handle_keeper_list`, 관리자 관측)만 진입점으로 센 내용 읽기 |
| `summarize.py` | 위 표에서 분석 문서의 표를 만든다 |
| `summary.md` | `summarize.py` 출력(표 A~D) |
| `loop-entries.txt` | 진입점으로 넣은 주기 루프 binding 7개 |
| `tui-paths.txt` | TUI 코드에 적힌 `/api/v1/...` 경로 172개 |

## 다시 만들기

스크립트를 새 디렉터리에 복사해서 그 안에서 돌린다. 이 디렉터리의 결과는 덮어쓰지 않는다. `summarize.py` 는 자기 옆의 TSV 를 읽는다.

```bash
R=<masc 저장소, 0542d471eedf5>
OUT="$R/artifacts/read-path-inventory-<날짜>"
mkdir -p "$OUT" && cp *.py loop-entries.txt "$OUT"/ && cd "$OUT"
python3 data_families.py /Users/dancer/me/.masc --out data-families.tsv --stores-out data-stores.tsv
python3 code_read_sites.py "$R" --out code-read-sites.tsv
python3 route_reach.py "$R" --sites code-read-sites.tsv --route-out route-reads.tsv \
  --site-out site-triggers.tsv --entry Keeper_agent_run.run_turn \
  $(sed 's/^/--entry /' loop-entries.txt)
python3 summarize.py > summary.md
awk -F'\t' 'NR==1 || (($1 ~ /^ROUTE (GET|PREFIX_GET) \/api\/v1\/(keepers\/turns|gate\/keepers|dashboard\/scheduled-automation|tui\/preferences|dashboard\/health-line|operator|keepers\/|dashboard\/logs)$/ || $1 == "Keeper_agent_run.run_turn" || $1 ~ /^Server_/) && $5 != "meta" && $5 != "open" && $5 != "dir" && $5 != "db")' route-reads.tsv > route-reads-focus.tsv
python3 route_reach.py "$R" --sites code-read-sites.tsv --route-out gate-route-reads.tsv \
  --site-out gate-site-triggers.tsv --entry Keeper_tool_surface.handle_keeper_list \
  --entry Dashboard_projection_cache.with_current_gate_keeper_observations
awk -F'\t' 'NR==1 || (($1 == "Keeper_tool_surface.handle_keeper_list" || $1 == "Dashboard_projection_cache.with_current_gate_keeper_observations") && $5 != "meta" && $5 != "open" && $5 != "dir" && $5 != "db")' gate-route-reads.tsv > gate-keepers-keeper-list-branch.tsv
cut -f1-7 data-stores.tsv > data-stores-no-paths.tsv
```

`/gate/keepers` 는 따로 센다. 그 route 는 `Keeper_tool_surface.dispatch` 로 도구 하나만 부르는데, 이름 그래프는 dispatch 의 모든 갈래로 이어진다. 그 두 진입점을 첫 실행에 넣으면 `site-triggers.tsv` 의 분류가 바뀌어서 따로 돌린다.

여기 있는 결과 중 셋은 원 출력을 줄인 것이다. `route-reads-focus.tsv` 와 `gate-keepers-keeper-list-branch.tsv` 는 위 `awk` 로 거른 것이고, `data-stores.tsv` 는 `max_path` 칸을 뺀 것(위 `cut`)이다. `data-families.tsv`(약 20만 행)와 전체 `route-reads.tsv`(약 20 MB)는 크기 때문에 넣지 않았다. 상태 디렉터리 한 번 훑기는 약 9분 40초 걸렸다(파일 약 390만 개).

## 한계

- 그래프의 선은 호출이 아니라 참조다. 닿는다는 것은 읽을 수도 있다는 위 한계다. 캐시는 모른다.
- `match` 디스패치는 모든 갈래로 이어진다. `/gate/keepers` 는 그래서 202곳으로 세지고, 실제 갈래만 따라가면 14곳이다.
- record 필드·ref·functor 를 거친 호출은 놓친다. operator snapshot 루프가 그 예다.
- 함수 모양(mech)은 기준 커밋의 구현을 읽고 붙였다. 래퍼 구현이 바뀌면 표도 다시 만든다.
