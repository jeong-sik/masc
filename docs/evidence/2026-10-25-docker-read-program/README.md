# Docker 조회 명령의 실행 주체 보존

이미지 기본 entrypoint가 조회할 실행 파일을 바꾸면, 실제 검색이 시작되지 않았는데도 결과 없음으로 기록될 수 있다. 기존 GLM/Docker 실행에서 `rg` 부재가 Node module 오류와 exit1로 끝났고 Task reviewer의 조회는 성공으로 표시됐다. [원래 실행](../2026-10-25-goal-playground-bootstrap/keeper-chain/actual-keeper-goal-proof-chain.json)의 실패를 유지한다.

## 제품 변경

`Keeper_sandbox_read_backend`의 Docker fallback은 `command_argv` 첫 값이 실행 파일이라는 기존 계약을 가진다. image 앞에서 기본 entrypoint를 비워 이 계약을 지킨다. 오류 문자열 판별이나 조회 횟수·시간·비용 게이트를 추가하지 않는다. 다른 guest/endpoint/turn-runtime 분기는 바꾸지 않는다.

제품 변경은 `84003fe04f9ac67a4b4b8f5fe851a3ad2c1924d8`에서 동결했고 fixture 호출을 교정한 현재 검증 소스는 `cdeb9e5af15677c22fc4be8b0cc0f82d42e5b351`이다. 직접 parent는 PR #45916의 `45592d21f7f1c11226e75c857d1983f7b0eef9d5`다. [.mli 계약](../../../lib/keeper/keeper_sandbox_read_backend.mli)과 [Docker 공식 문서](https://docs.docker.com/engine/containers/run/#default-entrypoint)를 함께 따른다.

## 실제 Docker 대조

같은 기존 이미지 ID `de170b39439eb0e5a3444ad7d60b015614a381e10fecae2e30ec9e735122f38d`와 같은 7B 입력 파일을 사용했다. 이 이미지의 Entrypoint는 `docker-entrypoint.sh`, Cmd는 `node`다. entrypoint 자체가 node라고 부르지 않는다.

| 호출 | 이미지 기본 entrypoint | caller program 직접 실행 |
|---|---:|---:|
| 없는 rg | 1 | 127 |
| 실제 grep 결과 없음 | 1 | 1 |
| 실제 grep 결과 있음 | 0 | 0 |
| 실제 cat 파일 읽기 | 0 | 0 |

총 8개 직접 Docker CLI 호출이다. 검색 성공·결과 없음·파일 읽기의 출력 바이트는 각각 전후 같았고 입력 해시도 유지됐다. 모든 호출에 non-root, network none, read-only rootfs/input, cap-drop ALL, no-new-privileges와 pull never를 지정했다. 이미지 pull/build나 전역 Docker 변경은 하지 않았다.

이 대조는 Docker CLI 실행 의미의 실측이다. 새 MASC 실행 파일이나 새 provider/model 실행의 성공으로 확장하지 않는다. 정상 no-match 대조는 실제 `grep`이며 실제 `rg` no-match라고 바꾸어 쓰지 않는다.

## 선택 native 소비자

`test_keeper_sandbox_read_backend`만 명시적으로 요청했다. 두 새 fixture는 실제 `Keeper_workspace_read_ops` handler와 Docker fallback을 통과하지만 Docker engine은 fixture다. 하나는 이미지 entrypoint가 누락된 프로그램을 감추지 못해 `Runtime_failure`가 되는지, 다른 하나는 정상 exit1이 `Completed`와 빈 matches로 유지되는지 검사한다. 기존 suite는 bare argv, Read, 허용된 종료 코드와 다른 sandbox route도 확인한다.

첫 native 실행 [40189920561](https://github.com/jeong-sik/masc/actions/runs/40189920561)은 새 fixture의 잘못된 `~meta` 라벨로 컴파일에서 실패해 테스트가 실행되지 않았다. 실제 API의 positional 인자로 1줄 고쳤고, 같은 suite만 새 source cdeb로 다시 요청했다. 수리 후 [40190669931](https://github.com/jeong-sik/masc/actions/runs/40190669931)은 source cdeb의 같은 suite에서 79개 case가 모두 성공했다. 새 두 handler case도 포함된다. `native-result-cdeb.json`과 `native-failure-84003.json`에 성공·실패 및 원본 로그 해시를 각각 보존한다. 로컬에서는 변경한 3개 OCaml 파일의 parse만 수행했고 Dune은 실행하지 않았다. 전체 회귀는 미실행이며 이전 전체 회귀 run/head/TARGET_SUITES는 확인하지 못했다.

## 한계

- 원래 CLI 드라이버의 inspect 비0만으로 삭제 완료를 입증할 수 없다. 후속 exact-ID 조회의 관측 시각과 범위는 별도 cleanup 증거로 구분한다.
- 시간순 Task 계약의 선행 승인 원장 가시성, 외부 acceptance 측정, whole-stack 승인·병합·운영 반영은 별도 남은 작업이다.
- microVM·SSH grading 및 새 candidate의 실제 guest/provider 검증을 수행하지 않았다.
- 원래 Goal의 성공조건·측정·acceptance를 바꾸거나 사람 확인을 수행하지 않았다.

공개 파일은 허용한 식별자·해시·사실만 포함한다. 원문 stderr/stdout과 사설 경로는 별도 원본에 보존하며 인증값은 수집하지 않는다. 원본 실측, native fixture, source review, 설치와 사람 확인은 서로 다른 증거다.
