# Librarian 재설계 RFC 의 근거 기록, 2026-11-18

[RFC](../../../rfc/RFC-librarian-call-only-proposes-and-one-writer-per-keeper-commits-in-one-line.md)가 이 기록을 근거로 쓴다.
이 폴더에는 스크립트, 표, 집계한 수만 있다. TLA+ 모델과 설정은 `specs/bug-models/Librarian*.tla` 에 있고 결과는 RFC §21 에 있다. Keeper 의 대화, Memory 의 글, 요청 본문은 넣지 않았다.

코드에서 읽은 것은 모두 main `55a024cc280e` 의 것이다.

## 폴더

| 폴더 | 담은 것 | RFC 절 |
| --- | --- | --- |
| `state-table/` | RFC 본문의 상태 표를 그대로 읽어 빠진 쌍을 찾는 스크립트 | §9 |
| `cut-callers/` | 컷이 지우는 모듈을 직접 부르는 바깥 단위의 목록과 그것을 만드는 스크립트 | §19.2 |
| `slot-outcome/` | slot 결과 타입의 생성자를 코드에서 뽑는 스크립트, 생성자마다 한 행인 표, 둘을 맞추는 스크립트 | §7.2 |
| `seat-replay/` | 자리 재생 스크립트와 그 출력 | §15 |

## 상태 표 (`state-table/`)

`check_state_table.py` 는 RFC 파일의 「9.3」 절을 읽는다. 표의 사본을 따로 두지 않는다.

```
python3 check_state_table.py <RFC 파일> [pairs.tsv]
```

- 상태 7개와 사건 12개의 쌍 84개를 본다. 행이 없는 쌍, 조건 없이 겹치는 행, 조건이 붙은 행 하나뿐인 쌍, 모르는 상태나 사건 이름이 있으면 실패한다.
- 끝난 묻기의 표는 (물은 것, 결과) 32쌍을 본다. 쌍마다 행이 정확히 하나여야 한다.
- 조건들이 모든 경우를 덮는지는 보지 않는다. 그것은 모델이 본다.
- `pairs.tsv` 는 스크립트가 RFC 에서 뽑아 쓴 것이다. 손으로 고치지 않는다.
- RFC 의 표를 고치면 같은 커밋에서 `pairs.tsv` 를 다시 만든다.
- 스크립트가 보는 것은 행이 있는가다. 조건들이 서로 겹치지 않는지, 모든 경우를 덮는지, 「하는 일」 칸이 §7~§8 과 맞는지는 보지 않는다. 한 행의 「하는 일」 칸 안에 든 조건도 읽지 않는다.

결과: 쌍 84개, 행 89개, 묻기 결과 32쌍. 실패 0.
표에서 행 하나를 지우거나, 겹치게 하거나, 조건을 붙이면 스크립트가 실패하는 것을 네 가지 변이로 확인했다.

## slot 결과 표 (`slot-outcome/`)

| 파일 | 내용 |
| --- | --- |
| `types.txt` | 분류가 읽는 타입 16개. 파일과 타입 이름 |
| `extract_constructors.py` | 인터페이스 파일에서 그 타입들의 생성자를 뽑는다 |
| `constructors.tsv` | 뽑은 생성자 163개 |
| `table.tsv` | 생성자마다 갈래 하나. 168행 |
| `not-constructors.tsv` | 생성자가 아닌 것 9행. 방문이 없는 slot, 잡힌 slot, 답 검사의 결과, Agent-Core 에 새로 생길 생성자 둘 |
| `check_table.py` | `constructors.tsv` 와 `table.tsv` 를 맞춘다 |

```
python3 extract_constructors.py <저장소 루트> < types.txt > constructors.tsv
python3 check_table.py constructors.tsv table.tsv
```

- 행이 없는 생성자, 생성자가 없는 행, 조건으로 갈리지 않는 두 행, 열두 갈래 밖의 값이 있으면 실패한다.
- 다른 타입을 읽으라는 행(`> 파일 타입`)이 행 없는 타입을 가리켜도 실패한다. 세 뿌리 타입에서 닿지 않는 타입이 있어도 실패한다.
- 다섯 생성자는 타입 있는 칸으로 둘로 나뉜다. Claude 와 Codex 의 `Context_window_exceeded`, Codex 와 Muse 의 `Turn_failed`, Claude 의 `Turn_failed_with_observation` 이다.

결과: 생성자 163개, 행 168개, 타입 16개. 실패 0.

