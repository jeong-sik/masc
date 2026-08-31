# Memory OS aggregate budget runtime R1

## 결과

ordinary `*.memory-current.json`과 source-bound
`*.memory-source-current.json` writer가 keeper별 aggregate lock을 공유하게
했다. 두 store는 계속 분리돼 있지만, 어느 writer가 먼저 실행되든 상대
store의 exact rendered payload를 같은 commit 구간에서 읽고 합산 byte
budget을 검사한다.

이 수정은 issue #31915의 overcommit 경계를 닫는다. recall 시점의
fail-closed만 믿지 않고, 서로 합치면 다시 읽을 수 없는 snapshot 조합을
commit 전에 거절한다.

## 구현 계약

- lock 순서는 aggregate lock 다음 store-specific lock이다.
- ordinary writer는 aggregate lock 안에서 source snapshot을 읽는다.
- source-bound writer는 aggregate lock 안에서 callback으로 ordinary
  snapshot을 읽는다. module cycle을 만들지 않는다.
- source revalidation은 aggregate lock을 잡지 않는다. fact를 삭제하고
  반드시 더 짧은 typed invalidation으로만 바꾸므로 payload를 늘리지
  않는다는 계약을 test로 고정했다.
- reader는 aggregate lock을 잡지 않는다. commit 전 검사는 writer
  invariant이고, recall은 여전히 합산 초과 시 block 전체를 뺀다.
- store shape, old reader, migration, compatibility path는 추가하지 않았다.

## exact identity

- source commit: `e57f5ac581249e21ea0aba98698f6b20bf1b3d95`
- embedded binary commit: `e57f5ac581249e21ea0aba98698f6b20bf1b3d95`
- binary SHA-256:
  `65342273d818dff5f7abd41ed25ad49649de65a4b1d19a4141cd6caa5c6a86c0`
- provider/model: `ollama` /
  `hf.co/unsloth/gemma-4-31B-it-qat-GGUF:UD-Q4_K_XL`

세 runtime은 이 binary에서 실행했다. 이후 보고서만 추가했으며 production
source는 바꾸지 않았다.

## 실측 1: ordinary overcommit 거절

격리 포트 `9502`, 합산 budget `256`에서 source-bound stale claim을 먼저
live source와 대조했다. 첫 prompt는 stale claim을 넣지 않고 revision 2의
`source_changed` invalidation 1개를 241-byte block으로 넣었다.

모델에는 ordinary `keeper_memory_write`를 정확히 한 번 호출하고 content에
소문자 `x` 200개를 보내라고 지시했다. 모델은 지시와 달리 208 bytes를
보냈다. raw tool log가 확인한 실제 계약은 다음과 같다.

- tool call 1회
- `title` 없음, `source_path` 없음
- observed content 208 bytes
- combined rendered payload 364 bytes, limit 256 bytes
- `success=false`, `error_kind=persistence_failed`
- ordinary snapshot은 생성되지 않음
- source snapshot은 revision 2, fact 0개, invalidation 1개 유지
- workspace verifier exit 0

harness 표면의 `provider_error`는 예상한 terminal tool rejection이다. 이
run의 성공 판정은 pass rate가 아니라 raw tool output과 두 snapshot의
post-state다.

## 실측 2: 서버 재기동 뒤 tombstone 유지

첫 run의 config와 target을 보존한 채 서버를 종료하고 exact binary를 포트
`9503`에서 다시 시작했다. 같은 keeper에 두 번째 turn을 보냈다.

- operation state: `Succeeded`
- absolute turn: 2
- 새 prompt capture: `1788064088.335604`
- prompt block: 241 bytes
- source revision: 2
- 원래 `invalidated_at`: `1788063649.50978`
- fact 0개, `source_changed` invalidation 1개

즉 process memory가 아니라 current store가 pending invalidation을
복구했다. 두 번째 turn의 prompt에도 stale claim 대신 같은 tombstone이
들어갔다.

## 실측 3: 정상 source refresh 보존

aggregate guard가 정상 회복을 막지 않는지 포트 `9504`에서 기존
`l1-context-source-bound-refresh` case를 다시 실행했다.

