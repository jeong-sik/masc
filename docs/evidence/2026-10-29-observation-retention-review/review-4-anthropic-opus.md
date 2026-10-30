
(로컬에 masc 체크아웃이 없어서 커밋 diff는 확인하지 못했습니다. 아래 재분류는 주신 설명만 보고 한 것입니다.)

**Verdict 항목별 평가**
- **1. 동의합니다.** 다만 공통 journal이 틀린 핵심 이유는 메커니즘이 다양해서라기보다, 두 번째 진실원(second source of truth)이 생긴다는 점입니다.
- **2. 검증되지 않은 주장입니다.** A군 fix가 rebuild 지점에 live 경로의 derivation을 *복제*하는 방식이었다면, 각 fix는 국소적으로는 최소여도 다음 drift가 생길 표면을 넓힌 셈입니다. 29건 중 같은 함수가 다시 고쳐진 비율(fix-of-fix)을 세어 보면 확인할 수 있고, 이 비율이 높으면 2는 반증됩니다.
- **3. 절반만 맞습니다.** 더 근본적인 원인은 같은 사실을 계산하는 경로가 둘 이상 있다는 구조입니다. 의무를 추가하는 것은 증상 관리에 가깝습니다.

## a. 불변식 프레이밍

- **⊇는 너무 약합니다.** 다음 세 경우가 모두 통과합니다.
  - 부활: 의도적으로 끝낸 ownership이 replay로 되살아남
  - 중복: replay 때 correlation key나 retry가 두 번 적용됨
  - 우선순위 역전: C군처럼 관측은 남아 있는데 최종 verdict가 틀림

  인용하신 선례도 `transcript = fold log`라는 등식입니다. 따라서 `project(rebuild(durable)) = project(live)`로 써야 합니다.
- **"intentionally"는 검사할 수 없습니다.** 29건 모두 작성자에게 손실 의도는 없었고, 그래서 아무도 몰랐습니다. 의도적 종료는 코드에 드러나야 합니다. boundary별 명시적 drop 목록이나 `Ended of reason` 생성자가 그 방법입니다.
- **"accepted"가 정의되어 있지 않습니다.** 정의가 없으면 "모든 in-memory 사실을 영속화하라"로 읽혀 헌법에 어긋납니다. accepted를 *다른 주체(client, agent, user)에게 ack된 것*으로 정의하길 제안합니다. 누군가 이미 그 사실에 의존했으니, 잃으면 헌법이 말하는 durable truth 손상과 정확히 일치합니다.
- **수명(lifetime) 조항이 없습니다.** "끝내지 않는 한 살아남는다"에 끝의 정의가 없으면 무한 누적, 즉 컨텍스트 메모리 누수를 불변식이 정당화하게 됩니다. 관측 종류마다 lifetime(turn, session, 명시적 retract)을 선언하게 해야 합니다.

**축은 하나가 아니라 셋입니다.**

| 불변식 | 내용 | 해당 군 |
|---|---|---|
| I1 rebuild 동등성 | `project(rebuild) = project(live)` | A, restart |
| I2 전이 단조성 | 확정된 결과나 소유권은 같은 작업의 error, cleanup, interrupt 전이로 덮어쓸 수 없고 명시적 후속 이벤트로만 대체됨 | C |
| I3 필드 소유권 | 필드마다 writer는 하나이고, 주기적 refresh는 자기가 소유한 필드만 교체함 | D |

D(browser lane 선택)는 durable truth가 아니라 client가 소유한 view state입니다. umbrella 불변식에 넣으면 헌법의 판단 기준이 흐려집니다.

## b. 런타임 레이어

- **공통 append-only journal에는 반대합니다.**
  - 기존 log와 별개의 두 번째 진실원이 되어, journal과 log 사이의 정합성 버그라는 새 클래스가 생깁니다.
  - retention과 compaction 비용이 들고, C와 D에는 효과가 없습니다.
  - speculative state 금지 조항에도 정면으로 어긋납니다.