| 갈래 | 행 |
| --- | --- |
| `Refused (Sized Input_too_large)` | 7 |
| `Refused (Sized Output_over_reserve)` | 2 |
| `Refused (Sized Window_reached)` | 3 |
| `Refused Unsized` | 6 |
| `Silent Not_called` | 3 |
| `Silent Unavailable` | 45 |
| `Silent Busy` | 11 |
| `Silent Lost` | 58 |
| `Silent (Unusable _)` | 18 |

확인하지 않은 것:

- 표는 타입에서 만들었다. 어느 생성자가 실제로 Exact 경로에 닿는지는 따라가지 않았다.
- `Incomplete_output` 과 `Empty_completion` 의 행은 Agent-Core 가 stop reason 을 실어 준 뒤의 것이다(RFC §7.2 의 넷째 변경). 지금 `Incomplete_output` 은 값을 싣지 않는다.
- Codex 가 tool 을 쓰지 않고 알린 창 넘침을 생성 전의 거절로 읽었다. 지금 코드의 읽기를 따른 것이고 따로 재지 않았다.

## 자리 재생 (`seat-replay/`)

운영 설치 하나의 기록을 읽어 만든 것이다. 기간은 2026-11-10 부터 2026-11-18 13:44 까지다. 재생은 그 가운데 168시간을 쓴다.

| 파일 | 내용 |
| --- | --- |
| `seats_extract.py` | 턴이 끝난 시각, 스트리밍 호출의 시간, 자리 대기 사건을 뽑는다. 글은 읽지 않는다 |
| `seats_measure.py`, `seats_measure.out` | 뽑은 것의 집계 |
| `seats_sim.py`, `seats_sim.out`, `seats_sim_fixed.out` | Keeper 턴을 그대로 재생하고 그 위에 Librarian 의 묻기를 얹는다 |
| `seats_sim_limit.py`, `seats_sim_limit.out` | run limit 을 둔 재생 |
| `seats_no_tinker.py`, `seats_no_tinker.out` | tinker 가 없는 lane 의 재생 |
| `seats_tables.md` | 위 출력을 표로 모은 것 |

- `seats_measure.out` 은 정제본이다. 원본의 runtime profile id 에는 계정 이름과 hash 가 들어 있어 client 와 모델 이름으로 줄였다. 계정 이름 하나는 `claude_account_1` 로 바꿨다. 수는 그대로다.
- `seats_extract.py` 가 쓰는 중간 파일 둘(약 45 MB, 4.5 MB)과 호출 시간 표본 둘(`slot_latency.json`, `wc_runs.json`)은 넣지 않았다. Keeper 마다의 기록이다. 그래서 이 폴더만으로는 재생을 다시 돌릴 수 없다. 다른 설치에서는 `seats_extract.py <base path>` 로 자기 기록을 뽑아 돌린다.
- 재생은 호출 시간을 질문 크기와 무관하게 뽑았다. Librarian 호출 시간의 표본은 slot 마다 크기가 다르다(GLM 185개, tinker 106개, ollama 7개).

## 컷이 지우는 모듈을 부르는 곳 (`cut-callers/`)

```
python3 list_callers.py <저장소 루트> > callers.tsv
```

- 지우는 모듈의 집합은 RFC §19.2 의 a~e 와 k 의 첫 행이다. `lib/keeper/keeper_librarian*.ml` 가운데 남는 여섯을 뺀 것, 스크립트에 이름으로 적은 것, 하는 일이 전부 옛 경로라 같이 지우는 단위다.
- 같이 지우는 단위는 손으로 적는다. 부르는 단위를 통째로 지울지는 그 단위를 읽어야 안다. 하나를 더 적으면 다시 돌린다. 그 단위를 부르는 곳이 다음 출력에 나온다.
- 출력은 그 집합 밖의 단위마다 한 줄이다. 단위, 부르는 지우는 모듈의 수, 그 이름이다.
- 찾는 방법은 `lib/` 와 `bin/` 의 `.ml`, `.mli` 에서 모듈 이름을 단어 경계로 찾는 것이다. `open` 이나 `include` 뒤에 가려진 호출은 못 찾는다. 주석 안의 이름은 찾는다.
- 지우지 않는 facade 를 거쳐 부르는 곳은 이 목록에 없다. facade 를 추린 뒤에 다시 만든다.
- 컷 층은 단위를 고칠 때마다 다시 만든다. 이 목록은 하한이다. dune 파일, 함수만 지우는 곳, 생성자 이름으로만 닿는 곳은 잡지 못한다(RFC §19.2 k). 컷이 끝났다는 기준은 지운 이름이 `lib/`, `bin/`, `test/` 와 dune 파일에 없고 타입 검사가 통과하는 것이다.