- status `ok`, workspace verifier exit 0
- duration 159000 ms
- stale claim match 0
- 첫 prompt의 `source_changed` match 2
- tool sequence: `Read, Read, Write, Execute, keeper_memory_write`
- final revision 3, fact 1개, invalidation 0개
- live source와 final fact digest 모두
  `0b79c1f7c5218e6a6bfa92266b0de96e7f506a9edc8eeb8b3ef91ecd4115abce`

## artifact index

전체 hash와 측정값은
`benchmarks/context_recovery/results/20260830-aggregate-r1/summary.json`에
있다. 핵심 SHA-256은 다음과 같다.

| 측정 | artifact | SHA-256 |
|---|---|---|
| overcommit | tool calls JSONL | `f7aa97b7…c41742` |
| overcommit | operation final | `5371d801…186160` |
| restart | last prompt | `ffd90d93…8fba6` |
| restart | operation final | `79a35545…a8431` |
| refresh | evidence | `4f6e3a24…b43f79` |
| refresh | final source snapshot | `286d35c5…12c87` |

## focused checks

- `test_keeper_memory_write`: 16/16
- `test_keeper_memory_os_current`: 22/22
- focused build: `bin/main_eio.exe`, `coding_eval_report_cli.exe`, 두 test
  executable

여기에는 ordinary-first, source-first, concurrent source-first writer,
invalidation monotone-shrink case가 포함된다. test는 동시 commit interleaving
회귀를 잡는 보조 근거이고 runtime proof를 대신하지 않는다.

## 해석과 한계

- 이번 측정은 overcommit 방지와 restart persistence를 증명한다. latency나
  모델 성능 향상은 주장하지 않는다.
- 모델은 200자 지시를 208 bytes로 실행했다. 그래서 prompt compliance
  점수로 사용하지 않고 실제 raw input을 기준으로 판정했다.
- source bytes는 aggregate lock을 기다리기 전에 읽힌다. 대기 중 외부
  source가 다시 바뀌면 다음 recall의 deterministic revalidation이 claim을
  무효화한다.
- file lock 장애나 disk I/O 실패는 typed write failure로 남는다. 장기
  contention 성능은 아직 측정하지 않았다.
- purge가 source-bound snapshot을 남기는 별도 lifecycle 결함은 issue
  #31917이다. 이 PR에 섞지 않았다.
- semantic claim이 source 내용을 올바르게 요약했는지는 여전히 증명하지
  않는다.

## 실행 종료

격리 포트 `9501`-`9504`에는 listener가 남지 않았다. 운영 `8935`는
`status=ok`, `effective_base_path=/Users/dancer/me`,
`effective_masc_root=/Users/dancer/me/.masc`, `roots_diverge=false`였다.
운영 state나 배포 binary는 바꾸지 않았다.

## 근거

- [근거] [Lemmalog 원문](https://pwning.systems/posts/llm-memory-program-analysis/),
  2026-08-30T12:36:47+09:00 확인, 신뢰도 High. stale observation에 의존한
  결론을 model 재판단 전에 철회하는 설계 근거다.
- [근거] [Lemmalog 저장소](https://github.com/JordyZomer/lemmalog),
  2026-08-30T12:36:47+09:00 확인, 신뢰도 High. provenance, retraction,
  incremental update 범위를 확인했다.
- [근거] [STALE 논문](https://arxiv.org/abs/2605.06527),
  2026-08-30T12:36:47+09:00 확인, 신뢰도 High. state resolution과 premise
  resistance를 분리해 측정하는 근거다.
- [근거] [StateAuditor 논문](https://arxiv.org/abs/2608.01619),
  2026-08-30T12:36:47+09:00 확인, 신뢰도 High. provenance와 chronology를
  결정적 코드로 검증하는 경계다.
- [근거] `git rev-parse HEAD`, binary `build-commit`, `shasum -a 256`, raw
  tool JSONL, source snapshots, `/last-prompt`, `/health?full=1`, `lsof`,
  2026-08-30T13:32:06+09:00 확인, 신뢰도 High.
