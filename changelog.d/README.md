# Changelog fragments

A pull request adds its changelog entry here as `changelog.d/<PR number>.md`
instead of editing `CHANGELOG.md`. Two pull requests never write the same
file, so merging one does not make the other conflict.

```markdown
### Fixed

- A 429 carrying `Retry-After: 0` keeps its runtime candidate (#38130).
```

- Headings are `### <Section>`, one of: Upgrade notes, Fresh state required,
  Known issues, Added, Changed, Deprecated, Removed, Fixed, Performance,
  Documentation, Internal — or `Exempt` for non-user-facing pull requests (see
  [Fragment exemptions](#fragment-exemptions) below).
- Each bullet starts with `- `, may wrap onto following lines, and cites the
  file's own pull request number as `#<number>`. Entries are in English.
- `python3 scripts/changelog-fragments.py check` validates the fragments. On a
  pull request the required `changes` check validates the fragments that pull
  request adds or edits, and a malformed one blocks the merge.
- At release, `scripts/bump-version.sh` runs
  `python3 scripts/changelog-fragments.py assemble`, which folds every
  fragment into `## [Unreleased]` of `CHANGELOG.md` (grouped by section, in
  pull request order, duplicates dropped) and deletes the fragments.


## Fragment exemptions

Pull requests that change nothing a user can see — documentation, tests,
comments, compile repairs, or changelog-only work (such as a backfill PR whose
payload is another PR's fragment) — declare their exemption in their own
`changelog.d/<PR number>.md` file using the `### Exempt` section:

```markdown
### Exempt

- Docs only: clarify README wording; no user-facing behavior change (#54014).
```

- `### Exempt` cannot be combined with any release section in the same file.
- Every exempt bullet must state a non-empty reason alongside `#<number>`.
- A pull request that changes behavior, output, configuration, or an interface
  a user reads must use a normal release section instead of `### Exempt`.
- The required PR `changes` job and `changelog-fragments.py check` validate
  exempt fragments; `missing --strict` counts them as satisfied; at release,
  `assemble` deletes exempt fragments without adding them to `CHANGELOG.md`.
- `scripts/changelog-fragments-exempt.txt` is retained read-only for previously
  merged pull requests so concurrent exempt PRs never collide on a shared tail
  line. Do not append new PR numbers there. Unrecognized lines in that legacy
  file are reported on stderr and ignored.
