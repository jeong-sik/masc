# Counterpart and relationship memory: small-store design review

Date: 2026-08-13

## Question

How should a Keeper remember who it met, what that person explicitly prefers,
and what they have done together without creating a second memory authority or
turning conversational inference into operator policy?

The expected cardinality is small: a Keeper has a bounded current-memory
snapshot and usually meets a small recurring set of people. This review
therefore treats graph retrieval, embeddings, decay scores, and another
persistent store as costs that need evidence rather than defaults.

## Implementations reviewed

### Hermes Agent

Hermes separates a compact agent memory from a compact `USER.md` profile. The
profile holds identity, role, communication preferences, habits, and skill
level. A background review explicitly asks whether the user revealed persona,
desires, preferences, personal details, or expectations. Updates use
add/replace/remove operations and the total injected profile is intentionally
small. Hermes also documents one agent/profile per home, which means its
single-user profile cannot be copied directly into a Keeper that meets several
connector users.

- https://hermes-agent.nousresearch.com/docs/user-guide/features/memory
- https://github.com/NousResearch/hermes-agent/blob/main/agent/background_review.py

### OpenClaw

OpenClaw uses a compact `USER.md` for stable preferences, communication style,
relationships, and active-project context. Entries carry observed dates and
active/superseded status so changed preferences replace rather than coexist
with old active directives. Its action-sensitive memory guidance also keeps
source authority and permission boundaries in the memory text and states that
memory does not enforce policy.

- https://docs.openclaw.ai/concepts/memory
- https://docs.openclaw.ai/reference/templates/USER

## Research reviewed

- *Long Time No See! Open-Domain Conversation with Long-Term Persona Memory*
  maintains user and chatbot persona memories separately and reports role
  tokens/embeddings as safeguards against confusing the two parties' facts.
  https://aclanthology.org/2022.findings-acl.207/
- *LongMemEval* treats information extraction, cross-session reasoning,
  temporal reasoning, knowledge updates, and abstention as distinct required
  abilities. In this design, correction and omission-on-uncertainty are part of
  the contract rather than optional prompt style.
  https://arxiv.org/abs/2410.10813
- *LoCoMo* evaluates persona-grounded, temporal, and causal continuity across
  long multi-session conversations. It supports keeping meaningful shared
  history, but does not imply that every dialogue event belongs in active
  memory.
  https://arxiv.org/abs/2402.17753
- *Generative Agents* shows that natural-language experience records and
  higher-level reflection can support relationship formation and coordination.
  Its full memory stream and scored retrieval target a larger simulation than
  the current Keeper store.
  https://arxiv.org/abs/2304.03442
- Mem0 and A-MEM add graph or dynamic-link organization for scalable relational
  retrieval. Those mechanisms solve a search/organization problem that has not
  been measured for the small Keeper current snapshot, so they are not adopted
  here.
  https://arxiv.org/abs/2504.19413
  https://arxiv.org/abs/2502.12110

## MASC model

1. Memory OS remains the sole automatic semantic-memory authority. No new
   people database, graph, score, TTL, or `person` category is added.
2. A person is anchored by a stable actor reference. The Librarian reads a
   bounded typed projection of producer-owned durable records: direct rows
   come from the chat store and connector rows also come from external
   attention, which survives a failed best-effort ambient chat append.
   `channel + workspace_id + user_id` identify an external actor, `user_name`
   is a mutable display label, `authority` is host-authored, and only `content`
   is untrusted text. An authenticated owner without an external ID is named by
   the `owner`/`operator` role, not a fabricated identifier. This avoids
   treating a copied prompt marker as identity and covers ambient and
   official-client paths that do not preserve the incoming message in an
   AGENT_CORE checkpoint.
3. Existing categories retain their meaning. A person claim can be a `fact`,
   `preference`, `goal`, `validated_approach`, or `lesson`; the claim sentence
   contains the actor reference and Keeper-relative relationship.
4. Keep only explicitly stated identity/preferences, stable responsibilities,
   ongoing commitments, jointly validated outcomes, and meaningful shared
   history not recoverable from an authoritative source.
5. Store observations, not personality verdicts. Repeated concrete behavior
   may be summarized cautiously; isolated tone, inferred motives, diagnoses,
   sensitive traits, and third-party hearsay are omitted or kept explicitly as
   attributed speech.
6. A speaker-scoped preference affects interaction with that actor only. It is
   never promoted into a global Keeper rule, operator authority, or permission
   to perform an effect.
7. Correction uses the existing total selection contract: drop the superseded
   claim with a reason and add the corrected claim in the same commit. If
   attribution or durability is uncertain, add nothing.

Recall remains Keeper-wide rather than adding an actor-indexed authorization
layer. The Keeper must not disclose or apply one external actor's private facts
to another actor; this is a semantic response contract, not a deterministic
hard gate in this change.

The provider sees raw observations inside the bounded prompt. The admin-only
exact-run registry keeps the same raw input to preserve its exact-input
contract, so its recent retained runs are a second durable copy of actor text
and identifiers. A registry-wide retention or encrypted-reference design is
deferred rather than creating a Librarian-only pseudo-exact exception. This is
also not an instruction-injection proof: `content` remains model-visible
untrusted text, and the prompt contract requires treating it only as quoted
evidence.

`Keeper_person_notes` continues as a deliberate roster annotation. It is not
an automatic Librarian sink and is not synchronized with Memory OS. If future
usage shows that two stores create operator confusion, consumer tracing should
precede removal or migration; this change does neither.

## Deferred evidence threshold

Add structured subjects or retrieval only after live evidence shows one of
these failures:

- actor-name collisions or actor-scoped correction cannot be resolved from the
  stable references in claims;
- the current snapshot no longer fits its byte budget because person memories
  dominate it;
- exact Memory OS search cannot find a known actor's facts at observed scale;
- a real consumer needs a typed person projection rather than recalled prose.

Until then, a richer schema would add coupling without changing the Keeper's
observable ability to remember a small recurring cast.
