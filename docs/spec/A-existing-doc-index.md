---
status: reference
last_verified: 2026-04-23
code_refs:
  - docs/
  - docs/_audit/2026-04-17-doc-classification.md
---

# Appendix A: Existing Documentation Index

> 목적: tracked 문서를 `front door / maintained reference / historical / archive / cleanup action`으로 다시 분류한다.
> 기준일: 2026-03-25
> Baseline: `dune-project` version `2.148.0`

## Classification

| Status | 의미 |
|--------|------|
| Canonical | 현재 front-door 또는 운영 SSOT. 적극 유지 |
| Maintained Reference | 여전히 참조되거나 tool/test에 묶인 참고 문서 |
| Historical | superseded banner가 있는 과거 snapshot. 삭제 대신 맥락 보존 |
| Archive | `docs/archive/` 또는 실험/피드백 저장소 |
| Redirect Stub | 옛 경로 호환용 짧은 포인터 |
| Removed | 이번 정리에서 통합 후 삭제 |

## Canonical Front Door

| File | Status | Notes |
|------|--------|-------|
| `README.md` | Canonical | public overview, build/run entry |
| `docs/QUICK-START.md` | Canonical | install, health check, first workflow |
| `docs/MCP-TEMPLATE.md` | Canonical | HTTP/stdio MCP config examples |
| `docs/RELEASE-EVIDENCE.md` | Canonical | reproducible production proof bundle contract |
| `docs/spec/SPEC-INDEX.md` | Canonical | spec suite index |
| `docs/BENCHMARK-RUNBOOK.md` | Canonical | baseline vs swarm recipe |
| `docs/INTEGRATED-BENCHMARK-RUNBOOK.md` | Canonical | control/search wrapper |
| `docs/SUPERVISOR-MODE.md` | Canonical | supervised delivery/operator path |
| `docs/TRANSPORT-PRACTICAL-PLAYBOOK.md` | Canonical | transport selection and diagnostics |
| `docs/KEEPER-USER-MANUAL.md` | Canonical | keeper lifecycle and troubleshooting |

## Maintained Reference

| File | Status | Notes |
|------|--------|-------|
| `docs/MCP-SURFACE-AUDIT.md` | Maintained Reference | public/hidden tool surface audit |
| `docs/VERIFICATION-MATRIX.md` | Maintained Reference | verification tier SSOT |
| `docs/VERSIONED-ROADMAP.md` | Maintained Reference | release train and intake policy |
| `docs/CAPABILITY-REGISTRY-SSOT.md` | Maintained Reference | MCP vs internal capability mapping |
| `docs/OAS-MASC-BOUNDARY.md` | Maintained Reference | OAS/MASC role split |
| `docs/PROVIDER-ADAPTER-RUNBOOK.md` | Maintained Reference | provider/runtime/auth guidance |
| `docs/TRPG-KEEPER-SPECTATOR-QUICKSTART.md` | Maintained Reference | TRPG spectator entry |
| `docs/TRPG-OPS-MANUAL.md` | Maintained Reference | follow-up ops guide for spectator flow |

## Historical Snapshots Kept In Tree

| File | Status | Notes |
|------|--------|-------|
| `docs/SPEC.md` | Removed | superseded by `docs/spec/SPEC-INDEX.md`; deleted 2026-04-23 |
| `docs/MERGED-ARCHITECTURE-SSOT.md` | Removed | superseded by `docs/spec/01-system-overview.md`; deleted 2026-04-23 |
| `docs/GLOSSARY.md` | Historical | superseded by `docs/spec/00-glossary.md` |
| `docs/SWARM-ARCHITECTURE.md` | Historical | chain/spec context only |
| `docs/DASHBOARD-INTEGRATION.md` | Historical | dashboard integration snapshot |
| `docs/PRODUCT-REVIEW.md` | Historical | product/security review memo |
| `docs/MASC-V2-DESIGN.md` | Historical | early v2 concept document |
| `docs/MULTI-ROOM-DESIGN.md` | Removed | deleted 2026-04-17 (historical, no code refs) |
| `docs/COMMAND-PLANE-RUNBOOK.md` | Historical | retired command-plane contract and migration context |

## Archive and Experiment Stores

| Path | Status | Notes |
|------|--------|-------|
| `docs/archive/` | Archive | closed roadmaps and archived planning docs |
| `docs/archive/keeper-autonomy-identity-v2/` | Archive | archived design package |
| `docs/design/` | Archive | active design memos, not front-door docs |
| `docs/research/` | Archive | research reference material |
| `docs/qa/` | Archive | reverse-engineered and QA-oriented notes |

## Cleanup Actions From This Sweep

| Path | Result | Notes |
|------|--------|-------|
| `docs/QUICKSTART.md` | Removed | 3-line redirect stub deleted; canonical entry is `docs/QUICK-START.md` |
| `docs/SETUP.md` | Removed | install/run content merged into `README.md` and `docs/QUICK-START.md` |
| `docs/INSTALL-CHECKLIST.md` | Removed | post-install checks merged into `docs/QUICK-START.md` |
| `docs/SPEC.md` | Removed | content merged into `docs/spec/SPEC-INDEX.md`; deleted 2026-04-23 |
| `docs/MERGED-ARCHITECTURE-SSOT.md` | Removed | content merged into `docs/spec/01-system-overview.md`; deleted 2026-04-23 |
| `docs/OCAML-NORTH-STAR.md` | Removed | duplicate of `docs/NORTH-STAR-OCAML.md`; deleted 2026-04-23 |
| `docs/architecture-boundary.md` | Removed | superseded by `docs/OAS-MASC-BOUNDARY.md`; deleted 2026-04-23 |
| `docs/RELEASE-ROADMAP.md` | Not present | use `docs/VERSIONED-ROADMAP.md` and `docs/archive/RELEASE-ROADMAP-v287.md` |

## Notes

- This index is a cleanup ledger, not a promise that every reference document is current.
- A document stays in-tree when code, tests, fixtures, or tool help still cite it.
- When deleting or moving docs, re-run link checks and `test/test_tool_registration_consistency.exe` before treating the sweep as complete.
