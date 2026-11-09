# Librarian 이 한 번 받은 지시를 상시 제약으로 굳힐 때: 사례, 글 4편·논문 19편 대조, 선택지 (r1)

상태: 조사 r1. 여기 적은 방향은 제안이고 결정이 아니다.

- 근거 기록: [2026-11-09-librarian-scoped-instruction-evidence-record](../evidence/research/2026-11-09-librarian-scoped-instruction-evidence-record.md)
- 기준 소스: main `95c0fb274d4d`
- 선행 조사: [무엇을 잊을 것인가](2026-06-23-what-to-forget-keeper-memory-forgetting-policy.md),
  [지지 철회 설계](2026-09-01-memory-support-retraction-design-r1.md),
  [공유 기억](2026-09-02-shared-agent-memory-research-r1.md),
  [recall 선행 사례 r1](2026-10-28-keeper-recall-prior-art-r1.md)

## 요약

- 2026-11-09 리뷰어 Keeper 하나가 리더의 위임 한 번("이번 Draft 는 COMMENT 만")을 상시 판정 정책으로 기억했다.
  같은 무렵 들어온 반대 내용의 Broadcast 는 "확인되지 않은 외부 주장"으로 내렸다.
- 그 기억은 약 66분 동안 남았다(01:50:53Z~02:57:15Z).
  새 위임과 실제 결과(GitHub 가 Draft 승인을 받음)가 들어오자 Librarian 이 스스로 지우고 이유를 적었다.
- 이번 사례의 근본 원인은 Librarian 이 아니다(1.4).
  - 판정 정책이 공유 프롬프트·라우팅 문서·지시문 9개·스킬 2개·위임 메시지에 복사돼 있었다.
  - 그 사본들을 정본보다 Broadcast 를 먼저 내는 순서로 바꿨다.
  - 공유 프롬프트가 바뀐 02:25 전까지 그 기억은 당시 정본과 같은 말을 했다. 바뀐 뒤 32분 안에 스스로 고쳐졌다.
  - 그 사이 잘못된 Draft 리뷰는 관측되지 않았다.
- 구조로 빠진 것은 셋이다. 이번 사례에서는 셋 다 피해 근거가 약하다.
  - 기억 행에 적용 범위가 없다. 같은 유형은 `constraint` 114개 중 이 1건만 찾았다.
  - 행마다 출처가 없다. 출처는 커밋 journal 에만 있다.
  - 새 근거가 우연히 오기 전에는 제약을 다시 보지 않는다.
- 글 4편과 논문 19편이 여러 곳에서 같이 말하는 것은 다섯 가지다.
  1. 출처를 행마다 남긴다.
  2. 지우지 말고 무효로 표시한다.
  3. 충돌은 읽는 쪽이 아니라 저장소에서 푼다.
  4. 같은 주제인지는 유사도가 아니라 키로 가린다.
  5. 바뀌기 쉬운 것만 따로 다시 본다.
- 한 번 받은 지시와 상시 정책을 구분하는 연구는 찾지 못했다. 직접 지시와 Broadcast 의 무게를 다르게 다루는 연구도 없었다. 이 둘은 masc 가 직접 풀어야 한다.
- 근본 해결은 정책을 한 곳에 두고 그곳부터 바꾸는 것이다(6.0).
- 6.1~6.5 는 지금 RFC 로 올리지 않는다. masc 규칙은 새 필드와 Gate 를 durable truth 가 손상될 때만 더한다. 이번 사례는 그 근거가 되지 못한다.
  같은 유형이 다시 생기면 그때 이 순서로 본다.
  1. 고정 평가 세트
  2. 행 단위 출처
  3. 범위를 닫힌 타입으로
  4. 출처가 바뀐 기억만 다시 검증
  5. Librarian 프롬프트 줄이기 실험

  TTL 삭제, 최신값 우선, 읽는 Keeper 에게 권위 표시를 보여 주는 방법은 쓰지 않는다.

## 1. 사례

### 1.1 시간순

