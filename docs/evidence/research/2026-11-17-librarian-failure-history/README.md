# Librarian 실패 이력 셈 기록, 2026-11-17

[연구 문서](../../../research/2026-11-17-librarian-failure-history.md)가 이 기록을 근거로 쓴다.
이 폴더에는 커밋, fix, 이슈, PR, 코드 크기를 센 표와 그 표를 만든 스크립트가 있다.

이 표들은 요약이다. 원자료가 아니다.
git log 원문, 커밋 목록 JSON, 이슈와 PR 의 JSON 은 넣지 않았다.
요청 본문, 기억 문장, 대화 원문도 넣지 않았다. 표에 든 글은 커밋 제목과 PR 제목뿐이다.
시기마다 RFC 를 읽고 쓴 작업 기록도 이 폴더에 없다.

## 환경

| 항목 | 값 |
| --- | --- |
| 저장소 | `jeong-sik/masc` |
| 센 커밋 | main `fa5aead0d999`(2026-11-17 21:55 KST). 실행을 시작할 때 로컬 `origin/main` 이 이 커밋이었다 |
| 실행 중 바뀐 것 | 다른 프로세스가 로컬 `origin/main` 을 커밋 21개만큼 새 쪽으로 옮겼다. 그중 #52817, #52818 이 `lib/lane_addon/` 을 건드린다. 아래 수에는 들지 않는다 |
| git 으로 센 것 | 커밋, 코드 크기, 시험 수. 모두 위 커밋에서 읽었다 |
| GitHub 에서 받은 것 | 이슈와 닫힌 PR. 2026-11-17 22:10 KST 무렵의 상태다 |
| 달마다 묶은 표 | 2026-11-18 에 같은 커밋 목록을 달로 다시 묶었다 |
| 실행한 쪽 | Claude Code 세션, 읽기만 했다. `git fetch` 는 돌리지 않았다 |

## 파일

| 파일 | 내용 |
| --- | --- |
| [commits-weekly.md](commits-weekly.md) | 주마다, 종류마다 센 커밋 |
| [commits-monthly.md](commits-monthly.md) | 달마다, 종류마다 센 커밋 |
| [fix-themes.md](fix-themes.md) | fix 주제 23개의 수, 첫 날과 마지막 날, 예 |
| [fix-themes-monthly.md](fix-themes-monthly.md) | fix 주제를 달마다 센 수, 주제 이름 맞춤표 |
| [fix-loops.md](fix-loops.md) | 주제마다 fix 가 있었던 주의 수, 하루 최대 수 |
| [fix-unmatched.md](fix-unmatched.md) | 어느 주제에도 들지 않은 fix 제목 67개 |
| [feat-then-fix.md](feat-then-fix.md) | feat 뒤 7일 안에 같은 파일을 건드린 fix |
| [closed-prs.md](closed-prs.md) | 닫힌 PR 과 병합 없이 닫힌 수 |
| [weekly-issues.md](weekly-issues.md) | 주마다 열리고 닫힌 이슈 |
| [code-size.md](code-size.md) | 코드와 시험의 줄 수 |
| [file-churn.md](file-churn.md) | 2026-09-01 이후 커밋이 많은 파일 15개 |
| `scripts/parse06.py` | git log 출력에서 커밋을 고르고 종류와 주를 붙인다 |
| `scripts/themes06.py` | fix 제목에 주제를 붙이고 표를 낸다 |
| `scripts/feat_fix06.py` | feat 뒤와 앞 7일의 fix 를 센다 |

## 명령과 본 결과

명령은 저장소 루트에서 돌린다. `S` 는 이 폴더의 `scripts` 다.
출력 파일(`06-*.txt`, `06-*.json`)은 저장소 밖 작업 폴더에 썼다.
실행 때는 ref 를 `origin/main` 으로 적었다. 다시 돌릴 때는 `fa5aead0d999f` 로 바꿔 적는다.
파일 이름의 `06` 은 이 셈에 붙인 작업 번호다. `<기본 경로 넷>` 은 아래 「커밋 고르기」 명령의 앞 네 경로다. `<모든 경로>` 는 `keeper_memory_*` 까지 다섯이다.

```sh
S=docs/evidence/research/2026-11-17-librarian-failure-history/scripts
```

### 커밋 고르기

```sh
git log origin/main --no-merges --since=2026-06-01 --format='@@@%H%x09%cI%x09%s' --name-only -- \
  'lib/keeper/keeper_librarian_*' lib/lane_addon/ addons/keeper-librarian/ addons/exact_worker.py \
  'lib/keeper/keeper_memory_*' > 06-gitlog-raw.txt
python3 -I $S/parse06.py 06-gitlog-raw.txt 06-commits.json
```

