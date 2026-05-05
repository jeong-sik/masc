# RFC 0022 — IDE Plane Assembly v1 (Umbrella)

- **Status**: Draft
- **Author**: Vincent + Claude (auto mode session 2026-05-05)
- **Created**: 2026-05-05
- **Depends on (existing RFCs)**:
  - RFC 0010 (CollaborationCursor — keeper presence anchor primitive)
  - RFC 0014 (TreeView — file explorer keyboard parity)
  - RFC 0015 (Tabs — view tabs + LAYERS multi-select)
  - RFC 0016 (Toolbar — IDE modebar)
  - RFC 0017 (Solid Migration — sync-mount + Solid island regime)
  - RFC 0019 (Keeper Line Ownership — blame-by-keeper data model)
  - RFC 0020 (Layered Overlay System — LAYERS toggle framework)
  - RFC 0021 (Anchored Thread Rail — CONVERSATION rail data model)
- **Blocks**: RFC 0023, 0024, 0025, 0026 (모두 본 RFC 의 application)
- **Sister RFC**: repo `docs/rfc/RFC-0033-worktree-status-sse.md` (server side)
- **SSOT audit**: `dashboard/design-system/audits/2026-04-30-ide-mockup-vs-v0.4-mapping.md`
- **GitHub Issues**: #13197 (P0-A) · #13198 (P0-B) · #13199 (P1-A) · #13200 (P1-B) · #13201 (P2)

---

## 1. Motivation

`dashboard/src/components/ide/`에 30+ 파일이 wire-up 되어 있고 IDE plane 의 client-side 는 80%+ 완성 상태다. `ide-shell.ts` 가 root container, `IDE_LAYERS` 가 정의됨, `keeper-presence-store` 의 `workspace_label` 필드 contract 도 있다. 그러나:

1. **server-side gap**: IDE plane 이 필요로 하는 데이터(worktree status, keeper shell ring buffer)를 노출하는 핸들러가 0건. `rg "worktree" lib/dashboard/` 가 0 hit.
2. **mock fragments**: mockup 이 추가한 4 영역 중 일부는 still mock — `ide-activity-mock.ts`, `ide-conversation-rail-mock.ts`, `ide-interject-mock.ts`.
3. **producer wire-up gap**: RFC-0019/0020/0021 의 store contract 는 정의됐지만 producer-side handler / SSE 가 미작성.

본 RFC 는 이 gap 을 5 sub-RFC (DS 0023–0026 + repo 0033) 로 분할하고, 각 sub-RFC 가 production PR sequence 로 어떻게 매핑되는지 우산으로 묶는다.

## 2. Non-Goals

- 새로운 store/primitive 정의 (DS 0019/0020/0021 이 이미 정의).
- file explorer 자체의 RFC (RFC-0014 + zone-E1 worktree 진행 중).
- mockup 의 raw hex 를 production 에 직접 도입 (audit §3 token tier 룰).
- emoji/아이콘 도입 (SKILL.md `Component vocabulary`).
- worktree 생성·삭제 등 mutating action (read-only IDE plane).

## 3. Sub-task → RFC → PR 매핑

| Sub-task | scope | 신규 RFC | 의존 RFC | 우선순위 | LOC 추정 | Issue |
|---|---|---|---|---|---|---|
| **P0-A** worktree presence | server SSE + topbar chip mapper | repo RFC-0033 | RFC-0010 | P0 | ~250 | #13197 |
| **P0-B** cascade overlay | LAYERS 'cascade' entry + line-level data | DS RFC-0023 | RFC-0019, 0020 | P0 | ~300 | #13198 |
| **P1-A** BDI inspector slot | inspector rail BDI peek | DS RFC-0024 | RFC-0019, 0008 | P1 | ~200 | #13199 |
| **P1-B** keeper shell drawer | drawer + ring buffer SSE | DS RFC-0025 | (없음) | P1 | ~400 | #13200 |
| **P2** audit replay | scrubber + timestamp filter | DS RFC-0026 | RFC-0021 | P2 | ~330 | #13201 |

총 ~1,480 LOC + 6 RFC.

## 4. PR Sequence

