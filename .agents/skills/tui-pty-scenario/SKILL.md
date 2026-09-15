---
name: tui-pty-scenario
description: "masc TUI 를 진짜 터미널(PTY)에 띄워 확인하는 파이썬 시나리오를 돌리고, 고르고, 실패를 읽고, 새로 만든다. test/test_tui_keyboard_input.py 의 가족·시나리오 선택(--list, --scenario), 'timed out waiting for' 실패 읽기, dune PTY alias 종료 코드, CI 시간 초과, macOS 와 Linux 결과 차이를 다룬다. 화면 문구·기호·폭을 바꾼 뒤나 PTY 스위트가 빨갈 때 쓴다."
---

# TUI PTY 시나리오

`test/test_tui_keyboard_input.py` 가 하네스다. `run_terminal_scenario` 가 PTY 를 열고, 가짜 HTTP
서버를 붙이고, TUI 를 띄우고, 키를 보내고, 화면 바이트를 기다린다. 다른 `test/test_tui_*.py` 초점
스위트들도 이 모듈을 `import test_tui_keyboard_input as h` 로 가져다 쓴다.

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
- 같은 설명이 한 가족에 두 번 있으면 둘 다 돈다. 끝줄 `PASS (N selected scenario runs)` 의 N 으로 확인한다.
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

### PR CI

`scripts/ci/run-edited-tests.sh` 가 PR 이 바꾼 파일로 스위트를 고른다.

- 편집한 `test/test_*.py` 중 `test/dune` 에 `runtest-<stem>` 규칙이 있는 것은
  `dune build @test/runtest-<stem>` 으로 돈다. 로그에 `== test/<stem> (dune rule)` 이 찍힌다.
- 소스 경로를 문자열로 적어 둔 스위트는 그 소스가 바뀐 PR 에서도 돈다(아래 `SOURCE_MODULES`).
- 기본 키보드 산책은 지금 그 파일을 고친 PR 에서만 돈다. 렌더 파일만 고친 PR 의 초록은 산책의 증거가
  아니다. 그런 PR 은 바뀐 문구가 `test/*.py` 에 needle 로 남아 있는지 직접 찾는다.
- 스위트 하나의 상한은 300초이고 키보드 산책만 600초다. `timeout` 이 끊으면 출력이 남지 않는다.
  로그의 `== test/<stem>` 줄과 `ran N, skipped M` 줄의 시각 차가 상한과 같고 PASS 도
  `AssertionError` 도 없으면 시간 초과다.

### 가족 하나를 Linux 에서

```sh
gh workflow run test.yml --ref <branch> -f suite=test_tui_keyboard_input-<family>
gh workflow run test.yml --ref <branch> -f suite=test_tui_keyboard_input   # 기본 산책
```

`suite` 는 `test/<이름>.py` 파일 이름이나 `test/dune` 에 선언된 `runtest-<이름>` alias 이름을 받는다.
시나리오 하나만 고르는 입력은 없다.

## 5. 새 시나리오 만들기

기본 산책에 시나리오를 더 넣지 않는다. 산책은 이미 CI 상한 가까이 걸린다(이슈 #36343).
초점 스위트 파일을 따로 만든다. `test/test_tui_tab_strip_pty.py` 가 예다.

1. `test/test_tui_<무엇을 확인하나>.py` 를 만들고 `import test_tui_keyboard_input as h` 로 하네스를 쓴다.
2. 파일 위쪽에 이 시나리오가 지키는 소스를 적는다. PR CI 는 바뀐 경로를 따옴표째 적은 스위트를 고른다.

   ```python
   SOURCE_MODULES = (
       "bin/masc_tui_render.ml",
   )
   ```

3. `h.run_terminal_scenario(executable, description=..., interact=..., http_fixtures=...)` 를 부른다.
   끝에 `print("<무엇>: PASS")` 를 찍는다.
4. `test/dune` 에 규칙과 `runtest` 연결을 둘 다 넣는다. 연결이 없으면 전체 테스트에서 안 돈다.

   ```text
   (rule
    (alias runtest-test_tui_<stem>)
    (deps test_tui_<stem>.py test_tui_keyboard_input.py ../bin/masc_tui.exe)
    (action
     (run python3 %{dep:test_tui_<stem>.py} %{dep:../bin/masc_tui.exe})))

   (alias
    (name runtest)
    (deps (alias runtest-test_tui_<stem>)))
   ```

## Gotchas

- 설명이 같은 시나리오가 다른 가족에도 있다. `--scenario` 는 고른 가족 안에서만 찾는다.
- `chat-atomic` 과 `browser-scene` 가족은 `test/dune` 규칙이 없다. 손으로만 돈다.
- 가족 몇 개(`msx-retained-tick`, `tools-purpose` 등)는 PASS 줄 앞에 증거 JSON 줄을 찍는다.
  `--list` 는 그런 출력을 stderr 로 돌려서 stdout 에는 이름만 남긴다.