- git log 는 커밋 1,069개를 냈다.
- 기본 경로 넷(`keeper_librarian_*`, `lib/lane_addon/`, `addons/keeper-librarian/`, `addons/exact_worker.py`)을 건드린 커밋이 766개다.
- `keeper_memory_*` 만 건드리고 제목에 `librarian` 이나 `사서` 가 있는 커밋이 19개다. 합쳐 785개다.
- 단위는 merge 가 아닌 커밋이다. 날짜는 git 이 적은 committer 날짜다. 785개 중 60개는 UTC(Z)로 적혀 있고, 표는 그 값을 바꾸지 않고 묶었다.
- 종류는 제목 앞머리(`^([a-zA-Z]+)(\([^)]*\))?!?:`)다. 그 밖은 `other` 다. `rebase(stack)` 10개, 콜론 없는 `fix` 제목 3개, 앞머리 없는 제목이 여기에 든다.
- 결과는 [commits-weekly.md](commits-weekly.md) 다.

같은 경로로 다시 센 값은 이렇다.

```sh
git log origin/main --no-merges --since=2026-06-01 --format=%h -- <기본 경로 넷> | wc -l      # 766
git log origin/main --first-parent --since=2026-06-01 --format=%h -- <기본 경로 넷> | wc -l   # 763
git log origin/main --format=%ci --reverse -- <기본 경로 넷> | head -1                        # 2026-06-12
```

### 달마다 묶기

```sh
python3 -I -c "import json,collections,sys; m=collections.defaultdict(collections.Counter); [m[x['date'][:7]].update([x['type']]) for x in json.load(open(sys.argv[1]))]; [print(k, dict(m[k]), sum(m[k].values())) for k in sorted(m)]" 06-commits.json
```

- 달마다 합은 45, 31, 28, 154, 318, 209 다. 더하면 785 다.
- 결과는 [commits-monthly.md](commits-monthly.md) 다.

### fix 주제

```sh
python3 -I $S/themes06.py 06-commits.json 06-theme-assign.json > 06-themes-out.md
```

- fix 제목 337개 중 270개가 주제 하나 이상에 들었다. 67개는 들지 않았다.
- 정규식 23개는 `scripts/themes06.py` 에 있다. 영어와 한국어 키워드다.
- 결과는 [fix-themes.md](fix-themes.md), [fix-themes-monthly.md](fix-themes-monthly.md), [fix-unmatched.md](fix-unmatched.md) 다.
- [fix-loops.md](fix-loops.md) 는 `06-theme-assign.json` 에서 주와 날을 다시 센 표다. 그 셈의 명령은 남아 있지 않다.

### feat 뒤의 fix

```sh
python3 -I $S/feat_fix06.py 06-commits.json > 06-featfix-out.md
```

- feat 는 232개다. 뒤 7일은 평균 6.41, 중앙값 4, p90 19, 최대 48, 하나 이상 83%(192/232)다.
- 앞 7일은 평균 4.35, 중앙값 2, p90 11, 최대 28, 하나 이상 71%(165/232)다.
- `lane_addon_runtime.ml(i)` 와 `keeper_librarian_runtime.ml(i)` 를 같은 파일로 세지 않으면 뒤 7일은 평균 2.34, 하나 이상 57%(132/232)다. 앞 7일은 평균 1.41, 38%(88/232)다. 두 파일은 커밋 대부분이 건드려서 따로 봤다.
- 결과는 [feat-then-fix.md](feat-then-fix.md) 다.

### revert

```sh
rg -i '^@@@.*(revert|되돌)' 06-gitlog-raw.txt
git log origin/main --since=2026-06-01 -i -E --grep='revert|되돌|This reverts commit' --format='%h %cs %s' -- <모든 경로>
git log origin/main --since=2026-06-01 --format='%h %cs %s' | rg -i '^\S+ \S+ revert' | wc -l      # 16
```

- 고른 785개 중 revert 커밋은 0개다. 저장소 전체에는 같은 기간 16개가 있다.
- 경로에 닿는 revert 는 하나다. `15e7f2711aa42`(2026-07-27)가 `keeper_memory_os_io.ml(i)` 를 건드린다. 제목에 `librarian` 이 없어 고르지 않았다.
- PR 안에서 되돌린 뒤 squash 된 것이 둘 있다. #28625 와 #24335 다.

### 닫힌 PR