```
PR-1 (this)  RFC umbrella + sub-RFCs 6개
   └── feature/ide-plane-rfc-umbrella

PR-2  P0-A server SSE  ─┐
                         ├─ 독립 (server endpoint scope 분리)
PR-3  P0-A client mapper┘  PR-2 머지 후

PR-4  P0-B cascade overlay  RFC-0019/0020 producer wire 후

PR-5  P1-A BDI inspector slot  RFC-0019 producer wire 후

PR-6  P1-B keeper shell server SSE ─┐
                                     ├─ PR-7 ← PR-6
PR-7  P1-B drawer client            ┘

PR-8  P2 audit replay  RFC-0021 producer wire 후
```

PR-2~8 은 server endpoint scope 가 분리되어 있어 keeper 별 병렬 가능. 단 같은 sub-task 내 server→client 순서는 지킨다.

## 5. Keeper 분배

| Keeper | toml | persona | 분배 |
|---|---|---|---|
| **sangsu** | yes | sangsu | P0-A 서버 (coding preset, 안전 패턴) |
| **nick0cave** | (toml 없음) | (link) | P0-A 클라이언트 wire-up |
| **masc-improver** | yes | analyst | P0-B cascade (delivery preset, cascade 도메인) |
| **issue_king** | yes | issue_king | P2 audit replay (delivery preset, 감사 도메인) |
| **ramarama** | yes | (link) | P1-B drawer 서버 (delivery, sandbox) |
| **taskmaster** | yes | (link) | umbrella 진행 추적 (delivery preset) |
| **scholar** | persona only | scholar | P1-A BDI 모델링 자문 |
| **analyst** | persona only | analyst | P1-A 관찰성 자문 |
| **verifier** | persona only | verifier | 모든 PR 테스트 검증 |
| **executor** | persona only | executor | 빌드/lint 게이트 |
| **jobsian_purist** | (no toml) | (perpetual) | P1-B drawer 클라이언트 |
| **velvet-hammer** | (no toml) | (perpetual) | P2 audit replay 회고 분석 |
| **tech_glutton** | (no toml) | (perpetual) | P0-B 통합 |

이외 perpetual keeper(qa-king, imseonghan, glm-coding-plan)는 board post 보고 자율 picker.

## 6. 검증 (PR 별 통과 기준)

audit §6 checklist + 다음:

- [ ] `rg "#[0-9a-fA-F]{3,8}" dashboard/src/components/ide/` 0 hits (raw hex 금지)
- [ ] Solid component 는 RFC-0017 §7d sync-mount 패턴 (`useLayoutEffect` ref callback)
- [ ] 새 token 필요 시 `tokens/source.ts` PR 선행 + `tokens-drift` CI 4 gate green
- [ ] vitest unit + msw + Playwright e2e 각 PR
- [ ] a11y: `jest-axe` + reduced-motion 처리

## 7. 일정 추정

- RFC 머지 (PR-1): 1-2일 (리뷰 1회)
- PR-2~8: 6 keeper 병렬이면 4-6일 wall clock
- 단일 keeper sequential: ~2주

## 8. 위험

- **mock cutover regression**: mock 컴포넌트와 production 컴포넌트가 같은 store 를 쓰므로 cutover 시점에 시각 회귀 가능 → 각 PR 마다 mock 도 같이 정리.
- **worktree count scale**: 2026-05-05 기준 33 worktree. 200 worktree 까지 청크 페이지네이션 (RFC-0033 §4.4).
- **race-window during PR series**: 7 PR 직렬은 same-axis race 위험. PR-2/3/4/6/8 은 독립 가능하지만 head sweep `gh pr list --search "<filename>"` 매번.
- **keeper 자율 picker drift**: keeper 가 board post 만 보고 잘못된 sub-task pick 가능 → 본 RFC §5 분배표를 SSOT 로.

## 9. Open questions

1. **drawer terminal input 권한**: PR-7 read-only. input 은 별도 RFC + RBAC 검토 필요.
2. **audit replay free-range vs PR-bound**: 1단계 PR-bound → 2단계 free-range. 데이터 cardinality 측정 후 결정.
3. **cascade overlay line-level vs commit-level**: 1단계 commit-level (적은 data join), 2단계 line-level (diff hunk join 추가).

이 질문들은 draft acceptance 를 막지 않으나 각 PR 시작 전 close 한다.
