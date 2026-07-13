---
rfc: RFC-0109
title: "CDAL x Goal Integration Contract"
status: Withdrawn
created: 2026-05-17
updated: 2026-07-13
---

# RFC-0109 — Withdrawn

The proposed CDAL-to-Goal transition bridge is retired in full. A local
contract verdict, verifier identity, quorum count, or operator role must not
authorize or reject a Goal transition.

Goal state remains owned by the Goal boundary. When context or evidence needs
judgment, the configured LLM receives the typed Goal input and returns the
request-local judgment. CDAL output may be supplied as observed context only;
it has no implicit transition authority.

The former Phase D Task adapter was already withdrawn for the same reason.
Phases A-C are now withdrawn as well. No feature flag, string classifier,
verdict bridge, or compatibility decoder from this RFC should be implemented.

Replacement boundaries:

- Goal typed state and version preconditions for objective transitions.
- Configured LLM judgment for semantic completion decisions.
- Keeper Gate for external effects; CDAL is not an authorization source.
