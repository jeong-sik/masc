# RFC-0234 Caller Context

Owner request, 2026-06-12:

- Build an internal MASC scheduling tool after the current provider/runtime work.
- Start with the design document before implementation.
- The scheduled action may be requested by one actor, but execution approval
  must be granted by a different person.

Design constraints:

- No external OS scheduler as the contract.
- No direct shell execution from stored schedule text.
- Scheduled execution must pass through existing MASC descriptor, policy,
  sandbox, and approval surfaces.
- Side-effecting scheduled work requires separate human execution approval.

Verification expectation:

- RFC numbering and ledger checks pass.
- The changed RFC passes the local RFC section-1 enforcer.
- Implementation is explicitly deferred to follow-up PRs.
