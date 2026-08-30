# Long-name Keeper purge runtime R1

## 결과

Keeper 생성 SSOT는 portable filesystem name을 최대 128자까지 받지만,
dashboard purge는 generic agent identifier의 64자 gate를 먼저 적용했다.
그 결과 생성된 75자 Keeper를 purge할 수 없었다.

resolver는 typed `Keeper_id.Keeper_name`을 먼저 읽도록 바꿨다. route가
Keeper 판별 전에 호출되므로 기존 namespaced plain-agent fallthrough는
generic validator로 보존했다. completion의 `Agent_artifact_bundle`도 Keeper
validator를 사용하고, synchronous plain-agent purge는 기존 64자 validator를
계속 쓴다.

## exact identity

- source/embedded commit: `f04d50dff57b3a49143f8786aebdec5f321a426b`
- binary SHA-256:
  `39ceeef14183564c97527e66eff17105f8da3592a3d27b0a2d1b202e7d81521b`
- model: `ollama/qwen3:8b`
- Keeper name length: 75

## 실측

포트 `9515`에서 exact binary가 75자 Keeper를 새로 만들고 source-bound
refresh case를 통과했다. final source snapshot은 revision 3, fact 1개,
invalidation 0개였다.

같은 target/config를 포트 `9516`에서 재기동해 dashboard purge를 호출했다.
HTTP 202와 operation
`shutdown-a8870a13-7926-45e8-9b93-01f9de62bfa1`을 받았다. 완료 뒤 source
snapshot, Keeper TOML, runtime directory, meta는 모두 absent였고 completion
또는 recovery error match는 0이었다.

fresh profile을 넣고 포트 `9517`에서 또 재기동했다. 같은 75자 이름의 새
Keeper가 생성됐고 turn은 `Succeeded`, 응답은 `LONG_PURGE_OK`였다. prompt
metrics의 dynamic context는 0 bytes, source snapshot은 absent,
`/last-prompt`는 injection artifact가 없어 HTTP 404였다.

## 실패에서 수정한 두 번째 경계

resolver만 고친 첫 binary는 purge를 202로 받았지만 completion의 agent
artifact cleanup이 다시 generic 64자 validator를 써 durable shutdown
record를 남겼다. 재기동 때 recovery가 실패하고 fresh profile까지 다시
삭제했다. callstack으로 `exact_agent_aliases`가 전달받은 validator 대신
하드코딩된 plain validator를 호출함을 확인했다. 이 loop를 고친 뒤
resolver와 completion focused case 2/2, exact runtime 전체가 통과했다.

전체 hash는
`benchmarks/context_recovery/results/20260830-long-name-purge-r1/summary.json`에
있다. 성능 향상은 주장하지 않는다. 포트 `9515`-`9517`은 모두 종료했다.

## 근거

- [근거] [Lemmalog 원문](https://pwning.systems/posts/llm-memory-program-analysis/),
  2026-08-30T12:36:47+09:00 확인, 신뢰도 High. stale state의 자동 철회와
  dependent artifact 정리 근거다.
- [근거] `Keeper_id.Keeper_name.max_length`, exact build identity, dashboard
  purge response, shutdown logs, post-state, Keeper metrics/chat, `lsof`,
  2026-08-30T14:14:04+09:00 확인, 신뢰도 High.
