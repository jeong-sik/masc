# v2.88.0 Live MCP Feedback Pack

Date: 2026-03-14
Audience: PM, Engineering, CS
Truth source: live MCP on `127.0.0.1:8935` first, disposable sidecar reproductions second

## One-page conclusion

`2.88.0` 에서는 사용자 체감상 두 가지가 분명히 좋아졌다.

- version truth가 맞아졌다. live `/health` 와 `agent_card` 가 모두 `2.88.0` 을 말한다.
- `dashboard current` 가 더 이상 즉시 lock error를 뿜지 않고 최소 요약을 반환한다.

하지만 execution 관점에서는 완전한 안정판은 아니다.

- 권장: 단일 worker `blocking` 작업, 짧은 검증 루프, proof 확인
- 실험적: 순차 multi-worker 협업
- 비권장: `spawn_batch` 후 즉시 후속 delegate, unattended background swarm

## Delta From Prior Package

| Topic | Prior package | v2.88.0 result | Status |
|------|---------------|----------------|--------|
| Version truth | `/health` 2.87 vs `agent_card` 2.60 mismatch | both now report 2.88.0 | Fixed in 2.88.0 |
| Dashboard current | distributed lock error surfaced to user | compact current summary returned normally | Fixed in 2.88.0 |
| Single-worker coding | passed | passed again | Stable |
| Sequential multi-worker | experimental and fragile | implementer path worked, verifier still failed | Improved but still experimental |
| Batch follow-up delegate | opaque target-worker lookup failure | explicit `not ready for delegation yet` contract | Improved but still experimental |

## What Users Can Reliably Do Now

1. 한 명의 implementer worker에게 명확한 코드 수정과 검증을 맡긴다.
2. `wait_mode="blocking"` 으로 단계 경계를 고정한다.
3. 검증 명령은 `python3 check.py` 같은 단일 명령으로 준다.
4. 결과는 `masc_team_session_prove` 로 확인한다.

## What Users Should Still Avoid

1. `spawn_batch` 후 곧바로 `target_agent` 로 follow-up delegate
2. 복합 shell 예시: `cd`, `&&`, `;`, 절대 python 경로
3. 독립 verifier worker가 자동으로 잘 끝날 거라고 가정하는 것
4. background swarm만 믿고 unattended 운영하는 것

## Evidence Basis

Primary live evidence:

- `curl http://127.0.0.1:8935/health` on 2026-03-14: `version=2.88.0`, `release_version=2.88.0`, `commit=c7444aa9`
- `mcp__masc__masc_agent_card` on 2026-03-14: `version=2.88.0`
- `mcp__masc__masc_auth_status` on 2026-03-14: auth disabled
- `mcp__masc__masc_dashboard(scope="current")` on 2026-03-14: compact summary returned normally

Disposable execution evidence:

- `/tmp/masc-v2880-case1-summary.json`
- `/tmp/masc-v2880-case2-summary.json`
- `/tmp/masc-v2880-case3-summary.json`

## Document Set

- [user-report.md](./user-report.md)
- [cs-playbook.md](./cs-playbook.md)
- [next-version-feedback.md](./next-version-feedback.md)
- [version-truth-audit.md](./version-truth-audit.md)