- **정당화되는 구조적 수정은 있습니다.** transcript가 이미 log의 fold라면, A군에서 잃은 것들(correlation key, goal criterion, reasoning, retry observation)이 둘 중 어느 경우인지 확인해 보세요.
  - (i) log에는 있는데 rebuild fold가 읽지 않는 경우
  - (ii) live 경로가 log를 거치지 않고 state를 직접 mutate하는 경우

  (ii)라면 live 경로가 반드시 `apply : state -> event -> state`를 거치게 하고, rebuild는 `List.fold_left apply init events`로 만듭니다. 경로가 하나가 되면 이 클래스 자체가 사라지고, 테스트는 기존 transcript-fold 테스트를 확장하는 것으로 충분합니다. 추가 상태는 0이고 코드는 줄어듭니다.
- **비용이 거의 없는 컴파일 타임 장치(OCaml)도 있습니다.**
  - Resume, Start, replay, restore 같은 boundary 생성자에서는 `{ default with ... }`를 금지하고 전체 record literal을 쓰게 합니다. 그러면 필드를 추가할 때 모든 boundary에서 type error가 납니다. "운반할지 버릴지"를 강제로 결정하게 되고, 버리는 결정이 diff에 드러납니다. "intentionally"를 코드로 실체화하는 방법입니다.
  - projection이나 복사 함수는 `; _` 없는 record 패턴으로 씁니다. warning 9이고, dune dev 프로필 기본값에서는 error입니다. 프로젝트 flags가 이를 덮어쓰는지는 확인이 필요합니다.
  - lifecycle 전이 함수에서는 `| _ ->`를 금지하고, `Interrupted`와 `Ended`를 별도 생성자로 둡니다.
  - C군은 cleanup 반환형을 outcome과 분리하고, `combine : outcome -> cleanup_result -> outcome`에서 `Confirmed`가 항상 이기게 만듭니다. 그러면 덮어쓰기가 타입 수준에서 불가능해집니다.

## c. round-trip 의무가 놓치는 것

1. **트리거 문제가 가장 큽니다.** 의무는 boundary를 *바꿀 때* 발동하지만, 흔한 회귀 경로는 live 경로에 새 필드를 추가하는 것이고 이때 boundary 코드는 건드리지 않습니다. #45791이 이런 형태일 가능성이 높습니다.
2. **공허하게 통과할 수 있습니다.** projection이나 generator를 손으로 유지하면 새 필드가 거기서도 빠져, 같은 누락이 테스트로 옮겨갈 뿐입니다. derive로 만든 generator와 exhaustive projection(warning 9)이 필수입니다.
3. **작성자의 맹점이 테스트에도 그대로 들어갑니다.** expected 값을 사람이 명세하면 rebuild와 같은 착각을 하게 됩니다. oracle은 live 경로 자체여야 합니다. 같은 이벤트 열을 넣어 live state와 persist 후 rebuild한 state를 비교하는 차등 테스트가 그 형태입니다.
4. **동시성(C)을 못 잡습니다.** 순차적인 round-trip 테스트로는 lock-release 실패 경합을 볼 수 없습니다. qcheck-stm/qcheck-lin 모델 기반 테스트에 cleanup 경로 fault injection을 붙이고, flaky해지지 않도록 결정적 주입을 써야 합니다.
5. **프로세스 경계를 못 봅니다.** in-process 테스트로는 쓰기 도중 crash(torn write)나 실제 restart를 재현할 수 없습니다. D는 대시보드 쪽에서 테스트해야 합니다.
6. **의도적으로 손실이 있는 boundary가 있습니다.** context compaction, 큰 tool output의 truncation, TTL, redaction 같은 경우입니다. 그대로 두면 통째로 면제되면서 불변식이 침식되므로, boundary별 drop policy를 코드로 두어야 합니다.
7. **스트리밍 청크 경계는 rebuild가 아니라 framing 문제입니다.** `assemble (split_anywhere x) = x` 같은 split-invariance 속성이 맞는 형태입니다.
8. **성능과 볼륨은 실질적 문제가 아닙니다.** generator 크기에 상한을 두면 되고, log replay는 O(n)입니다. 진짜 볼륨 위험은 a에서 말한 lifetime 부재입니다.
9. **헌법과의 정합성 문제가 있습니다.** 의무를 "모든 boundary"에 걸면 실패와 무관한 테스트 금지 조항에 걸립니다. 29건에서 도출한 boundary 열거 목록으로 범위를 한정하면 테스트마다 실제 실패와 연결됩니다.

