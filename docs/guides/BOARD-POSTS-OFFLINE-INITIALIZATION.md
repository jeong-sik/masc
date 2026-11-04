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

`live_posts_guard_enforced` is false: normal Board loads and writes do not read
the initialization guard. The first load of a workspace without a posts file
starts from an empty source. Once a running store has observed an actual posts
file, a later absence of that file is refused. Posts and auxiliary writers
revalidate the workspace of the observation they act on. Unknown posts effects
remain unsettled. This command performs only the explicitly requested offline
action.

One positive recognition path is narrower than creation: an exact Fusion-origin
replay may return a matching row already in memory, including one a partial
load kept. Matching the row neither directly accesses source files
nor publishes a new row, and grants no posts authority, negative evidence,
operation receipt or durability guarantee. The call still runs ordinary
maintenance scheduling before lookup; a separate flusher may process the
queued sweep or flush work.
A different Fusion run still requires ordinary admission before creating a row.

An observed reserved cleanup cause stops later selected snapshot writes. The
attempted write retains its actual result; every unattempted snapshot remains a
retry obligation without an invented error. Diagnostic counters are retained
before propagation, without invoking logging after the reserved cause.
Votes and reactions use the existing posts retry group: a separate retry may
exact-CAS rewrite current posts while finishing those pending ledgers. This
preserves logical post/deletion state and does not create another post.

Writers that bypass the BasePath lease remain outside its quiescence contract.
Guard and posts observations are separate transactions. Path checks describe
observed boundaries; they do not make operations descriptor-relative, exclude
same-UID path races, or certify earlier unknown durability.
