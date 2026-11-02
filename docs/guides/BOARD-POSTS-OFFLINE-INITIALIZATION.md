# Offline Board posts initialization

Stop workspace writers, then inspect an existing BasePath:

```sh
masc workspace-upgrade board-posts inspect --base-path /path/to/workspace
```

Inspection creates no directory, payload, sibling lock or lease. It distinguishes
an absent posts file from an existing empty file and reports raw complete-byte
SHA256 evidence. It rejects malformed or torn posts, nonregular or multiply linked
files, and an aliased `.masc` directory. Root aliases resolving to the same physical
BasePath are supported. The result is an observation, without write authority.

Copy `result.intent_sha256` from a fresh actionable inspection. An unused layout
reports `bootstrap_required`; existing healthy posts without a guard report
`adoption_required`. Run the matching explicit action:

```sh
masc workspace-upgrade board-posts bootstrap --base-path /path/to/workspace \
  --expected-intent-sha256 "$INTENT"
masc workspace-upgrade board-posts adopt --base-path /path/to/workspace \
  --expected-intent-sha256 "$INTENT"
```

The token binds the physical root, selected action and logical content. A changed
root or content requires a new inspection. Bootstrap requires posts, guard and all
four dependent Board data files to be absent. Adoption and Ready inspection do
not examine dependent files or certify their health.

Mutations acquire the configured host BasePath lease once and refuse any current
owner, including this process. There is no waiting, signaling, force or resume.
The protocol obtains real stable snapshots for both files before writing. Bootstrap
durably publishes empty posts; adoption durably rewrites the exact validated raw
posts bytes. Only a known posts receipt permits publishing the one-row
`board_posts.initialized.jsonl` guard with a fresh generation. Repeating a
completed action refuses without changing the generation.

Read each file's `effect` and diagnostics in the outcome. `confirmed_now` records
an actual durable receipt; `effect_unknown` requires investigation and must not be
treated as permission to replay. A known posts receipt survives a later guard
failure. There is no rollback or automatic repair. Guardless surviving posts need
a fresh explicit adoption. A restart can observe valid current files, but cannot
settle an earlier attempt's unknown durability. Loss of both files with no
dependents is indistinguishable from an unused layout; bootstrap is an explicit
operator decision.

Descriptor cleanup diagnostics preserve known primary effects. Retained reserved
exceptions are raised after structured output is attempted. Lease release is
reported as attempted: the existing lease API does not certify release, and some
acquisition rejections retain only a diagnostic string.

`live_posts_guard_enforced` is true: normal Board loads require an actual valid
initialization guard and complete Present posts source before granting posts
write authority. Posts and auxiliary writers freshly revalidate the accepted
guard; guard-only observations do not authorize posts. A changed guard cannot
replace retained initialization history through repeated failed loads. Unknown
posts effects remain unsettled. This command performs only the explicitly
requested offline action; it does not initialize a running store automatically.

Writers that bypass the BasePath lease remain outside its quiescence contract.
Guard and posts observations are separate transactions. Path checks describe
observed boundaries; they do not make operations descriptor-relative, exclude
same-UID path races, or certify earlier unknown durability.
