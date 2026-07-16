# ENTERPRISE Edition — Module Separation Candidates

> Status: Candidate identification (코드 변경 0). **본 문서는 분리 결정이 아니다.**
> Author: Vincent (jeong-sik)
> Created: 2026-04-29
> Related: `docs/legal/LICENSE-AUDIT-2026-04.md`, IMPLEMENTATION-QUEUE Q-P0-5
> Source 자료: 외부 multi-agent IDE 분석 (`multiagent-ide-deep-analysis.md` Track D §1, line 3294-3458) Open Core 권고

---

## 1. Purpose

Open Core 분리 시 EE(Enterprise Edition) tier로 이동 가능한 모듈을 *식별*한다. 본 문서는 식별만 다루며, 분리 결정은 별도 (CLA 선행 + 모든 contributor 동의 + 비즈니스 결정 후).

분리 *반대 의견*도 §4에 기록한다 — anti-hype: 분리는 항상 옳지 않다.

---

## 2. Candidate Modules (식별)

### 2.1 Auth Suite

| 모듈 | EE 적합성 근거 |
|---|---|
| `lib/auth.ml` + `.mli` | 인증 핵심. EE는 *확장*만 (SAML2/SCIM/SSO) |
| `lib/auth_diagnostic.ml` + `.mli` | auth 진단 도구. compliance 시나리오에서 EE 차별화 가능 |
| `lib/auth/auth_login.ml` + `.mli` | login 흐름 |
| `lib/auth_resolve.ml` + `.mli` | identity 해소 |
| `lib/auth_strict_mode.ml` + `.mli` | strict mode (compliance) — Enterprise compliance 요구에 부합 |
| `lib/auth_error_kind.ml` + `.mli` | error variant (분리 무관, OSS 유지 권고) |

**평가**:
- ✅ Enterprise 차별화 가능 (SSO/SAML2/SCIM/OIDC 확장은 typical EE)
- ⚠️ 핵심 기능 — Open Core 사용자가 인증 *없이* 동작해야 함 → core auth는 OSS에 *유지*, EE는 *추가 확장만*
- 다음 작업: 코드 sweep으로 *core*(필수)와 *enterprise*(SAML2/SCIM/audit) 경계 식별

**분리 반대 의견**: auth는 보안 핵심. EE 분리 시 OSS 사용자의 *security audit* 가능 영역이 줄어듦 → 신뢰 저하 위험. *추가 확장만 EE*로 한정.

### 2.2 Sandbox

| 모듈 | 근거 |
|---|---|
| `lib/sandbox.ml` + `.mli` | task 격리. gVisor/Firecracker 도입 시 EE 후보 (외부 분석 §1, line 3437) |

**평가**:
- ✅ Enterprise 차별화 (강한 격리 = compliance 요구)
- ❌ 현재 구현이 *Tier 1 부분 구현* (ch1 S6: "sandbox path leak 잔존, gVisor/Firecracker rg 0 hits")
- → EE 분리 *prerequisite 미충족*. sandbox 완성 후 결정.

### 2.3 Repo Auth Provider

| 모듈 | 근거 |
|---|---|
| retired | repo-local auth brokering was removed from the product surface |

**평가**:
- ❌ 현재 EE 후보 아님. repo-local auth brokering is not a supported split surface.

### 2.4 향후 후보 (현재 미구현)

| 영역 | 외부 분석 인용 | 구현 여부 |
|---|---|---|
| SSO / SAML2 / OIDC 확장 | line 3437-3458 (SOC2/GDPR DPO) | 미구현 |
| Multi-tenancy / Tenant isolation | line 3326 Enterprise Tier | 미구현 |
| Audit log + compliance reporting | line 3437-3458 | 부분 (`metric_*` 카운터 일부) |
| Quantum-resistant encryption (Ed25519 → CRYSTALS-Kyber) | line 3431+ | 미구현 |
| Bring-Your-Own-Agent (BYOA) marketplace | line 3424-3428 | 미구현 |

위 5건은 *모두 미구현 영역* — EE 후보 식별이라기보다 *EE 차별화 후보 영역*. 구현 자체가 prerequisite.

---

## 3. 분리 의사결정 Prerequisites

분리 PR을 만들기 전 만족해야 할 조건:

- [ ] CLA / DCO 도입 (LICENSE-AUDIT §4)
- [ ] 모든 contributor 동의 (git blame sweep + outreach)
- [ ] 분리 후 OSS / EE 양쪽의 build/test 검증 인프라 (CI 분기, monorepo vs 별도 repo)
- [ ] 비즈니스 결정 (Vincent 단독 또는 법인 전환 후)
- [ ] EE 라이선스 모델 결정 (proprietary, AGPL, Apache 2.0 + commercial 듀얼, …)
- [ ] 외부 의견 — 기존 contributor + early users 의견 수렴

---

## 4. 분리 반대 의견 (anti-hype)

분리는 항상 옳지 않다. 다음 위험을 명시:

1. **OSS 신뢰 저하**: 핵심 기능을 EE로 보내면 OSS 사용자가 "fully usable" 상태가 아님 → adoption 저하
2. **유지비 분산**: monorepo vs 별도 repo 결정 따라 CI/test 비용 2배
3. **Premature optimization**: 현재 12 keeper 환경에서 Enterprise tier 수요 검증 안 됨 → 시기상조
4. **License 전환 cost**: MIT → Apache+Commercial 등 전환 시 모든 contributor 동의 필요 → 실패 시 forking 위험
5. **External 분석의 시장 수치 신뢰도**: $526억 시장 (Insight 6) Confidence L — investor pitch 외 내부 결정에 사용 비권장 (Track D §4 참조)

→ 결정: **본 cycle에서는 분리 결정 보류**. 식별만 진행. 6개월 후 (2026 Q4) 재평가 일정.

---

## 5. Open Questions

- 분리 시 monorepo vs 별도 repo? (외부 분석 §1.2 Open Core, line 3300)
- EE 코드의 publish 위치 (private GitHub org? GitLab? self-hosted?)
- 분리 시 기존 contributor의 EE 코드 contribute 가능성 (CLA 동의 + access)
- "free tier 3 agent / 100 credits" (line 3326-3327)와 OSS 무제한의 관계
- BYOA(Bring Your Own Agent, line 3424) 도입 시 EE/OSS 경계

---

## 6. References

- 외부 분석: `multiagent-ide-deep-analysis.md` Track D §1 (line 3294-3458), §4 (Insight 6)
- LICENSE-AUDIT: `docs/legal/LICENSE-AUDIT-2026-04.md` §4 (CLA prerequisite)
- IMPLEMENTATION-QUEUE: Q-P0-5
- ch1 진단: `ch1_diagnosis_mapping.md` S6 (sandbox path leak)
- RFC 0008: `docs/rfc/RFC-0008-credential-provider.md`

*작성: 2026-04-29 / 분리 결정은 별도, 본 문서는 식별만*
