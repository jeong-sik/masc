# Version Truth Audit

Date: 2026-03-14
Decision: closed mismatch for version number, keep regression guard

## Summary

`2.88.0` 에서는 직전 패키지에서 관찰된 version truth mismatch가 해소됐다.

- live `/health` -> `2.88.0`
- live `agent_card` -> `2.88.0`
- repo `CHANGELOG` -> `2.88.0`

즉 사용자에게 “현재 버전이 무엇인가”를 안내할 때 더 이상 서로 다른 숫자를 말하지 않는다.

## Observations

| Source | Observed value | Meaning |
|--------|----------------|---------|
| live `/health` | `2.88.0` | live build/release truth |
| live `agent_card` | `2.88.0` | client-visible metadata truth |
| repo `CHANGELOG.md` | `[2.88.0]` expected next line after bump | repo release line과 크게 충돌하지 않는 상태 |

## Residual Gap

완전히 끝난 건 아니다.

- `/health` 는 `commit`, `started_at`, `uptime_seconds` 같은 build provenance를 준다.
- `agent_card` 는 version은 맞지만 build provenance는 주지 않는다.

따라서 운영/CS는 계속 `/health` 를 기준으로 보는 것이 맞다.

## Decision

- 사용자 안내용 버전 숫자: `/health` 또는 `agent_card` 어느 쪽을 써도 됨
- 운영 기준 진실: `/health`
- regression guard 필요: yes
