# task-3491 / task-3497 — lib/tui_terminal_text.ml 경계 시험 증거

`test/test_tui_terminal_text.ml` 을 붙이면서 만든 증거입니다. PR #50748 로 main 에 들어갔습니다.

## 저장하지 않는 것

이 디렉터리에는 **컴파일 산출물을 두지 않습니다.**

- `probe.exe` (7.3 MiB) — 컴파일된 시험 실행파일. 이 커밋은 `git add -f` 로 `_build/` 까지 함께 넣어, 저장소에서 유일하게 `.exe` 를 품은 디렉터리가 됐습니다. 바이너리는 지우고 **해시만 `SHA256SUMS` 에 남겼습니다**(`probe.exe` 줄에 `not stored; identity only` 표기). 재생성 명령은 `run.cmd.txt`.
- `_build/**` — alcotest 가 만든 출력. `.gitignore:2` 가 `_build/` 를 무시하는데 `git add -f` 가 이를 우회했습니다. 재생성 가능하므로 제거했습니다.
- `mut/` 안의 중복 사본(`string_util.ml`, `time_codec.ml`, `time_codec.mli`, `tui_terminal_text.mli`, `test_tui_terminal_text.ml`, `masc.ml`, `mutant.log`) — 단독 컴파일용 사본이며 이 디렉터리 루트에 같은 파일이 있습니다.

## 보존하는 것과 그 이유

| 파일 | 무엇을 증명하나 |
|---|---|
| `run.log` | 원본 시험 7/7 통과 (`Test Successful in 0.000s. 7 tests run.`) |
| `mutant.log` | CR 제거 변이에서 `preservation 2` **하나만** FAIL — 계약 3항이 실패 가능한 단언으로 고정됨 |
| `mut/tui_terminal_text.ml` | 그 CR 제거 변이 본문 (원본 대비 +2줄) |
| `drop.log` | 문자열 통째 폐기 변이에서 **6/7 FAIL** — changelog 조각의 "fails six of these seven" 근거 |
| `dropmut/tui_terminal_text.ml` | 그 폐기 변이 본문 |
| `ci-dune-target.log` | 저장소 dune 표적을 CI 러너에서 실행한 영수증 (Keeper 레인은 빌드 불가) |
| `dune-attempt.log` | Keeper 레인이 dune 을 돌릴 수 없음을 보인 시도 기록 |
| `SHA256SUMS` / `SHA256SUMS.src` | 위 소스·바이너리의 신원 |
| `tui_terminal_text.ml`, `test_tui_terminal_text.ml`, `masc.ml`, `string_util.ml`, `time_codec.ml`, `time_codec.mli`, `tui_terminal_text.mli` | 변이 전후를 읽기 위한 소스 스냅샷 |
| `run.cmd.txt` | `probe.exe` 재생성 명령 |

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
