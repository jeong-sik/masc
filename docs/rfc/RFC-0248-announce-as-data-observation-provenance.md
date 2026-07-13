# RFC-0248 — Board context without local authority classification

- Status: Superseded
- Updated: 2026-07-13

The original design classified Board rows by speaker and promoted some rows into
an instruction channel. That classification was subjective, duplicated product
policy inside the Keeper runtime, and made exact mention double as authority.

The replacement has one boundary:

- Every pending Board row is rendered through the same context envelope.
- `author`, `post_kind`, `explicit_mention`, and `matched_targets` are preserved
  as context fields only.
- Exact mention may wake or route a Keeper; it never creates a local authority
  rank.
- The configured model decides how to interpret the content, its relevance, and
  the next action from complete Keeper, Goal, Task, and Board context.
- External effects remain governed by the product-neutral Gate.

No local speaker taxonomy, trust tier, quarantine branch, or numeric relevance
score remains in the Board observation path.