## d. 재분류

| 커밋 | 기존 | 재분류 | 이유 |
|---|---|---|---|
| #46327 | A | C/I2 | 실패한 turn을 처리하는 error 전이가 축적된 관측을 덮어씀 |
| #46132 | B | C/I2 | FSM이 interrupt를 terminal로 모델링함 |
| #46168 | B | A/I1 | restart는 가장 극단적인 rebuild이고, 원인은 선언이 durable하지 않았던 것 |
| #45950 | A | A + E | replay 손실(A)과 streaming 청크 framing(새 군 E), 두 버그가 섞여 있음 |

결과적으로 B는 독립된 메커니즘이 아니게 됩니다. A 4건, C 3건, D 1건, E 1건입니다.

더 중요한 것은 8건이 아니라 29건 전부를 분류하는 일입니다. A가 한 모듈(예: Keeper context rebuild)에 몰려 있다면, b의 단일 `apply` 리팩터가 RFC보다 효과가 큽니다. 또 "retain/preserve/keep" regex는 "lost/dropped after resume"류 커밋을 놓치고 UI의 "keep scroll"류를 잡으므로, 29는 하한도 상한도 아닙니다.

## e. 대안

1. **RFC는 짧게 쓰고, 규범 문구는 코드 옆에 둡니다.** RFC-0099가 위임한 typed contract(`tool_result.mli`, `keeper_gate_replay.mli`)와 boundary 모듈의 `.mli` doc에 넣으면 0099와 경쟁하지 않습니다. 내용은 I1/I2/I3, accepted 정의, lifetime 조항, boundary 열거 목록입니다.
2. **강제는 컴파일러, CI, 테스트 순서로 겁니다.** full record literal, warning 9, wildcard 금지가 먼저입니다. 그다음, 열거된 boundary 파일이나 record 타입을 바꾸는 PR은 대응 테스트 파일도 바뀌어야 통과하는 경로 기반 CI 체크를 둡니다.
3. **A가 몰린 도메인은 live 경로를 incremental fold로 일원화**하고 transcript-fold 테스트를 확장합니다.
4. **테스트는 메커니즘별로 맞춥니다.**
   - A: live와 rebuild를 비교하는 차등 테스트로, exhaustive projection 위의 등식과 명시적 drop list를 씁니다.
   - C: STM 모델 테스트에 fault injection을 붙입니다.
   - E: split-invariance 속성 테스트를 씁니다.
5. **sunset 조건을 둡니다.** 이후 fix 100건당 이 클래스의 비율을 추적하고, N개월 뒤에도 줄지 않으면 철회합니다. 헌법의 evidence 기준을 RFC 자신에게도 적용하는 것입니다.

**"per-site fix를 계속하는 것"이 최적인가: 아닙니다.**
- 이 클래스는 정의상 silent라서 발견이 늦습니다.
- 헌법이 최우선으로 보호하는 durable truth를 손상시킵니다.
- per-site fix가 하나 늘 때마다 다음 boundary가 운반해야 할 필드가 늘어납니다.
- PR 번호(~46k)가 보여 주는 개발 속도에서, 특히 에이전트가 쓴 커밋 비중이 높다면, 산문으로 된 의무는 금방 잊히지만 컴파일 에러는 그렇지 않습니다.

e-2의 컴파일 타임 장치는 비용이 거의 없으므로, 그것만으로도 아무것도 하지 않는 쪽보다 낫습니다.

[exited with code 0]
