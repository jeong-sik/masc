# task-3491 / task-3497 — lib/tui_terminal_text.ml 경계 시험 증거

`test/test_tui_terminal_text.ml` 을 붙이면서 만든 증거입니다. PR #50748 로 main 에 들어갔습니다.

## 저장하지 않는 것

이 디렉터리에는 **컴파일 산출물을 두지 않습니다.**

- `probe.exe` (7,672,840 바이트, ELF) — 컴파일된 시험 실행파일. 이 커밋은 `git add -f` 로 `_build/` 까지 함께 넣어, 저장소에서 유일하게 `.exe` 를 품은 디렉터리가 됐습니다. 바이너리는 지웠습니다. **바이트는 git 이력에서 꺼낼 수 있습니다** — base `24d54a4a`, blob `fb99f6bb985a05a0e24ca17939542118a02411cf`, sha256 `4facd482…`. `SHA256SUMS` 하단 주석에 그 좌표와 함께 **그 해시가 무엇을 증명하고 무엇을 증명하지 않는지** 적었습니다.
- `_build/**` — alcotest 가 만든 출력. `.gitignore:2` 가 `_build/` 를 무시하는데 `git add -f` 가 이를 우회했습니다. 재생성 가능하므로 제거했습니다. 개별 assertion 출력 9건은 base `24d54a4a` 에 남아 있습니다.
- `mut/` 안의 중복 사본(`string_util.ml`, `time_codec.ml`, `time_codec.mli`, `tui_terminal_text.mli`, `test_tui_terminal_text.ml`, `masc.ml`, `mutant.log`) — 단독 컴파일용 사본이며 이 디렉터리 루트에 같은 Git blob 이 있습니다.

## 보존하는 것과 그 이유

| 파일 | 무엇을 기록하나 |
|---|---|
| `run.log` | 원본 시험 7/7 통과 (`Test Successful in 0.000s. 7 tests run.`) |
| `mutant.log` | CR 제거 변이에서 `preservation 2` **하나만** FAIL — 계약 3항이 실패 가능한 단언으로 고정됨 |
| `mut/tui_terminal_text.ml` | 그 CR 제거 변이 본문 (원본 대비 +2줄) |
| `drop.log` | 문자열 통째 폐기 변이에서 **6/7 FAIL** — changelog 조각의 "fails six of these seven" 근거 |
| `dropmut/tui_terminal_text.ml` | 그 폐기 변이 본문 |
| `ci-dune-target.log` | 저장소 dune 표적을 CI 러너에서 실행한 영수증 (Keeper 레인은 빌드 불가) |
| `dune-attempt.log` | Keeper 레인이 dune 을 돌릴 수 없음을 보인 시도 기록 |
| `SHA256SUMS` | **이 디렉터리에 실제로 있는 파일**의 manifest. `sha256sum -c SHA256SUMS` 가 통과합니다 |
| `SHA256SUMS.src` | 소스 스냅샷 manifest |
| `tui_terminal_text.ml`, `test_tui_terminal_text.ml`, `masc.ml`, `string_util.ml`, `time_codec.ml`, `time_codec.mli`, `tui_terminal_text.mli` | 변이 전후를 읽기 위한 소스 스냅샷 (`time_codec.ml`·`time_codec.mli` 는 변이 대조용 사본이 아니라 이 디렉터리의 단독 컴파일 입력입니다) |
| `run.cmd.txt` | `probe.exe` 를 다시 빌드하는 명령 |

## 변이 대조

```
$ diff tui_terminal_text.ml mut/tui_terminal_text.ml
379a380,381
>   (* MUTANT: strip CR instead of escaping it *)
>   let text = String.concat "" (String.split_on_char '\r' text) in
```

`dropmut/` 는 `sanitize_terminal_text` 첫 줄에 `if Sys.getenv_opt "DROP_ALL" <> None then "" else` 를 넣은 변이입니다.

## 실행 주체 구분

- `probe.exe` / 변이 실행은 **Keeper 레인(rondo)** 에서 `ocamlfind` + `ocamlopt` 로 했습니다.
- `ci-dune-target.log` 의 run 은 **GitHub Actions 러너**가 실행한 것이며 Keeper 레인이 아닙니다. 레인에는 `jose`·`qrc` 가 없고 `h2 0.12` 요구가 맞지 않아 dune 빌드가 불가합니다(`dune-attempt.log`).

## 이 로그들의 한계 — 읽는 사람이 알아야 할 것

`run.log`·`mutant.log`·`drop.log` 는 **당시 실행의 출력**입니다. 그 안에는 컴파일 명령, `./probe.exe`, 시험 결과가 적혀 있지만 **실행된 실행파일의 해시는 적혀 있지 않습니다.**

따라서:

- 남아 있는 변이 소스가 그 로그를 만들었다고 이 디렉터리만으로 증명할 수 없습니다. 소스와 로그가 **일치한다**는 것까지가 여기서 말할 수 있는 것입니다.
- `probe.exe` 해시는 "그 바이트가 git 이력에 실재한다"는 것만 증명합니다. "그 바이트가 이 로그를 만들었다"는 증명이 아닙니다.
- 재빌드(`run.cmd.txt`)가 같은 바이트를 낸다는 것도 확인된 바 없습니다.

이 한계를 없애려면 실행 시점에 바이너리 해시를 로그에 함께 남겨야 합니다. 이 증거에는 그렇게 하지 않았습니다.
