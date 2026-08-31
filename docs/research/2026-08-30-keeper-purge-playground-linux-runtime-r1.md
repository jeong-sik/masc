# Keeper purge playground Linux runtime R1

## 결과

128자 Keeper의 source snapshot, TOML, runtime directory, meta를 지우는 것만으로는
fresh context가 아니었다. baseline Linux/arm64 image에서 dashboard purge는 HTTP
202를 반환했지만 Local playground를 남겼고, 서버 재시작 뒤 같은 이름의 Qwen
Keeper가 그 파일을 읽어 `RECREATE_CONTENT:mode=current-linux-r1`을 답했다.

dashboard purge artifact plan에 `Keeper_playground_bundles_artifact`를 추가했다.
현재 profile 하나를 다시 추정하지 않고 같은 이름의 Local, Docker, microVM,
remote-SSH bookkeeping root를 전부 typed path로 계산해 제거한다. profile 변경 뒤
다른 backend root의 과거 파일을 다시 읽는 경우도 같은 경계에서 막는다.

## exact identity

baseline:

- source/embedded commit: `d667ddb4a4aed8c1e3d1c383d10de91b089f756e`
- Linux/arm64 image digest:
  `sha256:151e4a32ca648cc3f18b967853257939a4d61a12ccc9bfc15a0be71e4d61f9b4`
- binary SHA-256:
  `624ef4ae20875902f347f0f60aa2dd8f25a60c24934566d371d11e10ff5443c6`

fixed composition:

- source/embedded commit: `f57c1f14b8825f5a6622ef0fdc0e744a4f794488`
- Linux/arm64 image digest:
  `sha256:2999ca517f3b234195392f5b0716666d9ff2fffdca965155cef75c7317b8838e`
- binary SHA-256:
  `3af3197406c210a3268c57448aa8e2b2c3017e3de56dad746508bb9c1a5422d0`
- model: host Ollama `qwen3:8b`
- Keeper name length: 128

두 이미지는 Git remote context에서 `BUILDKIT_CONTEXT_KEEP_GIT_DIR=1`로 만들었고,
컨테이너의 `build-commit`, `/health` embedded commit, binary hash가 각 source
head와 일치했다.

## baseline 실측

source digest와 다른 실제 파일을 둔 turn은 `Succeeded`했고 stale fact를 revision
2에서 제거해 `source_changed` invalidation 1개를 남겼다. last-prompt의 stale
claim match는 0, dynamic context는 0 bytes, 응답은 `LINUX_SOURCE_REFRESH_OK`였다.

서버 재시작 뒤 purge는 HTTP 202와 operation
`shutdown-fe1954a1-74b8-474b-b34d-837732918340`을 반환했다. source snapshot,
TOML, runtime directory, meta는 absent였지만 playground file은 present였다.
다시 재시작하고 같은 이름을 만들자 fresh turn은 파일을 읽고
`RECREATE_CONTENT:mode=current-linux-r1`을 답했다. Memory OS가 비어 있어도
workspace가 false context를 공급한 실제 반례다.

purge 직후 같은 프로세스에서 재생성한 첫 메시지는 삭제된
`chat-operations.sqlite3` handle 때문에 `READONLY`로 실패했다. 이는 #31926으로
분리했고, 이 보고서의 재생성 판정은 서버 재시작 뒤 수행했다.

## 수정 후 실측

새 Linux named volume에서 source snapshot, TOML, runtime directory, meta,
Local playground file을 만든 뒤 서버를 재시작했다. purge는 HTTP 202와 operation
`shutdown-3576e211-da4b-4ef4-9f03-c33a6056424a`을 반환했다. 위 네 artifact와
Local/Docker/microVM playground root는 모두 absent였다.

다시 서버를 재시작하고 같은 이름의 fresh Keeper를 만들었다. 첫 Qwen request는
missing-file error 뒤 empty completion과 fallback capability rejection으로 Failed였다.
empty workspace를 명시한 두 번째 request는 harness의 120초 관찰 상한을 넘겼지만
서버에서 178343ms 뒤 `Succeeded`로 종료했다. 최종 응답은 `RECREATE_ABSENT`,
dynamic context는 0 bytes, last-prompt의 이전 file content/claim match는 모두 0,
source snapshot은 absent였다.

## 남은 경계

- #31926: purge 뒤 same-process chat operation store handle invalidation이 필요하다.
- #31927: playground false-context는 제거됐지만 one-click image에는
  `docker`/`container` CLI가 없어 sandbox container teardown warning이 남는다.
- 성능 향상은 주장하지 않는다. 첫 terminal turn 62613ms, 최종 fresh turn
  178343ms였다.

## 근거

- [근거] [Lemmalog 원문](https://pwning.systems/posts/llm-memory-program-analysis/),
  2026-08-30T12:36:47+09:00 확인, 신뢰도 High. source와 dependent artifact가
  바뀌면 과거 주장을 자동 철회해야 한다는 기준이다.
- [근거] Git remote-context build log, container `/health`, `build-commit`,
  `sha256sum`, Qwen chat/metrics, purge response/log, named-volume post-state,
  2026-08-30T15:08:10+09:00 확인, 신뢰도 High.
