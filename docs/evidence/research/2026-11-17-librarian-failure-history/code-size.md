# 코드와 시험의 크기

- 조건: main `fa5aead0d999` 의 `git ls-tree` 와 `git cat-file` 로 센 줄 수다.
- 시험은 `test/` 아래에서 경로에 `librarian` 이나 `lane_addon` 이 든 파일이다. 127개이고 `.ml` 이 86개다.
- `test_case` 는 그 글자가 든 줄을 센 값이다. 실제 사례 수와 조금 다르다.
- 만든 명령: README 의 「코드 크기」.

## 코드

| part | modules (.ml) | .ml lines | .mli lines | total |
|---|---:|---:|---:|---:|
| `lib/keeper/keeper_librarian_*` | 69 (every .ml has an .mli) | 23,873 | 6,439 | 30,312 |
| `lib/lane_addon/*` | 53 (every .ml has an .mli) | 18,670 | 4,963 | 23,633 |
| `addons/keeper-librarian/**` (5 files: server.py 81, lane.toml 38, Dockerfile 4, 2 one-line JSON schemas) | – | – | – | 125 |
| `addons/exact_worker.py` | – | – | – | 620 |
| **total** | **122 OCaml modules** | 42,543 | 11,402 | **54,690** |

## 시험

| test group | .ml files | lines | `test_case` lines (≈ Alcotest cases) |
|---|---:|---:|---:|
| name contains librarian | 42 | 40,501 | 944 (in 38 files) |
| name contains lane_addon | 44 | 30,844 | 839 (in 43 files) |
| **all** | **86** | **71,345** | **1,783** (in 81 files; the other 5 are fixture, bench, helper, or use their own `check`) |
