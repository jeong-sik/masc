# 거짓 컨텍스트 탈출 루프 — 런타임 PoC 1차 보고서

- 날짜(ISO8601): `2026-08-30T11:50:01+09:00`
- 작성자: `Codex`
- 결정 ID: `context-recovery-r1`
- 적용 대상: `MASC_BASE_PATH=~/me` 의 `.masc`, `~/me/workspace/yousleepwhen/masc`
- 결정 상태: `추적 필요`
- 런타임 바이너리 소스 HEAD: `b4e0f6073909b2f84f71f15957b9368e077cdbb9`
  (`HEAD..origin/main = 0`)
- 수집 worktree: 하네스·케이스가 아직 commit 전 diff였다. 이 보고서를
  싣는 후속 commit이 그 diff를 보존한다. 따라서 이 자료는 exact binary
  source 증거이지만 exact committed harness 증거는 아니다.
- 실측 요약: `benchmarks/context_recovery/results/20260830-r1/summary.json`

## 결론

이번 라운드에서 production prompt 변경은 남기지 않았다. 경고 문구와
한 turn짜리 최신 note는 qwen3:8b의 결과를 바꾸지 못했다. 두 방식은
폐기한다.

오래된 fact를 모델에게 보여주기 전에 제거하고, live probe 결과로
revision 2를 발행하는 방식은 저장·철회·주입 경계까지 작동했다.
qwen3:8b는 그 뒤에도 엉뚱한 파일을 고쳤고, Qwen3.8-27B는 통과했다.
따라서 현재 확인된 문제는 둘이다.

1. Memory OS에는 source와 재검증 계약이 없어 오래된 claim을 스스로
   가려낼 수 없다.
2. 작은 모델의 파일 도구 실행 실패는 memory correctness와 별도로
   측정해야 한다.

표본은 모두 `n=1`이며 효과 크기를 주장할 수 없다. 이 보고서는
방향을 고르는 탐색 결과다.

## 근거 (Evidence)

### 최신 외부 근거

