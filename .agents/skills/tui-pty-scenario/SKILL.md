---
name: tui-pty-scenario
description: "masc TUI 를 진짜 터미널(PTY)에 띄워 확인하는 파이썬 시나리오를 돌리고, 고르고, 실패를 읽고, 새로 만든다. test/test_tui_keyboard_input.py 의 가족·시나리오 선택(--list, --scenario), 'timed out waiting for' 실패 읽기, dune PTY alias 종료 코드, CI 시간 초과, macOS 와 Linux 결과 차이를 다룬다. 화면 문구·기호·폭을 바꾼 뒤나 PTY 스위트가 빨갈 때 쓴다."
---

# TUI PTY 시나리오

`test/test_tui_keyboard_input.py` 는 가족 선택 CLI 진입점이다. 공통 하네스는
`test/tui_keyboard_harness.py` 이며, `run_terminal_scenario` 가 PTY 를 열고 가짜 HTTP
서버를 붙여 TUI 와 상호작용한다. 새 초점 스위트는 `import tui_keyboard_harness as h` 로
공통 기능을 가져오고, 화면별 fixture 는 `tui_keyboard_chat`, `tui_keyboard_board` 등 실제 소유 모듈에서 가져온다.
기존 진입점의 호환 export 는 새 테스트의 기본 import 로 사용하지 않는다.

## 바이너리

시나리오는 빌드된 `masc_tui.exe` 경로를 받는다.

- dune alias 로 돌리면 dune 이 바이너리를 먼저 빌드한다.
- 직접 돌리면 `_build/default/bin/masc_tui.exe` 가 있어야 한다. 이 저장소의 worktree 는
  `<repo>/.worktrees/<branch>` 에 있어서, `--root .` 없이 dune 을 부르면 위쪽 main 체크아웃을
  루트로 잡는다. 로그 첫 줄에 `Entering directory` 가 나오면 잘못 잡힌 것이다.
- 경로가 실행 파일이 아니면 첫 시나리오에서 바로 `no executable TUI at <절대 경로>` 로 끝난다.
- 로컬 빌드를 하지 않는 작업이면 4절의 CI 실행을 쓴다.

## 1. 돌리기

### dune alias

```sh
dune build --root . @test/runtest-test_tui_keyboard_input            # 기본 산책
dune build --root . @test/runtest-test_tui_keyboard_input-<family>   # 가족 하나
```

`test/dune` 의 규칙이 `python3 test_tui_keyboard_input.py <exe> [family]` 를 부른다.
alias 는 통과하면 exit 0, 실패하면 exit 1, 없는 이름이면 `Alias ... is empty` 로 exit 1 이다.

### 스크립트 직접

```sh
EXE=_build/default/bin/masc_tui.exe
python3 test/test_tui_keyboard_input.py "$EXE" --list                      # 모든 가족과 시나리오 설명
python3 test/test_tui_keyboard_input.py "$EXE" <family> --list             # 한 가족만
python3 test/test_tui_keyboard_input.py "$EXE" --scenario "<설명>"           # 기본 산책에서 하나
python3 test/test_tui_keyboard_input.py "$EXE" <family> --scenario "<설명>" --scenario "<설명>"
```

- 가족은 dune lane 이름이다. 가족을 안 주면 기본 산책(`keyboard`)이다.
- `--scenario` 는 `run_terminal_scenario(description=...)` 의 설명과 정확히 같아야 한다.
  실패 트레이스백에 찍힌 호출 줄에서 설명을 복사한다.
- 모르는 설명을 주면 터미널을 열기 전에 exit 2 로 끝나고, 그 설명이 있는 가족을 알려 준다.
- 한 가족 안에서 설명은 하나씩이다. 같은 설명을 두 번 쓰면 `--list` 와 `--scenario` 가 이름을 모으다 실패한다.
  끝줄 `PASS (N selected scenario runs)` 의 N 이 실제로 돈 개수다.
- `--list` 도 바이너리 경로를 받는다. 두 가족이 증거용으로 바이너리를 해시하기 때문이다.

한 가족은 첫 실패에서 멈춘다. 그 뒤 시나리오는 검증되지 않은 상태로 남는다. 앞쪽이 main 에서 이미
깨져 있으면 내가 고친 시나리오는 한 번도 안 돈다. 그럴 때 `--scenario` 로 그것만 돌린다.

## 2. 실패 읽기

```
AssertionError: timed out waiting for b'MASC Overview': b'...'
```

- **콜론 뒤의 바이트열이 원인이다.** 앞은 "무엇을 기다렸나" 이고, 뒤는 그때까지 터미널에 찍힌 전부다.
  SGR 이스케이프(`\x1b[...m`)를 걷어 내고 읽으면 실제 화면이 보인다.
  기다린 문구의 철자를 추측해서 고치지 말고, 이 화면에서 지금 무엇이 그려졌는지 보고 고친다.
- `TUI exited before <needle>: ...` 는 TUI 가 끝났다는 뜻이다. 뒤 바이트열에 TUI 의 오류 출력이 있다.
- `<설명> did not restore the original terminal mode` 는 종료할 때 termios 를 되돌리지 않았다는 뜻이다.
- **키를 눌렀는데 반응이 없을 때:** 키가 사라진 것인지, 그 순간 상태가 준비되지 않은 것인지 가른다.
  같은 키를 한 번 더 눌러서 두 번째에 반응하면 키 문제가 아니라 상태 문제다.
  시나리오의 준비 신호는 동작이 읽는 데이터가 그린 글자로 고른다. 머리글·제목·탭 이름은 데이터가
  오기 전에도 그려지니 준비 신호가 못 된다.
