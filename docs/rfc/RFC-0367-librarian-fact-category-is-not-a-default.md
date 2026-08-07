# RFC-0367 — `fact` 는 기본값이 아니라 최후수단이어야 하고, 그건 스키마가 강제해야 한다

**Status**: Draft
**Author**: Claude Opus 5 (1M context)
**Date**: 2026-08-07

## 문제

librarian 프롬프트는 이미 옳은 말을 하고 있다.

> `fact` is the **last resort, never the default** — if you are unsure whether something is durable, omit it rather than storing it as "fact".

지시는 지켜지지 않는다. 2026-08-07 실측:

```
rondo, rev 600~667 에 추가된 44건
  fact                37   (84%)
  blocker              4
  goal                 2
  constraint           1
```

그리고 rev 668 에서 32건이 한 커밋에 전부 버려졌다. drop reason 은 하나하나 정당하다.

```
"Task-205 is fully done and accepted, so this claim that it is 'todo and reclaimable' is false."
"Mid-progress status of task-205 is obsolete — the task is fully done and accepted."
"Meta-entry about which other memory entries are stale is itself stale and has no durable value."
```

버린 판단은 옳았다. 문제는 **애초에 담긴 것이 순간 상태였다는 것**이고, 그것들이 전부 `fact` 로 들어왔다는 것이다.

대조군이 이를 확인한다. `sangsu` 는 같은 기간 14건을 유지하고 있고 최고령이 70.6시간이다.

```
constraint          3     "PR title validation enforces ^\[([A-Z]+-[0-9]…"
lesson              5     "submit_for_verification requires a `notes` field…"
validated_approach  4
fact                2
```

`fact` 가 2건이다. 살아남는 메모리는 외부에서 강제되는 규칙이고, 사라지는 메모리는 `fact` 로 들어온 순간 상태다.

## 왜 프롬프트로는 안 되는가

`fact` 는 카테고리 목록의 마지막 항목이고, 스키마상 다른 일곱과 완전히 동등하다.

```json
"category": "code_change|fact|preference|blocker|goal|constraint|validated_approach|lesson"
```

"최후수단"은 산문에만 있다. 모델이 분류에 확신이 없을 때 가장 넓은 라벨을 고르는 것은 합리적 행동이고, `fact` 의 정의("externally verifiable statement about the world")는 거의 모든 문장을 받아준다. 프롬프트를 더 강하게 쓰는 것은 같은 층위에서 같은 부탁을 반복하는 것이다.

이 저장소는 같은 결론에 여러 번 도달했다. `RFC-0042` 가 문자열 분류기를 닫은 것, 오늘 `#27275` 가 게이트 감사에서 네 권한을 문자열 하나로 뭉개던 것을 payload 없는 variant 로 바꾼 것이 같은 모양이다. CLAUDE.md 의 워크어라운드 거부 기준 2번(문자열 분류기 보강)이 정확히 이 자리를 가리킨다.

## 제안

`fact` 에만 추가 필드를 요구해, 다른 일곱과 **비용이 다르게** 만든다.

```json
{
  "claim": "…",
  "category": "fact",
  "durability_basis": "무엇이 이 문장을 다음 주에도 참으로 유지하는가"
}
```

- 일곱 카테고리는 지금과 동일하다. 각자 정의가 이미 지속성을 함의한다 — `constraint` 는 외부가 강제하고, `lesson` 은 교정을 담고, `validated_approach` 는 확인된 결과를 담는다.
- `fact` 는 `durability_basis` 없이는 파서가 거부한다. 근거를 못 쓰면 애초에 durable 하지 않다는 뜻이므로, 프롬프트 53행("If you are unsure a claim is durable, omit it")이 산문이 아니라 검증으로 집행된다.
- `durability_basis` 는 저장되지 않는다. 입장 심사에만 쓰고 버린다. 저장하면 그 자체가 재심 대상이 되어 같은 문제를 재생산한다.

### 대안과 트레이드오프

| 안 | 장점 | 단점 |
|---|---|---|
| `fact` 를 스키마에서 제거 | 가장 단순 | 일곱에 안 맞는 진짜 외부 사실을 담을 곳이 없어짐 |
| `fact` 에 만료 시각 요구 | 순간 상태를 자동 청소 | 만료 추정은 또 다른 비결정 판단이고, 정리기는 이미 정상 작동한다 |
| **`durability_basis` 요구 (제안)** | 기존 카테고리 보존, 거부가 결정론적 | 프롬프트/스키마 양쪽 수정, 기존 저장분과의 호환 필요 |
| 프롬프트만 강화 | 코드 변경 없음 | **이미 시도된 상태이며 84% 로 실패했다** |

## 범위

- `Keeper_librarian` 의 selection 스키마와 파서
- `config/prompts/librarian.md` 의 출력 스키마 블록과 `fact` 항목
- 기존 저장분: 이미 저장된 `fact` 는 `durability_basis` 가 없다. 재심에서 요구하지 않는다 — 입장 심사에만 적용한다. (별도 변경으로 재심과 입장 기준을 분리했다: `fix/librarian-retention-asymmetry`)

## 검증

게이트는 PASS 가 아니라 **거부하는지**로 확인한다.

1. `durability_basis` 없는 `fact` 를 담은 selection → 파서가 거부
2. `durability_basis` 있는 `fact` → 통과, 저장된 fact 에는 필드가 없음
3. 다른 일곱 카테고리 → 필드 없이 통과 (기존 동작 불변)
4. 이미 저장된 `fact` 의 재심 → 필드를 요구하지 않음

측정 지표는 카테고리 분포다. 배포 후 `fact` 비율이 84% 에서 유의하게 내려가고 메모리 생존 시간이 늘어나는지를 `*.memory-journal.jsonl` 로 확인한다. 내려가지 않으면 이 RFC 는 틀린 것이고 되돌린다.

## 관련

- `fix/librarian-retention-asymmetry` — 재심 기준을 입장 기준에서 분리 (프롬프트 단독, 이 RFC 없이도 유효)
- `#27275` — 같은 형태(문자열 하나로 뭉개진 분류)를 게이트 감사에서 typed variant 로 교체
- CLAUDE.md 워크어라운드 거부 기준 §2 — 문자열 분류기 보강
