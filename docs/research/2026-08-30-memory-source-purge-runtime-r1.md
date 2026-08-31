# Source-bound Memory purge runtime R1

## 결과

dashboard Keeper purge의 typed artifact plan에
`Keeper_memory_source_current_artifact`를 추가했다. path는 source store
owner인 `Keeper_memory_source_current.path_for_keepers_dir`로만 계산한다.

이제 purge는 ordinary snapshot과 journal뿐 아니라
`<keeper>.memory-source-current.json`도 strict removal한다. 같은 이름
Keeper가 새로 생겨도 이전 source fact나 pending invalidation을 상속하지
않는다.

## 변경 범위

- public purge artifact variant 1개
- dashboard purge plan entry 1개
- server path projection 1개
- plan membership regression assertion 1개

source store schema, reader, migration, lock sidecar는 바꾸지 않았다. `.lock`은
stale claim을 담지 않는 기존 file-lock artifact이므로 authority가 아니다.

## exact identity

- source commit: `cadfbc6b47d7ea646c29df7f4d8eef82b9478f95`
- embedded binary commit: `cadfbc6b47d7ea646c29df7f4d8eef82b9478f95`
- binary SHA-256:
  `f527230f8c0a5e93880d7507e96660df9cf9673d4d72c88da969f34b5080e472`
- provider/model: `ollama` / `qwen3:8b`

이 binary로 state 생산, purge, same-name recreate, 추가 restart를 모두
실행했다. 이후 보고서만 추가했으며 production source는 바꾸지 않았다.

## 실측 1: purge할 pending invalidation 생산

포트 `9507`에서 45자 Keeper
`coding-eval-ollama-qwen3-8b-p-source-bound-r1`을 만들었다. source seed와
live file을 다르게 둬 첫 turn 전에 deterministic revalidation을 일으켰다.

- first prompt Memory OS block: 315 bytes
- source snapshot: revision 2, fact 0개, invalidation 1개
- reason: `source_changed`
- model tool call: 0회
- workspace verifier: 0

모델에는 source memory를 재생성하지 말고 짧게 답하게 했으므로 harness의
`provider_error`는 예상한 final recreation 미충족이다. 이 단계의 authority는
pass rate가 아니라 purge 직전 persisted snapshot
`707c2cd9…099ea8`이다.

## 실측 2: dashboard purge

같은 config/target을 포트 `9508`에서 재기동하고
`POST /api/v1/dashboard/agents/purge`를 호출했다.

- HTTP 202
- `accepted=true`
- operation `shutdown-acd27bef-93c7-422b-a3e1-cfe27d8547bc`
- lifecycle completion log 관찰
- source snapshot absent
- Keeper TOML absent
- runtime directory absent
- Keeper meta absent

pre-purge source artifact의 hash와 harness final snapshot hash는 같았다. 즉
관찰한 바로 그 revision 2 snapshot이 purge 대상이었다.

## 실측 3: same-name fresh create와 다시 재기동

purge가 Keeper TOML도 지우므로 새 docker profile을 명시하고, 같은 이름을
포트 `9510`에서 다시 만들었다. 새 turn 결과는 다음과 같다.

- operation `Succeeded`
- outcome `trace-1788065461314-00000#1`
- assistant response `AFTER_PURGE_OK`
- tool call 0회
- latency 33511 ms
- persisted prompt metrics의 dynamic context 0 bytes
- source snapshot absent

dynamic context가 없어서 `/last-prompt` capture 자체가 만들어지지 않았다.
포트 `9511`에서 한 번 더 재기동한 뒤 endpoint가 HTTP 404와
`this keeper has not assembled a turn since prompt capture existed`를 그대로
반환하는 것을 확인했다. 이것은 stale block이 빈 block으로 위장한 것이
아니라 주입 artifact 자체가 없다는 관찰이다.

## 실패가 만든 새 정보

첫 purge probe는 coding-eval의 75자 Keeper를 사용했고 포트 `9506`에서
HTTP 400을 받았다. purge resolver가 generic identifier max 64를 먼저
적용했기 때문이다. creation과 purge name contract가 다른 별도 persistence
gap은 issue #31919로 기록했다. #31917 수정에는 섞지 않았다.

첫 same-name recreate는 profile 없이 호출해 sandbox validation에서
fail-closed했다. purge가 TOML까지 삭제한 정상 결과였으며, fresh profile을
명시한 다음 run은 성공했다.

## artifact index

전체 hash와 exact 값은
`benchmarks/context_recovery/results/20260830-purge-r1/summary.json`에 있다.

| 구간 | artifact | SHA-256 |
|---|---|---|
| pre-purge | source snapshot | `707c2cd9…099ea8` |
| purge | response | `350035e1…3998f` |
| purge | post-state | `fbbaed67…67b10` |
| recreate | operation final | `1e74a1a8…30fb7` |
| recreate | metrics | `8d851e9b…a60d4` |
| recreate | chat | `50d0f5fe…2ea4f` |
| restart | empty prompt response | `ff75bf4b…f8338` |

## focused checks

- `test_keeper_memory_os_current`: 22/22
- focused `bin/main_eio.exe`와 test executable build
- `ocamlformat --check`
- `git diff --check`

test는 typed plan membership과 exhaustive path projection의 보조 근거다.
실제 deletion authority는 HTTP 202, lifecycle completion, 네 artifact의
post-state, same-name prompt metrics를 함께 사용했다.

## 한계

- 64자 초과 기존 Keeper purge는 #31919가 해결되기 전까지 실패한다.
- global system logs에는 과거 invalidation 관찰이 남을 수 있다. 새 Keeper
  prompt authority가 아니며, 이번 fresh turn의 dynamic context는 0 bytes였다.
- auth token/credential artifact cleanup은 이 source snapshot slice의 판정
  대상이 아니다.
- qwen3:8b 한 run이므로 성능 향상은 주장하지 않는다.

## 실행 종료

격리 포트 `9505`-`9511`에는 listener가 남지 않았다. 운영 `8935`는
`status=ok`, `effective_base_path=/Users/dancer/me`,
`effective_masc_root=/Users/dancer/me/.masc`, `roots_diverge=false`였다.
운영 state나 배포 binary는 바꾸지 않았다.

## 근거

- [근거] [Lemmalog 원문](https://pwning.systems/posts/llm-memory-program-analysis/),
  2026-08-30T12:36:47+09:00 확인, 신뢰도 High. 철회된 observation의
  dependent state가 새 identity에 남지 않아야 한다는 설계 근거다.
- [근거] [Lemmalog 저장소](https://github.com/JordyZomer/lemmalog),
  2026-08-30T12:36:47+09:00 확인, 신뢰도 High. provenance와 retraction의
  현재 구현 범위를 확인했다.
- [근거] [STALE 논문](https://arxiv.org/abs/2605.06527),
  2026-08-30T12:36:47+09:00 확인, 신뢰도 High. state resolution과 false
  premise rejection을 구분하는 근거다.
- [근거] `git rev-parse HEAD`, binary `build-commit`, `shasum -a 256`,
  dashboard purge response, persisted source snapshot, Keeper metrics/chat,
  `/last-prompt`, `/health?full=1`, `lsof`,
  2026-08-30T13:52:58+09:00 확인, 신뢰도 High.