- 1KB 넘는 입력은 `h.write_all` 로 보낸다. PTY 입력 큐가 작아서 `os.write` 한 번은 짧게 쓰고 나머지를 버린다.

## 3. 로컬 결과를 믿어도 되는 범위

- 백그라운드로 감싼 명령(`( dune build ... ) > f 2>&1; echo EXIT=$?`)의 알림 종료 코드는 바깥
  셸의 것이다. 판정은 출력 파일 안의 `EXIT=` 줄이나 `PASS` 줄로 한다.
- 파이프를 붙이면 `$?` 는 마지막 명령(`tail` 등)의 것이다.
- PTY 스위트는 alcotest 요약을 안 찍는다. 통과 신호는 `tui ...: PASS` 한 줄뿐이다. 출력이 그 줄도
  없이 짧으면 dune 이 캐시로 건너뛴 것일 수 있다. `--force` 로 다시 돌린다.
- **macOS 에서 PASS 여도 Linux 에서 빨갈 수 있다.** 폭·잘림·두 칸 배치가 걸린 시나리오에서 실제로 있었다.
  렌더 폭을 바꿨으면 4절로 Linux 에서 해당 가족을 돌린다.
- 스윕이 도는 동안 그 체크아웃에서 브랜치를 바꾸거나 다시 빌드하지 않는다. 하네스는 트리의 `.py`
  를, TUI 는 빌드된 바이너리를 읽는다. 새 테스트와 옛 바이너리가 섞이면 없는 회귀가 보인다.

## 4. CI 에서 돌리기

### PR 검증

PR·일반 branch push로 자동 CI를 실행하지 않는다. 변경한 입력·렌더링 경계와 직접
소비자를 확인하고, 필요한 경우 해당 가족의 검증을 명시적으로 요청한다.
`SOURCE_MODULES` 기반 선택기는 제거됐으므로 경로 문자열 선언으로 실행을 보장하지 않는다.
Full CI는 최종 Release/Tag 후보에서 실행하며, 세부 절차는 `docs/constitution.xml`의
`execution_protocol`과 `docs/CI-REVIEW-WORKFLOW.md`를 따른다.

### 가족 하나를 Linux 에서

```sh
gh workflow run test.yml --ref <branch> -f suite=test_tui_keyboard_input-<family>
gh workflow run test.yml --ref <branch> -f suite=test_tui_keyboard_input   # 기본 산책
```

`suite` 는 `test/<이름>.py` 파일 이름이나 `test/dune` 에 선언된 `runtest-<이름>` alias 이름을 받는다.
시나리오 하나만 고르는 입력은 없다.

## 5. 새 시나리오 만들기

기본 산책에 시나리오를 더 넣지 않는다.
초점 스위트 파일을 따로 만든다. `test/test_tui_tab_strip_pty.py` 가 예다.

1. `test/test_tui_<무엇을 확인하나>.py` 를 만들고 `import tui_keyboard_harness as h` 로 하네스를 쓴다.
   필요한 fixture 는 그 정의가 있는 소유 모듈에서 명시적으로 import 한다.
2. 시나리오 docstring에 검증하는 사용자 동작과 입력·출력 경계를 적는다.
   실행 여부를 보장하지 않는 `SOURCE_MODULES` 선언은 추가하지 않는다.
3. `h.run_terminal_scenario(executable, description=..., interact=..., http_fixtures=...)` 를 부른다.
   끝에 `print("<무엇>: PASS")` 를 찍는다.
4. `test/dune` 에 규칙과 `runtest` 연결을 둘 다 넣는다. 연결이 없으면 전체 테스트에서 안 돈다.

   ```text
   (rule
    (alias runtest-test_tui_<stem>)
    (deps test_tui_<stem>.py tui_keyboard_harness.py ../bin/masc_tui.exe)
    (action
     (run python3 %{dep:test_tui_<stem>.py} %{dep:../bin/masc_tui.exe})))

   (alias
    (name runtest)
    (deps (alias runtest-test_tui_<stem>)))
   ```

위 규칙은 공통 하네스만 사용하는 최소 예다. 화면별 소유 모듈을 import 하면 그 파일과
그 모듈이 다시 import 하는 모든 `tui_keyboard_*.py` 파일도 `deps` 에 넣는다.
기존 CLI 진입점을 import 하는 소비자는 전체 진입점 import closure 를 선언해야 한다.
소스 트리에서 import 가 성공해도 Dune sandbox 의 의존성이 충분하다는 증거는 아니다.

## Gotchas

- 설명이 같은 시나리오가 다른 가족에도 있다. `--scenario` 는 고른 가족 안에서만 찾는다.
- 가족을 새로 만들면 `test/dune` 규칙과 `runtest` 연결을 같이 넣는다. 빠지면
  `test/test_tui_keyboard_scenario_selection.py` 가 실패한다. `memory-journal` 만 규칙은 있고
  `runtest` 연결은 일부러 뺐다(Linux 러너에서 멈춘다, `test/dune` 주석). 그 예외는 그 테스트에 적혀 있다.
- 가족 몇 개(`msx-retained-tick`, `tools-purpose` 등)는 PASS 줄 앞에 증거 JSON 줄을 찍는다.
  `--list` 는 그런 출력을 stderr 로 돌려서 stdout 에는 이름만 남긴다.
