⚠ claude.ai connectors are disabled because ANTHROPIC_API_KEY or another auth source is set and takes precedence over your claude.ai login · Unset it to load your organization's connectors
[claude-code:unrecognized_model] {"model":"glm-5.3[1m]","query_source":"sdk"}
로컬에 masc checkout은 없음(/private/tmp에는 관련 없는 파일뿐) — 제시된 증거만으로 판정한다.

## 결론

방향은 맞고, 제안된 수단이 틀렸다. "범용 retention runtime layer는 안 된다"(1번)는 유지 가능. 그러나 (i) 제안된 invariant는 boundary를 축으로 삼는 순간 **path-relative**가 되어 — 새 boundary path마다 증명 의무가 재발생하고, 그게 정확히 이 버그 클래스가 재발하는 방식이다. log를 축으로 잡으면 path-absolute가 된다: *"accepted ⟺ log에 기록됨, rehydrated ⟺ fold(log)"*. (ii) 이 invariant는 새로 만들 것이 아니라 이미 pin된 "transcript = fold(log)"의 따름정리로, **기존 property test의 적용 범위를 rehydration 경로로 확장**하는 편이 낫다. 병렬 invariant를 하나 더 두면 귀퉁이 케이스에서 서로 어긋났을 때 invariant 자체를 디버깅하게 된다. (iii) 2번 주장("29건 각각이 개별적으로 정확했다")은 검증되지 않았고 아마 절반만 참 — 개별 correct와 집합적 cruft는 양립한다. 29개의 per-site fix가 각자 자기 필드를 자기 path에 pin했다면, verdict가 "메커니즘이 heterogeneous하다"는 근거로 드는 이질성 자체가 per-site 수정 역사의 산물일 수 있다. 도메인의 성질이 아니라.

## a. Invariant — wrong axis

