# RFC-0297 Phase 1 (P0-1) 구현 계획 — closed-variant lifecycle gate

design-first 산출물 (CLAUDE.md: 복잡 로직 → 의사코드/테스트 케이스 먼저; RFC-0297 Phase 1 = TLA+ 필수).
2026-07-01 착수. worktree `feat/rfc-0297-p0-1-lifecycle-enabled-gate`.

## 문제 (착수 전 baseline — 이 PR이 아래 갭을 메운다)

| 사실 (이 PR 이전) | 근거 (실측 2026-07-01) |
|---|---|
| global TOML kill-switch(reactive/proactive/autonomous `.enabled`)가 없었음 | `keeper_runtime_config.ml:7-100` `key_to_env`에 `bootstrap.enabled`/`alert.enabled`/`debug.enabled`만. `[reactive]`=max_idle_turns, `[proactive]`=min_interval_sec, `[autonomous]`=fairness_cooldown/max_idle_turns 만 |
| unknown TOML key는 silent drop | `keeper_runtime_config.ml:6` 주석 + `load_and_apply`(190-218)가 `key_to_env`만 순회 → doc의 미매핑 키는 방문 안 됨 |
| per-keeper meta gate는 **이미 존재** | `keeper_activation_readiness.ml:16-20` `autonomous_blocker`: paused→autoboot_disabled(`meta.autoboot_enabled`)→proactive_disabled(`meta.proactive.enabled`) |
| reactive.enabled는 meta에도 없음 | 위 blocker에 reactive 항목 없음 |
| short-circuit | RFC-0297 §P0-1: reactive trigger 존재 시 `keeper_cycle_decision`(`lib/keeper/keeper_world_observation.ml:1054`)이 proactive/autoboot gate 검사 건너뜀 |

## 설계 (닫힌 변형 gate)

```
(* keeper_lifecycle_gate.ml — 신규, 순수 모듈 *)
type gate = Reactive | Proactive | Autonomous | Bootstrap

(* global(config) AND per-keeper(meta) 둘 다 true여야 enabled. default true.
   Reactive는 per-keeper meta 필드가 없음 — meta 쪽은 상수 true로 투영되어
   global kill-switch만으로 결정됨(구현: keeper_lifecycle_gate_env.ml
   meta_flags). *)
val gate_enabled : gate -> global:gate_config -> meta:Keeper_meta_contract.keeper_meta -> bool
```

- `gate_config` = runtime config에서 온 3개 global bool (기본 true). config record에 `reactive_enabled`/`proactive_enabled`/`autonomous_enabled` 필드 추가.
- exhaustive `match gate with` — 새 gate 추가 시 컴파일 에러(CLAUDE.md §FSM sparse match 방지).
- `Bootstrap`은 기존 `meta.autoboot_enabled` + `bootstrap.enabled`(이미 존재)로 매핑.
- `Reactive`는 per-keeper meta 토글이 존재하지 않으므로 global switch만 적용(meta 쪽은 always-true 투영).

## 구현 순서 (한 PR, 각 커밋 단위)

1. **config plumbing**: `key_to_env`에 3줄 추가 (`reactive.enabled`→`MASC_KEEPER_REACTIVE_ENABLED` 등, `proactive.enabled`→`MASC_KEEPER_PROACTIVE_ENABLED`, `autonomous.enabled`→`MASC_KEEPER_AUTONOMOUS_ENABLED`). runtime config record에 3 bool 필드(default true) + env parse. — 소비자(4)와 같은 PR이어야 no-op 아님.
2. **closed-sum gate 모듈**: `keeper_lifecycle_gate.ml{,i}` 신규. `gate_enabled` 순수 함수. 단위 테스트(global×meta 진리표 8케이스, default true).
3. **known-key WARN**: `load_and_apply`가 doc의 모든 키를 순회, `key_to_env` + 다른 로더 소비 키(=whitelist SSOT)에 없으면 `Log.warn "unknown runtime.toml key %s (ignored)"`. **주의**: whitelist는 keeper_runtime_config 외 로더(env_config_keeper 등)가 읽는 키까지 포함해야 false-positive 없음 → whitelist SSOT를 먼저 수집(별도 상수).
4. **short-circuit 제거**: `keeper_world_observation.ml`의 `keeper_cycle_decision`에서 reactive trigger 존재 시 `gate_enabled Reactive` 검사(global kill-switch가 꺼져 있으면 reactive trigger가 있어도 turn을 열지 않음). 순서를 주석으로 명시.
5. **activation_readiness 통합**: `autonomous_blocker`가 global gate도 검사(현재 meta만) → global proactive/autonomous false 시 blocker.

## 테스트 케이스 (Verification, RFC §Phase1)

- `gate_enabled`: global=false & meta=true → false; global=true & meta=false → false; 둘 다 true → true; 미설정(default) → true. (closed match 전수)
- unknown key WARN: `[proactive] enabled=false` + 미매핑 키 주입 → WARN 발생, known 키는 무경고.
- short-circuit 제거: reactive trigger 존재 + `proactive.enabled=false` → proactive 턴 미발생 (RFC §109).
- 회귀: 기존 default(전부 on) 동작 불변 (default true).

## TLA+ (Phase 1 필수, CLAUDE.md §TLA+ Bug Model)

- `KeeperLifecycleGate.tla`: state = (global_gates, meta_gates, trigger). 
- `Next` (clean): gate_enabled가 global∧meta. reactive trigger가 proactive gate를 우회 못 함.
- `BugAction` `ShortCircuitBypass`: reactive trigger 존재 시 proactive gate 무시하고 Run_proactive.
- `SafetyInvariant` `ProactiveNeverRunsWhenGated`: proactive 턴 실행 ⇒ gate_enabled Proactive.
- clean.cfg: no error / buggy.cfg(`Next \/ ShortCircuitBypass`): invariant violated.

## 범위 밖 (별도 PR)
- Phase 2(orphan TTL), Phase 3(config SSOT git 영속), Phase 4(FSM decision SSOT). RFC-0297 §96 표 참조.

## Deconfliction (fleet 중복 방지, 2026-07-01 확인)
- RFC-0297 doc(#22614), front door(#22618), no-progress closed-sum FSM(#22620), resume(#22621) 모두 MERGED. **enabled-gate(P0-1) 자체를 다루는 열린 PR/최근 커밋 없음** → 중복 아님.
