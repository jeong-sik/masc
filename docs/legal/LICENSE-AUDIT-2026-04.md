# LICENSE Audit — 2026-04-29

> Status: First-pass audit. Subsequent revisions track CLA, license header coverage, and dependency license drift.
> Author: Vincent (jeong-sik)
> Last verified: 2026-04-29
> Source 자료: 외부 multi-agent IDE 분석(`multiagent-ide-deep-analysis.md` Track D §1, line 3294-3317) Open Core 권고

---

## 1. Current License State

| 항목 | 상태 |
|---|---|
| Top-level `LICENSE` | **MIT License**, Copyright (c) 2024-2025 MASC Contributors |
| `LICENSE.md` (markdown variant) | 부재 |
| `ENTERPRISE.md` (top-level) | 부재 |
| `docs/legal/` | 부재 → 본 PR로 신설 |
| `CLA.md` / `DCO` / contributor agreement | **부재** |
| SPDX header coverage | 미점검 (§2 후속 작업) |
| 의존성 license 인벤토리 | 미점검 (§3 후속 작업) |

**현 단계 결론**: license 텍스트 자체는 MIT으로 명확. Open Core / Enterprise Edition 분리(외부 분석 §1) 진입 전 prerequisite이 *contributor 동의 절차* + *header coverage 자동화* + *의존성 license 인벤토리* 3건 미충족.

---

## 2. License Header Coverage

후속 작업 (별도 PR):

```bash
# 모든 OCaml 소스에 SPDX-License-Identifier 헤더 누락 여부 점검
find lib bin specs -name '*.ml' -o -name '*.mli' | \
  xargs grep -L 'SPDX-License-Identifier' | head -20
```

수동 점검은 sample 검사만 했고, 자동 sweep + ratchet 도입 후속 PR.

---

## 3. Third-party Dependencies (의존성 라이선스)

후속 작업 (별도 PR):

- `dune-project`의 `depends` 영역 enumerate (~30 packages)
- `opam list --installed` + `opam show <pkg> | grep -i license` 자동 수집
- license 호환성 매트릭스 (MIT/Apache 2.0/BSD/LGPL/AGPL 분류)
- copyleft (LGPL/AGPL) 의존성 발견 시 별도 평가

현재까지 spot-check (수동)로 발견된 license 종류:
- MIT (대부분)
- Apache 2.0 (`yojson`, `eio` 등 추정)
- BSD (`menhir` 추정)

자동 수집 후 본 문서 §3 갱신.

---

## 4. Contributor Agreement

| 항목 | 상태 | 위험 |
|---|---|---|
| DCO | 부재 (`.github/CONTRIBUTING.md` 없음) | 향후 license 전환 시 *모든 contributor 개별 동의* 필요 |
| CLA | 부재 | 동일 |
| `git blame` contributor 수 | (미수집) | sweep 후 §4 갱신 |

**권고**: contributor 수 증가 전 DCO 도입 (lightweight, CLA 대비 진입 장벽 낮음). Open Core 분리 시점에는 CLA 도입 검토.

---

## 5. Open Core 분리 후보

별도 문서 `docs/legal/ENTERPRISE-CANDIDATES.md` 참조. 본 문서는 license 측면만 다룬다.

---

## 6. Action Items

- [ ] **License header SPDX sweep** (별도 PR) — `find ... -name '*.ml' | xargs grep -L 'SPDX-License-Identifier'` ratchet 도입
- [ ] **opam 의존성 license 수집** (별도 PR) — `opam show <pkg>` 자동 enumerate, 호환성 매트릭스
- [ ] **DCO 도입 결정** (별도 PR) — `.github/CONTRIBUTING.md` + DCO/CLA-bot 통합
- [ ] **Contributor 식별** — `git log --format='%aE' | sort -u` + contact list
- [ ] **EE 분리 결정** (사용자 결정 영역, prerequisite 충족 후)

---

## 7. References

- `LICENSE` (top-level, MIT)
- 외부 분석: `multiagent-ide-deep-analysis.md` (2026-04-29) Track D §1 (line 3294-3458)
- IMPLEMENTATION-QUEUE: Q-P0-5 (research worktree)
- 본 PR: `feature/license-audit-2026-04`

*작성: 2026-04-29*