- **범위가 자기 증거를 못 덮는다.** 아래 (d)에서 보듯 C(#46169)와 D(#46098)는 "boundary에서 손실"이 아니다. 진짜 커버되는 건 A+B 6건. 반만 커버하는 invariant를 pin하면, 커버 안 되는 절반의 버그는 계속 나는데 RFC 인용 근거만 생긴다.
- **prose와 test formulation이 다르다.** prose에는 "intentionally ends it" escape hatch가 있고 test(`rebuild ⊇ accepted`)에는 없다. 매 lossy boundary(compaction, redaction, token budget)가 의도를 주장하면 escape hatch가 규칙을 삼킨다. RFC는 *test formulation이 invariant이고 prose는 motivation*이라고 못 박아야 한다. #45950이 정확히 이 사례다 — truncation 자체는 예산상 의도적이었 수 있고, 버그는 live path와 replay의 truncation이 *불일치*한 것이었다. invariant는 "존재"만 검사하고 "일치"는 검사하지 못한다.
- **A와 B는 log-level invariant로 통합된다.** Group B를 보라: #46168(선언된 guest가 restart에서 소실)은 declaration이 메모리에만 존재한 durability 버그다. "accept는 log write 선행(write-before-accept)"이면 B는 A와 같은 invariant로 흡수된다. boundary 관점에서는 둘이 달라 보이지만, log 관점에서는 같은 위반이다.

## b. "Runtime layer 금지" — 결론은 맞지만 이유 수정 필요

새 observation journal을 만들 필요가 없다. **journal은 이미 있다 — 그게 log다.** Group A의 근본 원인은 (i) live path가 log를 우회하는 shadow state를 축적하고, (ii) rebuild path가 N개라는 것. 헌법은 여기서 구조 변경을 *막는* 게 아니라 오히려 요구한다 — "durable truth가 손상될 때만"이 유일한 신규 구조 트리거인데, 500 commit 동안 전체 fix의 ~14%가 같은 손상의 재발생이라는 실측이 이미 있다. 헌법-compatible한 싼 구조 수정 셋:

1. **rehydration 단일 진입점.** RFC-0099가 `lib/keeper/keeper_gate_replay.mli`를 이미 가리키므로 이것은 추가가 아니라 확장이다. Resume/Start/replay/tool-reply가 각자 re-derivation을 굴리는 한, equivalence test는 path 개수만큼 필요하고 각각 잘못 쓸 수 있다. path가 하나면 새 boundary *type*은 그 하나를 확장할 수밖에 없다.
2. **`observation`을 closed variant로.** OCaml에서 non-exhaustive match를 error로 틀면, 새 observation 종류가 추가될 때 rehydrate가 빌드에서 깨진다. 이게 이 repo에서 쓸 수 있는 가장 싼 retention 메커니즘이다 — runtime layer도, 새 state도, 테스트 부담도 없음. #45853(correlation key), #45791(Goal criterion) 모두 "open 직렬화 표면 + closed rebuild 표면"의 불일치로 보인다.
3. **write-before-accept.** acceptance를 "log에 썼음"으로 정의. streaming reasoning chunk처럼 동기 write가 안 되는 것은 acceptance 지점을 명시적으로 정의(in-flight vs accepted)하면 된다 — 이 결정 자체가 RFC가 해야 할 일이다.

## c. Round-trip test 의무가 놓치는 것

- **관계가 틀림:** `⊇`는 집합 존재만 검사. 순서, 파생 상태, last-write-wins, truncation 위치를 못 잡는다. #46169는 rebuild 경로 자체가 없어 적용 불가.
- **순환 오라클:** "accepted"의 oracle을 피테스트 대상 코드의 accept 함수에서 도출하면 circular — 생산 코드가 *일관되게* 누락시키면 통과한다. oracle은 log 기반이어야 한다(위 3번과 연결).
- **입력 절단 함정:** property test가 속도 때문에 observation stream을 자르면(예: 50개만), 그 절단 지점이 정확히 버그가 사는 곳이다. 긴 세션에서만 발견되는 loss(#45950류)를 테스트의 전제로 갖게 된다.
- **crash window 비결정성:** group B 테스트는 "accepted지만 아직 log에 못 쓴 것"의 취급을 요구한다. 비동기 write면 timing-dependent flaky test, write-ahead면 결정적. 이 문제가 계속 write-ahead를 가리키는 것은 신호다.
- **의무 트리거의 사각:** 트리거가 "boundary path 추가/변경"인데, 실제 재발 시나리오의 하나는 *새 observation type 추가*로 기존 path가 조용히 못 담는 경우 — 아무 path도 "변경"되지 않았으므로 발화 안 됨. 역시 타입 축 트리거(2번)가 답.
- **집행 없는 의무는 첫 deadline 주에 죽는다.** review 경계는 메커니즘이 아니다. 최소한 "rehydrate 모듈/observation variant가 바뀌면 대응 test 파일도 바뀌어야 함"을 path-based CI check로 — 29건의 실측 실패에 연결되어 있으므로 헌법의 "실제 실패와 무관한 heuristic check 금지"에도 걸리지 않는다.

## d. 재분류

- **#46169 (C): 이 클래스에서 제외.** FSM transition / last-writer-wins 버그다. boundary 통과가 없고, round-trip test로 잡을 수 없다. "retain/preserve"라는 commit 문구가 분류기를 속였다. 별도의 invariant를 원한다면 `confirmed ⊑ next`(key별 상태 단조 전진)이지 retention이 아니다.
- **#46098 (D): 보류.** periodic refresh는 context-rebuild가 아니라 동시 쓰기 병합 문제다. 진짜 규칙은 "전체 교체 금지, writer가 소유하지 않은 필드 보존"이라는 write discipline이고, invariant는 "boundary"라는 단어를 그만큼 늘리면 모든 write를 뜻하게 된다 — 그때는 불가능해진다.
- 8건 중 2건 오분류면 29건 집계도 같은 오차를 가진다(commit message 패턴 매칭은 약한 분류기). **RFC 초안 전에 재분류부터.** 14%라는 숫자도 오차막대 없이 인용하지 말 것.

## e. Counter-proposal (doing nothing은 아님)

500 commit, 4개(재분류 후 2+) 메커니즘, 전체 fix의 두 자릿수 % 재발률은 per-site 수정이 최선인 구간을 지났다. 다만 가장 싼 지렛대는 "새 invariant + N개 equivalence test"가 아니라 **컴파일러 + 공유 path 하나**다:

1. 29건 재분류(엄격 정의: "소스에 이미 있던 사실을 state 재구성 경로가 못 담은 경우"만).
2. rehydration 단일 진입점으로 수렴(`keeper_gate_replay` 확장) + `observation` closed variant + write-before-accept.
3. 기존 transcript-fold property test를 rehydrate에까지 확장. 새 invariant를 만들지 말고 — 새 invariant는 이제 따름정리라서 테스트도 기존 것에 포함된다.
4. 의무는 두 트리거로 기계화: rehydrate 모듈/variant 변경 시 test 동반(path CI check), lossy boundary는 명시적 negative list로 면책 선언(의도는 발견되는 게 아니라 audit되는 것).

한 줄 요약: verdict의 1번은 유지, 3번은 유지하되 원인 진단을 고칠 것 — 문제는 "증명 의무가 없어서"가 아니라 "증명해야 할 path가 N개라서"다. path를 1로 만들면 의무 대부분은 컴파일러가 대신한다.

[exited with code 0]
