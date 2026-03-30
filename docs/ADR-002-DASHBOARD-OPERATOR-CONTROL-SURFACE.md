# ADR-002: Dashboard Operator Control Surface - operator quartet + review queue

**Status**: Accepted
**Date**: 2026-03-30
**Reviewers**: Human, Codex

---

## Context

대시보드 운영 제어를 어떤 surface 위에 올릴지 혼선이 있었다.

초안 RFC는 다음 전제를 두었다:

1. dashboard가 raw `masc_*` 도구 inventory를 직접 노출해야 한다.
2. `tools/list`로 전체 스키마를 받아 generic tool executor를 만들면 control plane이 된다.
3. 이 작업은 프론트엔드 전용으로 충분하다.

하지만 현재 `main`의 canonical path는 이 전제와 다르다.

- 기능 구현용 운영 surface의 기본 경로는 `masc_team_session_*` + `masc_operator_*` 다.
- operator-facing intervention UI는 raw tool palette가 아니라 translated digest/action surface다.
- operator-facing UI의 기본 UX는 `prioritized review queue` 또는 equivalent action queue로 수렴해야 한다.
- 기본 `tools/list`는 전체 inventory가 아니라 curated public MCP surface다.
- remote-safe operator surface는 `/mcp/operator`의 4개 도구로 제한된다.

즉 dashboard control plane의 기본 문제는 "모든 도구를 버튼으로 노출할 것인가"가 아니라,
"사람이 지금 검토해야 할 항목을 어떤 read model과 action flow로 처리할 것인가"다.

---

## Decision

### 1. Canonical dashboard control surface는 `masc_operator_*`다

운영용 dashboard control의 기본 surface는 다음 quartet로 고정한다.

- `masc_operator_snapshot`
- `masc_operator_digest`
- `masc_operator_action`
- `masc_operator_confirm`

raw `masc_*` inventory는 기본 dashboard control path로 취급하지 않는다.

### 2. Canonical UX는 review queue workbench다

운영 UI의 기본 구조는 다음 순서로 수렴한다.

1. `review_queue`
2. selected detail
3. action workbench
4. resolve / defer / confirm / verify

Truth, friction, advice는 같은 수준의 병렬 알림 스트림으로 노출하지 않는다.
기본 진입점은 queue이고, surface distinction은 detail/provenance에서 유지한다.

### 3. Generic tool executor는 기본 경로가 아니다

JSON Schema 기반 generic tool executor는 필요하면 만들 수 있지만, 그 역할은 다음으로 제한한다.

- local-only admin/debug utility
- curated public surface 또는 explicit allowlist 위의 보조 실행기
- operator control canonical path의 대체재가 아님

generic executor를 설계하더라도 "`tools/list`가 전체 inventory를 보여준다"는 가정 위에 두지 않는다.

### 4. “프론트엔드 전용” 가정은 기본값이 아니다

operator review queue, deferred lane, recent review history, confirmation flow처럼
운영 의미가 있는 surface는 필요 시 backend read/write model을 추가할 수 있다.

dashboard control 개선을 “프론트엔드만으로 해결해야 한다”는 제약으로 고정하지 않는다.

---

## Consequences

### 긍정적

- dashboard control의 중심이 raw tool catalog가 아니라 operator decision flow로 정리된다.
- intervention 화면이 monitoring 화면이나 버튼 모음으로 다시 퇴행하는 것을 막는다.
- remote `/mcp/operator` surface와 local dashboard UX가 같은 개념 축을 공유한다.
- generic executor가 생겨도 canonical control path와 admin/debug utility를 구분할 수 있다.

### 부정적

- 임의 도구를 즉시 실행하는 “Swiss-army knife” UI는 기본 대시보드에서 제공되지 않는다.
- 일부 제어 기능은 별도 operator read model이나 승인 flow가 필요해 구현 비용이 든다.
- generic executor를 원하는 요구는 별도 문서와 비정규 surface로 관리해야 한다.

### Follow-up Rules

1. dashboard control 관련 신규 문서는 raw tool palette가 아니라 `masc_operator_*`와 review queue를 먼저 기준으로 잡는다.
2. generic tool executor 제안은 별도 문서로 분리하고, local-only / admin-only / debug-only 여부를 명시한다.
3. `tools/list` 기반 설계는 curated public surface 제약과 `include_hidden` / full-surface 조건을 먼저 명시해야 한다.

---

## References

- `docs/MERGED-ARCHITECTURE-SSOT.md`
- `docs/REMOTE-MCP-OPERATOR.md`
- `docs/design/contract-driven-agent-loop-rfc.md`
- `docs/QUICK-START.md`
- `lib/tool_catalog.mli`

---

## Changelog

| Date | Change | Author |
|------|--------|--------|
| 2026-03-30 | Initial ADR | Codex |
