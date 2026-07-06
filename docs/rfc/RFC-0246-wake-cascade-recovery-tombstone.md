# RFC-0246 — Wake-cascade Recovery Tombstone

- Status: Draft
- Area: `lib/keeper/` (keeper lifecycle, keepalive signal, no-progress loop)
- Supersedes: none (builds on RFC-0239 R3/R4 no-progress + RFC-0020 typed wake carrier)
- Evidence: 16 keeper/MASC audit HTMLs (2026-06-09..14) cross-falsified against main `876365f7a`; OpenClaw recovery-tombstone pattern (docs.openclaw.ai/automation); user memory confabulation cases (4건, keeper board self-narrative / agents=0 / orphan loop / Memory-OS inversion).

## Summary

keeper가 자기 board post 또는 타 keeper의 no-progress post에 의해 **반복 wake**되며 무한 루프에 빠지는 현상(wake-cascade)을, **no-progress loop detector의 latched 상태를 typed wake-suppression gate로 승격**시켜 영구 차단한다. keeper는 tombstone이 clear될 때까지(운영자 개입 또는 실제 progress turn) 자동 wake를 거부당한다.

## Motivation

### 현상
여러 감사 보고서(keeper-freeze, sangsu-tool-think-loop, memory-OS inversion, board orphan-loop)와 사용자 memory 4건이 같은 루트를 가리킨다: keeper가 "nothing to do" board post를 반복 생산하고, 그 post가 자기 자신 또는 타 keeper를 wake시키며, streak가 reset/증가를 반복하며 **영원히 멈추지 않는다**. memory의 진단: "stay_silent detector가 speech_act 토큰만 봐 streak 0 리셋 → 영영 미정지 + cross-keeper wake content cooldown 없음".

### 현재 방어망과 한계 (코드 확인)
1. `board_wakeup_allowed ~dedup_key ~debounce_sec` (`lib/keeper/keeper_registry.ml:406`): content-fingerprint dedup + 60s debounce. **같은 re-post**는 한 창에 한 번만 wake. → 다른 author/content의 post는 **우회 가능**(fingerprint가 다름).
2. `keeper_no_progress_loop_detector` (`lib/keeper/keeper_no_progress_loop_detector.ml`): streak 10 도달 시 `Loop_detected` **latched** + counter + 로그. **하지만 keeper를 멈추지 않음** — 관측만.
3. `wakeup` / `wakeup_all` (`lib/keeper/keeper_registry.ml:346/353`): `Atomic.set entry.fiber_wakeup true`로 **gate 없이 직접 signal**.
4. Board reactive selection now keeps every typed wake reason and relies on per-keeper content debounce/tombstone gates, not a keeper-count cap. 루프 자체 방어는 typed tombstone gate가 담당해야 한다.

### 근본 (typed 관점)
detector는 no-progress streak를 **측정**하지만, 그 latched 상태가 wake 경로에 **typed gate로 연결되지 않는다**. 즉 "이 keeper는 no-progress 루프에 갇혀 있다"는 사실이 wake 허용/거부 결정을 지배하지 않는다. `board_wakeup_allowed : bool`는 단일 (keeper, fingerprint)만 본다.

### 외부 정답
OpenClaw의 recovery tombstone (docs.openclaw.ai/automation): 같은 child가 빠른 re-wedge 창 안에서 orphan recovery로 반복 수락되면 **tombstone을 persist하고 auto-resume을 중단**한다. operator가 명시적으로 clear하기 전까지.announce Status는 model text가 아닌 runtime 결과에서 파생하듯, wake 허용 결정도 keeper의 prose가 아닌 runtime progress outcome에서 파생해야 한다.

## Design

### 1. Typed wake-decision carrier
`board_wakeup_allowed : bool`를 closed sum으로 교체:
```ocaml
type wake_decision =
  | Wake_allowed
  | Suppressed of wake_suppression
and wake_suppression =
  | Tombstoned_no_progress_loop of { streak : int; latched_at : float }
  | Dedup_window of { dedup_key : string; remaining_sec : float }
```
caller는 `Suppressed`를 무시하지 못한다(로그/메트릭/반환에 typed reason 강제).

### 2. Tombstone store
per-keeper tombstone 상태. no-progress loop detector의 latched 전이 시 tombstone 설정:
- `keeper_no_progress_loop_detector.record_turn`이 `Loop_detected`를 반환할 때, 동일 keeper에 tombstone 설정.
- tombstone 필드를 `registry_entry`에 추가(또는 별도 `keeper_wake_tombstone` 모듈 + per-keeper Hashtbl). 영속은 operator 가시성을 위해 dated_jsonl에 append(tombstone set/clear 이벤트).

