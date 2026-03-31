# Issues 정리 완료 보고 (2026-03-30 → 2026-03-31)

이 문서는 2026-03-30에 작성된 이슈 정리 계획으로, 모든 액션이 완료되었습니다.

## 1. 완료된 작업 - ✅ 닫힌 이슈

### Issue #3901: Dashboard asset lookup should not follow MASC_BASE_PATH
**상태:** PR #3896에서 수정 완료
**코멘트:**
```
이 이슈는 PR #3896에서 수정되었습니다.

**수정 내용:**
- Dashboard asset lookup이 MASC_BASE_PATH를 따르지 않도록 수정
- mktemp 처리를 BSD/GNU 호환 가능하도록 개선
- Web_dashboard.assets_root를 통한 자산 해결 경로 수정

PR #3896이 머지되어 문제가 해결되었으므로 이슈를 닫습니다.
```

### Issue #3826: [P0-1] D-0: Handoff SSOT 결정 ADR
**상태:** PR #3887에서 완료
**코멘트:**
```
이 이슈는 PR #3887에서 완료되었습니다.

**완료된 작업:**
- D-0 (Delta-Context Architecture Phase 0) ADR 문서 작성 완료
- Handoff 데이터 3경로 분석 후 SSOT 결정 완료
- Handoff skill (PostgreSQL retrospective + session-state.md)을 SSOT로 선정

관련 Epic: #3825

PR #3887이 머지되어 설계 결정이 문서화되었으므로 이슈를 닫습니다.
```

## 2. 중복 또는 통합 가능한 이슈

### Issue #3897: keeper: write crash-events under cluster-scoped keeper root
**관계:** Issue #3888 (umbrella issue)의 하위 항목
**상태:** target:now로 표시되어 있으며 아직 수정되지 않음
**권고:** 유지 (아직 수정 필요)

### Issue #3898: dashboard/governance: high-risk runtime param set/clear must create petitions
**관계:** Issue #3888 (umbrella issue)의 하위 항목
**상태:** target:now로 표시되어 있으며 아직 수정되지 않음
**권고:** 유지 (아직 수정 필요)

### Issue #3899: test: cover bootstrap restore and keeper lifecycle runtime-param regressions
**관계:** Issue #3888 (umbrella issue)의 하위 항목
**상태:** target:now로 표시되어 있으며 테스트 커버리지 부족
**권고:** 유지 (테스트 추가 필요)

## 3. 장기 계획 - 현재 닫지 않음

다음 이슈들은 장기 계획이거나 Epic 트래킹 이슈로 현재는 유지:
- #3890: [Epic] Tool Surface Contract Redesign
- #3891: [Phase 3] Keeper 내부 API 추출
- #3825: [Epic] Delta-Context Architecture
- #3528: [CDAL] Contract-Driven Agent Loop RFC Implementation Tracker

## 4. 검토 필요 - triage-required 라벨

다음 이슈들은 `triage-required` 라벨이 있어 추가 검토 필요:
- #3904: infra: Pulse.set_rhythm API
- #3907: keeper: work-as-heartbeat 패턴
- #3903: keeper: expand hot-reload surface
- #3878: keeper: prompt 변경 후 SKIP 비율 감소에 따른 토큰 사용량 모니터링
- #3877: keeper: Qwen3.5-9B의 tool calling 품질 평가
- #3890: [Epic] Tool Surface Contract Redesign

## 요약

- **즉시 닫을 이슈:** 2개 (#3901, #3826) ✅ **완료**
- **유지할 이슈:** 40개 (대부분 진행 중이거나 장기 계획)
- **추가 triage 필요:** 6개

## 액션 완료 상태

1. ✅ Issue #3901 닫힘 (2026-03-30 08:41 UTC) — 소유자가 직접 처리
2. ✅ Issue #3826 닫힘 (2026-03-30 08:12 UTC) — 소유자가 직접 처리
3. ⏳ triage-required 라벨 이슈들은 소유자 검토 대기 중

## 현재 진행 중인 target:now 이슈 (2026-03-31 기준)

계획 작성 후 확인된 현재 진행 중인 우선순위 이슈:

- **#3593**: 모놀리스 분해 (lib/ 788파일 152K LOC → sub-library 추출)
- **#3528**: [CDAL] Contract-Driven Agent Loop RFC 구현 추적

---

**이 문서의 목적은 달성되었습니다.** 필요 시 아카이브하거나 삭제 가능.
