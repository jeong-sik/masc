# RFC-0339: Librarian memory — observable health and real retention

- Status: Draft
- Author: Claude (38-bug campaign, cluster C11 — bug #31)
- Date: 2026-07-10
- Related: RFC-0244 (Memory OS Tier 2 consolidation), 38버그 캠페인 진단 wf_8d9b2f7d (2026-07-10 아침, file:line 실측)

## 원문 (#31)

> "라이브러리안이 Memory를 어떻게 올바르게 관리하는지 의심됩니다. 해당 로그는 어디에 있고
> 어떤 활동을 하고 건강 상태는 어떤지 알 길이 없어요. 개선 부탁합니다."

요구는 두 겹이다: (a) **관측성** — 로그 위치/활동/건강 표면, (b) **의심의 해소** — 실제로
올바르게 관리하는가. 캠페인 진단이 (b)에 답했다: **의심이 맞다.**

## 실측된 문제 (2026-07-10 진단, main 기준 파일 실재 재확인)

1. **Ingest silent-zero**: `chronicle_ingest.ml`의 `run_git_output`이 비정상 종료·시그널·
   타임아웃을 전부 `None`으로 붕괴 — "새 기억 0개"가 정상 완료와 구분 불가. 운영자는
   librarian이 일하는지 죽었는지 알 수 없다 (#31의 직접 원인).
2. **FORGET 미구현**: `chronicle_librarian.ml`은 append-only 무한 리스트. forget 경로가
   코드에 존재하지 않는다 (rg 0건). 스펙이 약속한 retain/forget 수명주기의 절반이 없음.
3. **사문 가중치**: frequency 가중치 0.3이 항상 0.0과 곱해져 무효 — 코드가 자신이
   계산하지 않는 값에 가중치를 부여.
4. **수치 휴리스틱 판단**: retain 판정이 `cognitive_gravity.ml`의 tau=86400 지수 감쇠 —
   워크스페이스 원칙("판단 결정은 수치 휴리스틱이 아니라 LLM 경계로")과 정면 충돌.
5. **임베딩/벡터 인덱스 미구현**: recall 품질의 스펙 전제가 빠져 있음.

종합: 스펙 대비 사실상 스텁. 부분 패치(N-of-M)로는 워크어라운드 누적이므로 RFC로 재구축
방향을 결정한다.

## 선행 결정: Memory OS와의 관계

masc에는 이미 **Memory OS**(RFC-0244)가 병존한다 — per-keeper fact store, LLM consolidation
pass(`memory_os_keeper_consolidation`, librarian runtime 상속), recall 표면. chronicle
librarian이 하려던 것(세션 기록 → 기억 추출 → 보존/망각)과 역할이 겹친다.

- **Option A (권장): Memory OS로 흡수.** chronicle ingest를 Memory OS의 입력 소스 중 하나로
  재정의하고, retain/forget은 Memory OS의 기존 LLM consolidation 경계가 담당. cognitive_gravity
  수치 휴리스틱과 chronicle_librarian append-only 리스트는 삭제(불도저). 임베딩은 Memory OS
  recall 로드맵을 따름 — 별도 인덱스를 만들지 않는다.
  - 장점: 판단 경계 1곳(이미 LLM), 저장소 1곳, #31의 관측성 표면도 1곳.
  - 단점: Memory OS 스키마가 chronicle의 시계열 성격을 수용해야 함(에피소드 vs fact).
- **Option B: 독립 재구축.** chronicle librarian에 자체 LLM retain/forget 경계 + 자체 인덱스.
  - 단점: 판단/저장/관측 표면이 2벌 — drift 클래스가 그대로 남는다. 기각 권장.

## 설계 (Option A 기준)

### W1 — 관측성 (즉시, 소형 PR, 재구축과 독립)

#31의 문자적 요구. 재구축 결정과 무관하게 지금의 librarian에 적용 가능:

1. **활동 ledger**: `Dated_jsonl` (`.masc/librarian/activity/`) — ingest 시도/성공/실패를
   typed row로 (`Ingest_ok of {sources; extracted}` | `Ingest_failed of {stage; reason}` |
   `Consolidation_ran of {...}`). 실패 사유는 closed variant, 문자열 분류 금지.
2. **silent-zero 제거**: `run_git_output` 실패 모드를 `(output, ingest_error) result`로 —
   타임아웃/시그널/비정상종료를 구분해 ledger에 기록. `None` 붕괴 삭제.
3. **건강 표면**: 대시보드 memory 서브시스템 패널에 마지막 ingest 시각/결과, 누적 기억 수,
   실패 카운트, 다음 예정 실행. `/health?full=1` 구조화 스냅샷에도 동일 projection.

### W2 — retention 통합 (RFC 본체)

1. chronicle 추출물을 Memory OS fact/episode로 기록 (기존 write 경로 재사용).
2. retain/forget = Memory OS LLM consolidation pass 확장 — forget은 tombstone(감사 가능)
   후 compaction에서 물리 삭제. 수치 tau/가중치 삭제.
3. `chronicle_librarian.ml` append-only 리스트, `cognitive_gravity.ml` 휴리스틱 삭제 —
   흡수 완료 시 모듈 자체 제거 (하위호환 없음, 캠페인 불도저 지시).

### W3 — 검증

- W1: ledger row 스키마 codec 라운드트립 + 실패 모드별 typed row 테스트 + 대시보드 projection 테스트.
- W2: consolidation에 chronicle 입력이 흐르는 통합 테스트, forget tombstone→물리 삭제 수명주기 테스트.
- 하네스: librarian 활동을 재현 가능한 fixture(고정 git 히스토리)로 구동하는 평가 스크립트 —
  "좋은 에이전트는 좋은 하네스에서" 원칙.

## 마이그레이션 / 롤백

- W1은 추가만 (기존 동작 무변경) — 즉시 랜딩 가능.
- W2는 chronicle 저장물의 1회 이관 스크립트 + 이관 후 구 모듈 삭제. 롤백 = 이관 스크립트의
  역방향은 제공하지 않음(불도저) — 이관 전 스냅샷 백업으로 갈음.

## 완료 기준

- [ ] #31 문자적 해소: 대시보드에서 librarian의 마지막 활동/건강/로그 위치가 보인다.
- [ ] ingest 실패가 typed로 ledger에 남고 silent-zero가 불가능하다.
- [ ] forget이 실재하고 LLM 경계를 지나며 감사 가능하다.
- [ ] cognitive_gravity/append-only 리스트가 저장소에서 사라진다.