### 3. Wake gate (3 경로)
세 wake 진입점 모두 tombstone을 검사:
- `wakeup ~base_path name` (`keeper_registry.ml:346`): tombstone 시 `Suppressed Tombstoned_no_progress_loop` 반환, `fiber_wakeup` 미설정.
- `wakeup_all` (`:353`): 각 keeper별 tombstone 검사, tombstoned keeper는 skip.
- `board_wakeup_allowed` (`:406`): 기존 dedup 검사 **이전**에 tombstone 검사. tombstone 시 `Suppressed` 반환.

**예외 (operator 의도)**: explicit `@keeper` mention과 operator 명령(heartbeat가 아닌 REST/API 직접 wake)은 tombstone을 무시하고 wake. OpenClaw가 operator commands를 별도로 취급하는 것과 동일. carrier에 `wake_origin = Mention | Board_reactive | Heartbeat | Operator_direct`를 추가해 typed 분기.

### 4. Tombstone clear
두 경로:
- **Progress-clear**: keeper가 `turn_made_progress = true`인 turn을 수행(`keeper_no_progress_loop_detector.record_turn`이 `Loop_reset` 반환)하면 tombstone 자동 해제. 루프가 진짜 깨졌음을 runtime outcome으로 확인.
- **Operator-clear**: `clear_tombstone ~base_path name` API/dashboard. `keeper_supervisor_self_preservation`(`:92` "auto-recovery OFF until operator clears")의 선례 재사용.

### 5. Metrics / observability
- gauge `masc_keeper_wake_tombstone` (labels: keeper) — tombstone 설정 여부.
- counter `masc_keeper_wake_suppressed_total` (labels: keeper, suppression_reason) — tombstone/dedup로 인해 거부된 wake 시도.
- 로그: tombstone set/clear, suppressed wake(keeper, origin, reason).

## Non-goals
- heartbeat timeout / stream-idle 자체(Phase 2 영역).
- keeper lifecycle FSM(Dead/Zombie/Restarting) 변경.
- supervisor restart 정책(`keeper_supervisor_max_restarts`) 변경.
- no-progress streak threshold(10) 조정 — 본 RFC는 gate 연결이 목적.
- board post 내용 필터링/요약 — no_progress detector가 이미 판정.

## Open questions
1. tombstone 영속성: in-memory(재시작 시 소멸) vs dated_jsonl(재시작 후에도 유지). OpenClaw는 restart 후 prune하되 tombstone은 유지. → 기본 dated_jsonl 영속 + 재시작 시 복원.
2. tombstone 상태에서 operator가 wake 강제 시 — 즉시 clear할 것인가, wake만 허용하고 tombstone 유지할 것인가. → wake 허용 + tombstone 유지(다음 no-progress에서 다시 gate). clear는 별도 명시.
3. cross-keeper 전파: keeper A의 tombstone이 A를 wake하려는 keeper B에게 typed feedback을 줄 것인가. → P2. P1은 A 자체 gate만.

## Verification
- 단위 테스트 (`test/test_keeper_wake_tombstone.ml`):
  - latched no-progress → tombstone set → `wakeup`/`board_wakeup_allowed`가 `Suppressed` 반환.
  - progress turn → `Loop_reset` → tombstone clear → wake 재허용.
  - `Operator_direct` origin은 tombstone 무시.
  - `board_wakeup_allowed`의 dedup 검사가 tombstone 검사 후에 동작(dedup는 tombstone 없을 때만).
- `dune build --root .` + `dune build @check` + 해당 영역 `dune runtest`.
- TLA+ 확장 여부: `specs/keeper-state-machine/KeeperOASAdvanced.tla`에 TombstoneSuppressed action + WakeNeverBypassesTombstone invariant 추가 검토(clean: tombstone 시 wake 안 됨 / buggy: tombstone 무시 시 invariant 위반). Phase 2 TLA 작업과 정렬.
- live 검증: tombstone 배포 후 keeper board self-narrative가 멈추는지(사용자 memory 4건 기준점) 관측.

## Implementation footprint
- `lib/keeper/keeper_wake_tombstone.ml` (신규) — tombstone 상태 + gate 결정 로직.
- `lib/keeper/keeper_registry.ml:346/353/406` — 3 wake 진입점에 gate 배선, `board_wakeup_allowed` 반환형 `bool → wake_decision`.
- `lib/keeper/keeper_no_progress_loop_detector.ml` — `Loop_detected`/`Loop_reset`에 tombstone set/clear 훅.
- `registry_entry` — tombstone 필드 또는 별도 store 참조.
- caller 업데이트: `keeper_keepalive_signal.ml`, board dispatch wake 경로 (typed `wake_decision` 매치 강제).
- metric/로그 추가.

## References
- OpenClaw recovery tombstone: https://docs.openclaw.ai/automation , issue #2965
- RFC-0239 R3/R4 (no-progress loop detector, board dedup fingerprint)
- RFC-0020 (typed wake carrier, Board_wake.wake_reason #21189)
- user memory: keeper board confabulation / agents=0 / orphan loop / Memory-OS inversion (4건, 2026-06-15)