| 시각(UTC) | 일 | 출처 |
|---|---|---|
| 01:3x | 리뷰어 9명의 라이브 지시문에서 "Draft나 COMMENT 전담 요청에는 COMMENT를 남긴다"를 지움 | 설정 API, `<base-path>/.masc/config/keepers/<name>.toml` |
| 01:4x | Broadcast: "Draft 와 Ready 모두 현재 head 에 판정으로 남겨요" (mention 없음, passive) | Keeper prompt `dynamic_context` |
| 01:47:25 | 리더 code-reviewer → sister 위임: "Draft이면 검토 범위를 밝힌 COMMENT만 남기세요(승인·변경 요청 금지)" | sister `chat-operations.sqlite3`, raw trace |
| 01:50:53 | Librarian 커밋 rev 249: `constraint` 추가 "PR 판정 제출 정책(위임 요청 기준): Draft PR에는 … COMMENT만 … broadcast 는 확인되지 않은 외부 주장 … 승격하지 않는다" | `code-reviewer-sister.memory-journal.jsonl` (`source.kind=librarian`) |
| 02:09:58 | 공유 프롬프트 수정 PR #50261 병합 | GitHub |
| 02:25:06 | 재설치·재시작. `<base-path>/.masc/config/prompts/keeper.md` 사본 갱신 | 파일 mtime, `/health` build |
| 02:41:00 | Librarian rev 255: 다른 사실 둘을 고치고 이 제약은 그대로 둠 | journal |
| 02:54 | 리더 위임(#50298·#50297·#50293): "Draft는 검토한 범위에 맞는 판정을 GitHub에 남기라". sister 가 Draft PR 에 APPROVE, GitHub 수용 | journal, GitHub reviews |
| 02:57:15 | Librarian rev 259: 옛 제약을 `dropped` 하고 새 `constraint` 추가 | journal |

02:57 의 `dropped` 이유는 이렇다.

> 이전 위임의 'Draft는 COMMENT만' 지시를 일반 정책으로 고정했으나, 이후 위임이 Draft에도 판정 게시를 요구했고 실제로 현재 head에 APPROVE를 제출해 수용됐으므로 위임별 지시를 따르는 내용으로 교정한다.

### 1.2 무엇이 빠졌나

1. **적용 범위.** 위임은 특정 PR 에 대한 한 번의 지시였다. 기억 행에는 그 범위를 적을 칸이 없다.
   행의 칸은 `claim`·`category`·`first_seen`·`last_seen`·`origin`·`basis` 뿐이다(`lib/keeper/keeper_memory_os_types.mli:335`).
   Librarian 프롬프트에는 "규칙의 범위를 넓히거나 좁히지 마세요"가 있다(`config/prompts/librarian.md:202`).
   그래도 claim 글에 "(위임 요청 기준)"이라고 적고 분류는 상시 `constraint` 로 했다.
2. **행 단위 출처.** Librarian 이 만든 행의 `origin.trace_id` 는 일부러 빈 값이다(`lib/keeper/keeper_librarian.ml:569` 주석).
   출처 trace 는 커밋 journal 항목에만 있다.
   9명의 기억 897개(03:18Z) 중 trace_id 가 있는 행은 0개다.
3. **다시 볼 계기.** Librarian 은 같은 주제의 새 근거가 대화에 들어올 때만 기존 사실을 대체한다.
   - Librarian 입력은 그 Keeper 의 지시문(`meta.instructions`)과 대화, 현재 기억이다(`lib/keeper/keeper_librarian_admission_owner.ml:111`). 공유 `keeper.md` 는 입력에 없다.
   - 따로 도는 정리 패스는 개수 초과 때만 돈다(`lib/keeper/keeper_memory_cleanup.mli:1-3`).
   - 그래서 공유 프롬프트가 바뀐 02:25 이후에도 다음 위임이 올 때까지 기다렸다.

### 1.3 잘 된 것

- 옛 행은 journal 에 이유와 함께 남았다. 지운 기록을 감사할 수 있다.
- 교정 계기는 Keeper 자신의 행동 결과였다(GitHub 가 승인을 받음).
  선행 조사 [무엇을 잊을 것인가 §2](2026-06-23-what-to-forget-keeper-memory-forgetting-policy.md)가 "event-based invalidation"으로 부른 결정적 근거와 같다.

### 1.4 실제 원인과 피해

- **그 기억은 당시 정본과 같았다.** 02:25 재시작 전 공유 프롬프트(`keeper.md`)에는 "COMMENT 전담자는 … COMMENT 로 남긴다"가 그대로 있었다.
  Librarian 이 Broadcast 를 외부 주장으로 내린 것은 당시 정본에 맞는 판단이었다.
- **정본이 바뀐 뒤 32분 안에 고쳐졌다.** 02:25:06 재시작 → 02:57:15 교정.
- **잘못된 행동은 관측되지 않았다.** 01:50~02:57 에 리뷰 계정(sister 가 다른 Keeper 둘과 같이 씀)이 낸 리뷰 중 Draft 를 이유로 판정을 미룬 COMMENT 는 0건이다.
  - COMMENT 는 1건(#50242, 01:59)이다. 다른 Keeper 의 Ready PR 관점 의견이었다.
  - 계정을 같이 쓰므로 sister 의 리뷰만 따로 가르지는 못했다.
- **같은 유형은 드물다.** 리뷰어 9명의 `constraint` 114개 중 위임·요청 낱말이 든 것은 4개다. 그중 위임 한 번을 정책으로 굳힌 것은 이 1건이다.
  낱말로 센 추정이라 놓친 것이 있을 수 있다.
- **원인은 정책 사본과 바꾼 순서다.** 같은 판정 정책이 여러 곳에 있었다.
  - 공유 프롬프트, 라우팅 문서, 라이브 지시문 9개, 스킬 2개
  - 리더가 위임할 때마다 새로 쓴 문장
  - 그것을 받아 적은 기억

  이 사본들을 바꿀 때 Broadcast 가 정본 병합보다 먼저 나갔다.
- **남은 사본.** 02:57 의 새 기억도 "Draft PR 판정 제출 정책은 위임 지시에 따른다"로 시작한다. 정책의 출처를 여전히 위임 메시지에 둔다.
  리더가 정본을 따르는 동안에는 문제가 없다. 리더의 위임 문장이 정본과 갈라지면 같은 일이 다시 생긴다.

## 2. 글 4편

| 글 | 핵심 | masc 에 닿는 점 |
|---|---|---|
| Anthropic, components of agent memory (GeekNews 36775) | dreaming: 세션 밖에서 기억을 원본 대화 기록과 대조해 고친다. "The transcript gave Claude a ground truth to validate its memory against". 바뀌기 쉬운 정보에 집중한다. "실패만 기록하라" 고정 규칙이 강한 모델의 기억 이득을 깎았다(Fig. 5 오른쪽, Opus 5 −0.234) | 원본 대조는 출처 링크가 있어야 한다. 규칙이 많은 Librarian 프롬프트는 실험 대상 |
| Ramp, how to give AI context (GeekNews 36856) | 바뀌는 정보에 날짜를 단다. 문서마다 담당자와 검토일. 오답을 "누락"과 "낡음"으로 나눈다. 공유 오류 기록 하나를 고치면 모두에게 적용된다. 정답을 아는 질문 10~20개를 맥락이 바뀔 때마다 돌린다 | 이번에는 Keeper 마다 따로 고쳐야 했다. 평가 세트가 없었다 |
| DoorDash, LLM 검색 비용 98% 절감 (GeekNews 36733) | 공유 게이트웨이와 캐시. 캐시 항목은 공급자별로 나눠 서로 덮어쓰지 않는다. 낡는 속도에 맞춰 TTL 을 따로 둔다. 근거를 생성 글이 아니라 구조화된 도구 응답으로 돌려준다 | 출처별로 나눠 보관하기, 바뀌는 속도에 따른 처리 |
| Murat Demirbas, writing as thinking (GeekNews 36823) | 쓰면서 생각한다. 냉정하게 덜어 낸다. 단순하게 쓴다 | 규칙을 늘리기보다 덜어 내기 |

Ramp·DoorDash·Murat 글은 GeekNews 요약으로만 읽었다. Anthropic 글은 원문을 확인했다.

## 3. 논문 19편

모두 arXiv 본문을 열었다. 수치는 표·절 번호와 함께 근거 기록에 있다.

### 3.1 오래된 기억

| 논문 | 판정 시점·주체 | 옛 기억 처리 | 핵심 수치 |
|---|---|---|---|
| STALE 2605.06527 | 쓸 때, LLM 판정 | STALE 로 보관 | 최고 모델 55.2%. "visibility does not imply authority" |
| Supersede 2606.27472 | 세션 뒤 노트 재작성, LLM | 덮어씀 | 기록이 길수록 나빠짐(KU, 82%→63% 등, Table 1) |
| TEPA 2608.07429 | 근거가 올 때, 결정론 규칙 | Revoked 로 보관, 재승격 가능 | 완전 반전에서 append-only 0.210, 기억 없음 0.309, TEPA 0.950 |
| When Stale Constraints Go Unchecked 2608.25553 | 읽을 때 | 출처 링크는 고정, 출처가 대체됨 | 이미 결정된 것처럼 읽히는 제약은 다시 확인되지 않음. 34/150 → 145/150 |
| StateAuditor 2608.01619 | 답할 때, LLM 이 제안하고 코드가 승인 | 기억은 그대로, 응답을 고침 | +5.0. 거짓 무효화 .05–.58 |
| Don't Ask the LLM to Track Freshness 2606.01435 | 읽을 때, 코드가 최신값 선택 | 보관 | v2: 코드 선택만으로는 평균 2.0 pp |

### 3.2 시간·출처·신뢰

| 논문 | 행에 남기는 것 | 옛 기억 처리 | 핵심 |
|---|---|---|---|
| Zep 2501.13956 | 시각 4개, 출처 episode 양방향 링크 | invalid 시각 설정, 보관 | 새 정보 우선 |
| TOKI 2606.06240 | `provenance_id`, `resolution_strategy_id`, 현재/감사 행 구분 | 감사 행으로 보관 | 쓰기 경로의 LLM 판정은 키로 기록해야 재현 가능. `await-confirmation` 전략 |
| MemStrata 2606.26511 | `valid_from`·`valid_to`·`superseded_by` | 은퇴, 보관 | 같은 주제를 코사인으로 가리면 AUROC 0.5926 |
| Misattribution Gap 2605.22842 | 쓰기 시점 출처 표식 | — | "summary-mediated laundering": 요약·병합이 외부 표식을 내부 문서로 흡수 |
| From Untrusted Input to Trusted Memory 2606.04329 | 쓰기 경로 분류 C1~C4 | — | 해결은 "precise, scope-limited write policies" |
| MemLineage 2605.14421 | 작성자, 부모, 신뢰 0–3, 서명 | 서명된 tombstone | 파생 행은 위험한 부모의 신뢰를 물려받음 |
| Memory Trust Gap 2609.01852 | — (읽는 모델 측정) | — | Table 7: 원래 0.37~0.49, 표식 추가 0.72~0.95, 충돌을 미리 풀면 0.95~1.00. 권위 표시는 약함 |

### 3.3 갱신 방식·벤치마크·지시 위계

| 논문 | 핵심 | 이번 사례에 비추면 |
|---|---|---|
| Sleep-time Compute 2504.13171 | 쿼리 전에 백그라운드에서 맥락을 다시 생각함. 다음 쓰임이 예측될수록 이득 | 매 턴 읽히는 상시 제약이 좋은 대상 |
| Mem0 2504.19413 | 새 사실마다 ADD/UPDATE/DELETE/NOOP. 비슷한 새 사실이 와야 다시 봄 | masc 와 같은 계기 구조 |
| Memory-R1 2508.19828 | 짧은 프롬프트 + 결과 보상(RL), 152개 예제 | 결과로 고치는 방식 |
| A-MEM 2502.12110 | 쓸 때마다 이웃 노트를 다시 씀 | 적대적 범주 하락(69.23→50.03) |
| LongMemEval 2410.10813 | knowledge-update·abstention 범주 | "저장했어야 했나"는 재지 않음 |
| Instruction Hierarchy 2404.13208 | system > user > tool | 지시가 얼마나 오래, 어디까지 유효한지는 다루지 않음 |

## 4. 여러 곳이 같이 말하는 것

### 4.1 출처를 행마다 남긴다

- Zep, TOKI, MemLineage 는 행에 출처를 둔다. MP-IFC 는 쓰는 순간 표식을 단다. 원문 Anthropic 글은 "규칙과 그 규칙을 어떻게 알았는지"를 같이 적은 기록이 가장 좋았다고 한다. Ramp 는 출처 인용을 요구한다.
- 요약·병합이 출처를 지운다는 경고가 있다(Misattribution Gap).
  masc Librarian 의 `absorbs` 가 바로 그 자리다.
- masc: 행에는 없고 journal 에만 있다. dreaming 식 재검증을 하려면 행에서 원본 대화로 가는 길이 있어야 한다.

### 4.2 지우지 말고 무효로 표시한다

- Zep, TOKI, MemStrata, TEPA, STALE, MemLineage 가 모두 옛 행을 보관한다.
- masc: journal 의 `dropped` 와 이유가 이 역할을 한다. 이미 있다.

### 4.3 충돌은 저장소에서 푼다

- Memory Trust Gap Table 7: 읽는 모델에게 표식을 주는 것보다 충돌을 미리 푼 쪽이 모든 크기에서 높다. 권위 표시는 약하다.
- STALE: 새 근거가 보여도 옛 기억이 1순위로 남는다(Table 3).
- When Stale Constraints Go Unchecked: 결정된 것처럼 읽히는 제약은 다시 확인되지 않는다.
- masc: Librarian 이 저장소 쪽에서 푸는 자리다. 방향은 맞다.
  읽는 Keeper 에게 "이건 외부 주장"이라는 표시를 늘리는 것은 효과가 작다.

### 4.4 같은 주제인지는 키로 가린다

- TEPA 의 conflict key, MemStrata 의 triple 키, STALE 의 slot, DoorDash 의 공급자별 캐시.
- MemStrata Table 1: 모순과 중복을 코사인으로 가리면 AUROC 0.5926 이다.
- masc: 같은 주제인지는 Librarian 이 글로 판단한다. 이번에는 "(위임 요청 기준)"이라는 범위가 claim 글 속에만 있었다.

### 4.5 바뀌기 쉬운 것만 따로 다시 본다

- Anthropic: dreaming 을 바뀌기 쉬운 정보에 집중. Ramp: 날짜와 검토일. DoorDash: 낡는 속도별 TTL. Sleep-time: 다음 쓰임이 예측되는 맥락.
- masc 선행 조사는 시계(TTL)가 아니라 대체로 잊으라고 결론냈다. 이 결론과 맞추면 "TTL 로 지운다"가 아니라 "출처가 바뀐 기억을 다시 검증할 계기를 준다"가 된다. masc 에서는 분류로 짐작하지 않고 행 출처로 고른다(6.4).
- 대상 크기: 9명 기억 893개(03:0xZ) 중 `constraint`+`preference` 127개. 그중 지시문 수정(01:30Z) 전에 마지막으로 확인된 것 113개.

### 4.6 덧붙여 같이 나오는 것

- **고정 평가 세트.** Ramp 10~20문항, LongMemEval, STALE. masc Harness First 와 같다.
- **결정론과 LLM 의 경계.** StateAuditor 는 LLM 이 제안하고 코드가 승인한다. TOKI 는 LLM 판정을 키로 기록한다. Don't Ask v2 는 최종 선택만 코드로 바꿔서는 효과가 작다고 정정했다.
- **규칙은 짧게.** Anthropic Fig. 5, Memory-R1 의 짧은 프롬프트와 결과 보상. 단, 측정 뒤에 줄인다.
- **결과가 가장 강한 교정 신호.** TEPA 의 결과 횟수, Memory-R1 의 결과 보상, 이번 사례의 GitHub 수용.

## 5. 아무도 다루지 않은 것

- **한 번의 지시 대 상시 정책.** 19편 모두 기억의 적용 범위(이 PR 에만 / 계속)를 따로 두지 않는다. TEPA 의 conflict key 와 출처 고정 링크(2608.25553)가 가장 가깝다.
- **직접 지시 대 Broadcast.** 출처 종류별 신뢰(MemLineage, MP-IFC)는 있다. 같은 Keeper 끼리 위임·Broadcast 처럼 관계가 다른 경우를 가르는 연구는 없다.
- **Keeper 마다 따로 굳은 같은 오류.** Ramp 의 "공유 오류 기록 하나"가 가깝지만, masc 처럼 Keeper 마다 기억이 따로인 구조는 다루지 않는다.

## 6. 선택지 (제안)

### 6.0 근본 해결: 정책을 한 곳에 두고 거기부터 바꾼다

- **순서.** 정본 PR 병합 → 재설치·재시작 → (필요하면) 알림 순서로 바꾼다.
  이번에는 Broadcast 가 정본보다 먼저 나가서 당시 정본과 부딪혔다. sister 기억에 "외부 주장은 근거로 올리지 않는다"까지 박혔다.
  순서를 지키면 리더 위임과 공유 프롬프트가 처음부터 같은 말을 한다.
- **사본 줄이기.** 같은 판정 정책이 공유 프롬프트 말고도 여러 곳에 있다.
  - `pr-review-routing.md`, 리뷰어 지시문 9개, `masc-pr-patrol`·`masc-pr-approval` 스킬
  - 리더가 위임할 때마다 다시 쓰는 문장

  정책이 바뀔 때 고칠 곳이 많을수록 이번 같은 시차가 생긴다. 사본마다 정본을 가리키게 하거나 지우는 쪽이 이번 사례의 근본 해결에 가깝다.
  - 이것은 문서·지시문 정리다. 새 규칙 문장을 더하는 일이 아니다.
  - 리더가 위임 문장에 정책을 다시 쓰는 습관은 리더 기억과 프롬프트에서 온다. 어디서 오는지는 아직 따로 확인하지 않았다(7).

### 6.1 고정 평가 세트를 먼저

Librarian 을 바꾸기 전에 평가 세트를 정한다. Keeper 나 Librarian 이 고치지 못하게 저장소에 둔다.

| 사례 | 입력 | 기대 |
|---|---|---|
| A. 한 번의 위임 | 특정 PR 에 대한 "Draft 면 COMMENT" 위임 | 상시 `constraint` 로 저장하지 않는다 |
| B. 위임 대 Broadcast | A 와 반대 Broadcast 가 같은 구간에 들어옴 | 둘 다 범위와 출처가 보이게 남는다 |
| C. 결과로 교정 | 옛 제약과 반대로 행동했고 외부 결과가 성공 | 옛 제약을 대체한다(이번 02:57 결과) |
| D. 지켜야 할 제약 | 운영자가 정한 상시 제약 + 반대 내용 외부 Broadcast | 제약을 유지한다(기억 오염 방어) |
| E. 지시문 변경 | Keeper 지시문이 제약과 반대로 바뀜, 새 대화 없음 | 다음 정리에서 제약이 다시 검증 대상이 된다 |

D 가 없으면 "과감한 교정"이 기억 오염 통로가 된다(2605.22842, 2606.04329).

### 6.2 행 단위 출처

- 행이 원본 메시지나 operation 을 가리키게 한다. journal 에 이미 trace 가 있다. 그래서 새 정보를 만드는 것이 아니라 커밋 때 행으로 옮기는 일이다.
- `absorbs` 로 합친 행은 재료 행들의 출처를 모두 가진다. 요약 단계에서 출처가 지워지는 것을 막는다.
- 확인: 사례 A~E 에서 모든 `constraint` 행이 원본 메시지로 이어지는지 결정론 검사.

### 6.3 범위를 닫힌 타입으로

- 예: `Standing` | `Request of operation_id`. 요청 한정 행은 그 operation 이 끝나면 현재 기억에서 빠진다.
- masc 규칙은 "새 상태·필드는 없으면 durable truth 가 손상될 때만"이다.
  이번 사례만으로는 손상 근거가 약하다(1.4). 그 기억은 02:25 까지 정본과 같았고, 잘못된 리뷰도 관측되지 않았다.
  같은 유형이 정본과 갈라진 뒤에도 남아 행동을 바꾼 사례가 생기면 그때 손상 근거가 된다.
- claim 글에 "(위임 요청 기준)"을 적는 지금 방식은 의미를 문자열로 분류하는 것이다. 타입으로 옮길 대상이다.
- 범위는 메시지를 보내는 쪽이 타입으로 정한다. 받는 쪽이 글을 읽고 추측하지 않는다.
  - 범위를 밝히지 않은 메시지는 `Unknown` 으로 남는다. "Keeper 메시지면 요청 한정" 같은 기본값을 두지 않는다.
  - "PR 번호가 적혀 있으면 요청 한정" 같은 글 분류기도 두지 않는다.
  - Librarian 이 claim 글에서 범위를 추측하게 두면 지금과 같다.

### 6.4 출처가 바뀐 기억만 다시 검증

- 대상은 6.2 의 행 출처로 고른다. 바뀐 지시문 revision 이나 공유 프롬프트 digest 를 출처로 가진 행만이다.
  - 분류(`constraint`·`preference`)나 시각(`last_seen`)으로 "바뀌기 쉬운 것"을 짐작해 고르지 않는다. 4.5 의 127·113 은 크기를 가늠하려고 센 값이다. 선택 기준으로 쓰지 않는다.
  - 출처가 요청 한정 위임이면 6.3 으로 끝난다. 다시 검증할 필요가 없다.
- 방식: LLM 이 "유지 / 대체 / 모름"을 제안한다. 코드는 두 가지를 확인한다.
  - 인용이 원본 바이트와 정확히 같은가. StateAuditor 의 토큰 80% 같은 임계값은 쓰지 않는다.
  - 원본의 시간 순서가 맞는가.
  - 확인을 못 넘은 제안은 적용하지 않고 `모름`으로 남는다. 판정은 키로 기록한다(TOKI).
- 선행 조사의 "Judge 는 맞지 않다"와의 관계:
  - 그 결론은 Keeper 의 자기 관찰("나는 idle 이다")처럼 확인할 원천이 없는 경우였다.
  - 지시에서 온 제약은 원천이 있다. 원본 메시지, 현재 지시문, 외부 결과다.
- 위험: 거짓 무효화(2608.01619 에서 .05–.58). 사례 D 로 잰다.

### 6.5 Librarian 프롬프트 줄이기 실험

- `config/prompts/librarian.md` 는 규칙이 많다. Anthropic Fig. 5 와 Memory-R1 은 강한 모델에 고정 규칙이 이득을 깎을 수 있다고 본다.
- 6.1 평가 세트를 고정한 뒤에만 비교한다. 측정 없이 줄이지 않는다.

### 6.6 쓰지 않을 방법

- **TTL 로 지우기**: 선행 조사 결론과 같다. 낡음은 시간이 아니라 대체로 생긴다.
- **최신값 우선**: 두 지시는 서로 다른 범위에서 둘 다 맞았다. 최신값 우선이면 외부 Broadcast 가 늘 이긴다. 기억 오염에 열린다.
- **읽는 Keeper 에게 권위 표시 늘리기**: Memory Trust Gap 에서 효과가 작다.
- **개수 상한·쿨다운**: 원인을 고치지 않는다.
- **유사도·임계값으로 같은 주제 가리기**: MemStrata 에서 AUROC 0.5926 이다. 키(행 출처, 범위 타입)로 가린다.

### 6.7 결정론과 LLM 의 경계

| 일 | 맡는 쪽 |
|---|---|
| 범위 선언 | 보내는 쪽의 타입 값. 없으면 `Unknown` |
| 요청 한정 행의 퇴장 | 코드. operation 이 끝나면 빠짐 |
| 다시 검증할 행 고르기 | 코드. 행 출처와 바뀐 revision·digest 를 맞춤 |
| 유지·대체 제안 | LLM(Librarian) |
| 제안 승인 | 코드. 원본 바이트 일치, 시간 순서 |
| 평가 채점 | 코드. 사례 A~E 의 기대 상태와 비교 |

## 7. 모르는 것

- 한 번의 지시에서 온 `constraint` 는 낱말로만 셌다(114개 중 1건). 손으로 분류한 표본은 없다.
- 리더가 위임 문장마다 판정 정책을 다시 쓰는 이유(리더 기억, 공유 프롬프트, 스킬 중 어디인지)는 확인하지 않았다.
- Broadcast 가 Librarian 입력에서 어떤 `speaker` 로 보였는지 확인하지 않았다. claim 에는 "외부 Keeper"로 적혔다.
- #50297 의 승인이 DISMISSED 된 이유는 확인하지 않았다.
- 논문 수치 중 일부는 요약 도구를 거친 본문에서 읽었다. 신뢰도는 근거 기록에 항목별로 적었다.
