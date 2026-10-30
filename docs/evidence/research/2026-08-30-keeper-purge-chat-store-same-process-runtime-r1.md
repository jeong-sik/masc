# Keeper purge same-process chat store runtime R1

## 결과

dashboard purge가 Keeper runtime directory와 `chat-operations.sqlite3`을
삭제해도 process-local Keeper Owner actor는 의도적으로 남는다. 기존 구현은
같은 이름의 `Create`에서 actor를 재사용하면서 삭제된 SQLite inode handle도
재사용했다. 그 결과 `keeper_up`은 성공하지만 첫 message submit이
`rc=READONLY`로 실패했다.

Owner의 `Create` command는 actor mailbox에서 직렬 실행된다. 이 경계에서 기존
operation store path가 absent이면 parent directory를 복구하고 store를 새로 열어
inventory projection과 handle을 교체하도록 했다. 일반 최초 생성은 이미 만든
path가 있으므로 기존 경로를 그대로 사용한다.

## exact identity

- source change commit: `39625bdd9dbab077016f40571a1f6b2e02619ef1`
- Linux measurement composition/embedded commit:
  `1be736a1d173947a8e206abbffc40693c0b3edee`
- Linux/arm64 image digest:
  `sha256:4965a61f5452afb650f9c3caee03a005d4fb04d295f59de12a71e04bbd9b9349`
- binary SHA-256:
  `fe5f57baa87947d8433f319e4cc3ffd649c30e1f661758c7ddafd64a13668a4f`
- runtime instance:
  `01a05153-4d0b-7000-a2b5-373ef7b78a95`
- model: host Ollama `qwen3:8b`
- Keeper name length: 128

Git remote context와 `BUILDKIT_CONTEXT_KEEP_GIT_DIR=1`로 이미지를 만들었다.
container `build-commit`, `/health` embedded commit, binary hash가 같은 source
head를 가리켰다.

## 실측

128자 Keeper를 생성한 뒤 `masc_keeper_down`으로 lane을 정상 정지했다. 첫 purge
시도는 running lane 때문에 HTTP 409로 fail-closed됐고 상태를 바꾸지 않았다.
정지 operation은 `shutdown-1dc9c657-4310-4abc-bb7b-671788b5db4d`였다.

같은 server process에서 dashboard purge는 HTTP 202와 operation
`shutdown-bd1d730a-4211-4abb-917b-b164ecbe89d9`을 반환했다. core artifact와
playground present count는 0이 됐다. 서버를 재시작하지 않고 같은 이름을 다시
만들자 새 `chat-operations.sqlite3`가 28672 bytes로 생성됐다.

첫 `masc_keeper_msg`는 operation
`kmsg-cba76dd77e7fdd8ecefcfecc61386b9c`을 반환했고 `Succeeded`로 끝났다.
Qwen 응답은 `SAME_PROCESS_OK`, dynamic context는 0 bytes, latency는 40786ms였다.
purge 전후와 재생성 뒤 `/health` runtime instance id는 모두 같았고,
READONLY/readonly database/store_unavailable log match는 0이었다.

## 검증

- `scripts/dune-local.sh build test/test_keeper_owner.exe`
- owner actor focused tests 2/2:
  - normal root inventory creation
  - open SQLite directory 삭제→same actor `Delete → Create → submit/read`
- exact Linux/arm64 same-process runtime chain

## 남은 경계

one-click container의 sandbox CLI 부재 warning은 #31927 범위로 남는다. 이
수정은 operation store handle 수명만 다룬다. 성능 향상은 주장하지 않는다.

## 근거

- [근거] Git remote-context build log, container `/health`, `build-commit`,
  `sha256sum`, down/purge/up responses, SQLite stat, Qwen chat/metrics, server log,
  2026-08-30T15:23:36+09:00 확인, 신뢰도 High.
