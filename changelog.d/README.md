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
- At release, `scripts/bump-version.sh` adds the `## [<version>]` section and
  runs `python3 scripts/changelog-fragments.py assemble --into <version>`,
  which folds every fragment — together with anything still sitting in
  `## [Unreleased]` — into that section of `CHANGELOG.md` (bullets appended
  within their section, duplicates dropped, existing headings and their order
  untouched) and deletes the fragments. One run reaches the release section;
  nothing is moved by hand. Plain `assemble` (no `--into`) still folds into
  `## [Unreleased]`, and `assemble --into <version>` also serves a backfill:
  to fold late fragments straight into an already-shipped section, delete the
  fragments that release already folded first (below).
- `python3 scripts/changelog-fragments.py folded` lists fragments whose pull
  request already owns an entry in `CHANGELOG.md` — a terminal `(#<number>)`
  citation, which a passing mention inside another entry never is. A release
  that folds on its own branch and lands back on main as a squash leaves
  main's fragment files behind; assembling them again would duplicate their
  entries, so `bump-version.sh` refuses to fold while any remain.
  `folded --delete` removes exactly those files.
- `python3 scripts/changelog-fragments.py release-coverage --version <ver>`
  runs at release-candidate time (in `release-build.yml`'s `release-body` job)
  and verifies that every non-exempt pull request merged after the version-cut
  commit is cited in `CHANGELOG.md` under `## [<ver>]`. Unlike
  `missing --strict`, which checks pre-fold fragment presence when
  `bump-version.sh` runs, `release-coverage` catches late post-cut merges whose
  fragments were not folded into `## [<ver>]` or that merged without a fragment.


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