```sh
gh pr list -R jeong-sik/masc --search "librarian" --state closed --limit 300 --json number,title,mergedAt,closedAt
for r in '<2026-09-01' '2026-09-01..2026-09-10' '2026-09-11..2026-09-20' '2026-09-21..2026-09-30' \
         '2026-10-01..2026-10-31' '2026-11-01..2026-11-10' '>2026-11-10'; do
  gh pr list -R jeong-sik/masc --search "librarian created:$r" --state closed --limit 1000 --json number,title,mergedAt,closedAt,createdAt; done
```

- 첫 명령은 300개에서 잘린다. 가장 새 300개(닫힌 날 2026-09-23 ~ 11-17)만 온다. 그중 10개가 병합 없이 닫혔다.
- 구간 일곱의 수는 481, 72, 150, 324, 443, 237, 205 다. 더하면 1,912개다. 구간끼리 겹친 PR 은 없다.
- 1,749개가 병합됐고 163개(8.5%)가 병합 없이 닫혔다.
- 결과는 [closed-prs.md](closed-prs.md) 다.

### 코드 크기

```sh
P=fa5aead0d999f
git ls-tree -r --name-only $P -- lib/keeper | rg '^lib/keeper/keeper_librarian_.*\.ml$' \
  | while read f; do git cat-file -p "$P:$f" | wc -l; done | awk '{s+=$1;n++} END {print n, s}'
git ls-tree -r --name-only $P -- addons/keeper-librarian addons/exact_worker.py
git ls-tree -r --name-only $P -- test | rg -i 'librarian|lane_addon'
```

- 첫 명령은 `.mli` 와 `lib/lane_addon` 에도 같은 방법으로 돌렸다.
- 시험 파일마다 `git cat-file -p "$P:$f" | rg -c 'test_case'` 로 줄을 셌다.
- 코드는 54,690줄이다. OCaml 모듈 122개가 53,945줄, `addons/` 가 745줄이다. 시험은 `.ml` 86개, 71,345줄, `test_case` 줄 1,783개다.
- Python 시험 넷 중 `test_librarian_preflight_report.py` 에 `def test_` 가 50개 있다. 나머지 셋에는 없다.
- 시험 줄 수는 73,828(`.ml` 71,345 + `.py` 2,483)이다. 코드 54,690줄의 1.35배다.
- 결과는 [code-size.md](code-size.md) 다.

### 이슈

```sh
gh issue list -R jeong-sik/masc --search "librarian" --state all --limit 3000 --json number,title,state,createdAt,closedAt
```

- 처음에는 `--limit 500` 으로 돌려 500개에서 잘렸다. 위 명령은 `--limit 3000` 으로 다시 받은 것이다. 577개다.
- 열린 것이 91개, 닫힌 것이 486개다. 첫 이슈는 2026-04-19 에 만들어졌다.
- 열린 이슈의 나이는 2026-11-17 00:00Z 기준 중앙값 13일, 최대 99일이다. 48개가 11월에 열렸다.
- 결과는 [weekly-issues.md](weekly-issues.md) 다.

### 파일마다 센 커밋

- `06-commits.json` 에서 2026-09-01 이후 커밋 681개를 파일마다 셌다. 건드린 파일은 311개다.
- 이 셈의 명령은 남아 있지 않다. 줄 수는 `fa5aead0d999f` 에서 `wc -l` 로 셌다.
- 결과는 [file-churn.md](file-churn.md) 다.

## 확인하지 못한 것

- fix 주제는 키워드로 붙였다. 오탐이 있다. #42862 의 「컴파일 복구」가 재시작 주제에, #52243 의 「63자」가 크기 주제에 든다.
- 이슈와 PR 의 수는 `librarian` 이라는 말이 제목이나 본문에 있는지로 정해진다. Librarian 과 상관없는 것이 섞였는지는 하나씩 보지 않았다.
- 이슈와 PR 의 수는 받은 때의 상태다. 다시 받으면 달라진다.
- `test_case` 는 줄 수다. `let test_case …` 같은 도우미도 한 줄로 센다.
- feat 뒤의 fix 는 창이 겹친다. feat 하나가 fix 를 불렀다는 뜻으로 읽을 수 없다.
- [fix-loops.md](fix-loops.md) 와 [file-churn.md](file-churn.md) 는 만든 명령이 남아 있지 않다. 다시 만들려면 `06-commits.json` 과 배정 파일에서 세어야 한다.
- 운영 수치(읽지 않은 턴, pass 시간)는 이 폴더에 없다. 연구 문서 2.6 은 [다른 측정 기록](../../librarian-lag-20261117/README.md)의 값을 옮겼다.