- 항목: [근거] 검색된 과거 문맥과 지금 참인 상태는 다른 문제다. Lemmalog는
  근거 경로, 철회, 시간 구간을 유지하고 전제가 사라질 때 파생 결론을
  갱신한다.
  - 출처: [GeekNews 원문 요약](https://news.hada.io/topic?id=33015),
    [원저자 글](https://pwning.systems/posts/llm-memory-program-analysis/),
    [Lemmalog 저장소](https://github.com/JordyZomer/lemmalog)
  - 확인일시: `2026-08-30T11:50:01+09:00`
  - 신뢰도: `High`
  - 제한조건: 저자의 LongMemEval/LoCoMo 결과는 실제 MASC coding turn의
    성능을 직접 보장하지 않는다.

- 항목: [근거] STALE은 state resolution, premise resistance, implicit policy
  adaptation을 분리해 측정한다. 최고 평가 모델도 전체 정확도 55.2%에
  그쳤다.
  - 출처: [STALE 논문](https://arxiv.org/abs/2605.06527)
  - 확인일시: `2026-08-30T11:50:01+09:00`
  - 신뢰도: `High`
  - 제한조건: 개인화 memory benchmark이며 coding workspace와 분포가
    다르다.

- 항목: [근거] draft만 검사하면 말하지 않은 오래된 의존성을 놓친다.
  StateAuditor는 저장 상태에서 draft 방향으로 검사하고, 인용 근거와
  시간 순서를 코드로 확인한 transition만 repair에 사용한다.
  - 출처: [StateAuditor 논문](https://arxiv.org/abs/2608.01619)
  - 확인일시: `2026-08-30T11:50:01+09:00`
  - 신뢰도: `High`
  - 제한조건: 논문도 general-purpose agent memory를 해결했다고 주장하지
    않는다.

- 항목: [근거] 시간 지식 그래프는 새 사실을 즉시 갱신하고, 질문에 필요한
  작은 evidence subgraph만 LLM에 전달하는 방향을 검증했다.
  - 출처: [CIK-LLM, PMLR 2025](https://proceedings.mlr.press/v274/maio25a.html)
  - 확인일시: `2026-08-30T11:50:01+09:00`
  - 신뢰도: `High`
  - 제한조건: temporal KG QA 결과이며 MASC의 source binding 설계는
    별도 검증이 필요하다.

### 현재 코드 근거

- `keeper_memory_os_types.fact`에는 `claim`, `category`, `first_seen`만
  있다. source, validity interval, dependency는 없다.
- recall은 current snapshot의 모든 fact를 저장 순서대로 주입한다.
- append-only memory journal은 이미 있다. 따라서 다음 구현은 새 원장을
  만들기보다 source-bound refresh가 만든 `removed/added` delta를 기존
  journal에 남기는 편이 작다.
- 격리 서버에서 `MASC_CONFIG_DIR`를 설정하면 Memory OS의 keepers dir도
  `<MASC_CONFIG_DIR>/keepers`로 바뀐다. 첫 두 dry run은
  `<target>/.masc/keepers`에 valid-but-unread shadow snapshot을 써서
  무효였다. 하네스는 resolver와 같은 경로로 고쳤다.

## 검증 (Verification)

### 시나리오

세 케이스는 STALE의 세 축을 작은 coding workspace로 옮겼다.

| 케이스 | 오래된 claim | live source | workspace 판정 |
|---|---|---|---|
| state resolution | region=`us-west-1` | `service.toml`: `ap-northeast-2` | `current_region.txt`가 live 값과 같은가 |
| premise resistance | retry_limit=`9` | `retry.toml`: `4` | `status.json`이 live 값과 같은가 |
| policy adaptation | locale=`en-US` | `account.json`: `ko-KR` | locale 변경을 호출 때마다 반영하는가 |

`verify.sh`의 exit code만 pass 권위로 사용했다. 모델 judge는 쓰지 않았다.
`last-prompt.json`에 stale/live claim이 실제 들어갔는지도 별도로 확인했다.

### PoC 결과

| PoC | 모델 | 결과 | 판정 |
|---|---|---:|---|
| 기존 stale recall | qwen3:8b | 0/3, 완료 2, provider error 1 | state 결과가 `us-west-1` |
| recall 경고 문구 | qwen3:8b | 0/3, 완료 2, provider error 1 | 기준선과 동일, 폐기 |
| stale recall + 뒤쪽 operator note | qwen3:8b | 0/3, 완료 2, provider error 1 | prompt 순서는 맞지만 행동 변화 없음, 폐기 |
| revision 1 철회 + revision 2 live refresh | qwen3:8b | 0/1 | stale 0건, live 1건; 엉뚱한 파일 수정 |
| memory off 대조군 | Qwen3.8-27B | 1/1 | 작업 능력 확인 |
| stale recall | Qwen3.8-27B | state 1/1, premise 1/1 | 이 표본에서는 이미 저항함 |
| revision 2 live refresh | Qwen3.8-27B | 1/1 | 저장 경계와 작업 결과 모두 통과 |

prompt-warning, operator-note, seeded baseline의 report JSON hash가 같은
이유는 세 보고서의 집계값이 모두 같기 때문이다. 실제 prompt 차이는
각 `last-prompt.json` hash와 block 목록으로 구분했다. 정확한 값은
machine-readable summary에 있다.

### 실행 명령

```bash
scripts/dune-local.sh build \
  ./test/test_coding_eval_cases.exe \
  ./test/coding_eval_report_cli.exe \
  ./bin/main_eio.exe

CODING_EVAL_SKIP_BUILD=1 scripts/harness_coding_eval.sh \
  --models ollama:qwen3:8b \
  --case-ids l1-context-state-resolution,l1-context-premise-resistance,l2-context-policy-adaptation \
  --memory-mode filtered --repeats 1 --port 9482 \
  --out /private/tmp/masc-context-recovery-20260830/qwen8b-state-filtered

CODING_EVAL_SKIP_BUILD=1 scripts/harness_coding_eval.sh \
  --models ollama:hf.co/unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_XL \
  --case-ids l1-context-state-resolution \
  --memory-mode filtered --repeats 1 --port 9483 \
  --out /private/tmp/masc-context-recovery-20260830/qwen27b-state-filtered
```

### 재현 결과

- 1차: 공식 글·논문에서 철회, 시간, state-anchored 검사 축을 확인했다.
- 2차: source HEAD와 binary sha256을 고정했다.
- 3차: 포트 9471–9483의 격리 서버를 반복 기동·종료했다.
- 종료 확인: 9471–9483 listen process 0개. 운영 8935는 계속 `status=ok`,
  `effective_base_path=/Users/dancer/me`,
  `effective_masc_root=/Users/dancer/me/.masc`였다.
- 구조 검증: coding corpus 17 tests, Memory OS focused 22 tests 통과.
  이 테스트는 runtime 결과의 대체 근거로 사용하지 않았다.

## 불확실성 (Uncertainty)

- 미확인 항목: 각 조건 `n>=5`, 다른 provider/model family, 실제 장시간
  Keeper memory에서의 implicit dependency.
- 영향: 현재 1/1 통과를 일반 성능 향상으로 오판할 수 있다.
- 추가 확인 필요:
  1. tool use를 제거한 answer-only STALE 축으로 memory 판단만 격리한다.
  2. `fact`에 무제한 provenance 문자열을 넣지 말고, 닫힌 source kind와
     재검증 가능한 locator 계약을 설계한다.
  3. source가 바뀐 fact만 turn 전 refresh하고, 기존 journal에 철회 사유를
     남기는 production slice를 별도 PR로 만든다.
  4. 같은 케이스를 모델별 `n>=5`로 다시 돌린다.

## 적용범위 (Scope)

- 영향 받는 영역: coding eval harness, 세 context-recovery case, 실측
  결과 문서.
- 제약/배제: 현재 Memory OS production schema와 recall 문구는 바꾸지
  않는다. provider fallback 오류도 이 PR에서 고치지 않는다.
- 롤백 조건: case의 stale claim이 `last-prompt`에 없거나 filtered mode의
  revision 2가 stale claim을 남기면 해당 run 전체를 무효로 본다.

## Delta

이전에는 “오래된 memory가 문제”라는 서술만 있었다. 이제 MASC exact
runtime에서 prompt-only와 note-only가 실패했고, pre-prompt 철회·refresh는
저장 경계에서 성공했지만 작은 모델의 tool execution은 별도 병목이라는
실측 정보가 생겼다.
