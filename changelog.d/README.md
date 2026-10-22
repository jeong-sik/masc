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
  Documentation, Internal.
- Each bullet starts with `- `, may wrap onto following lines, and cites the
  file's own pull request number as `#<number>`. Entries are in English.
- `python3 scripts/changelog-fragments.py check` validates the fragments; CI
  runs it on every pull request.
- At release, `scripts/bump-version.sh` runs
  `python3 scripts/changelog-fragments.py assemble`, which folds every
  fragment into `## [Unreleased]` of `CHANGELOG.md` (grouped by section, in
  pull request order, duplicates dropped) and deletes the fragments.
- A pull request that removes an exact-output lane id from
  `lib/runtime/standalone_lane.ml` names that id in an `Upgrade notes` bullet
  (delete the `[runtime.exact_output_lanes.<id>]` table, and where the setting
  lives now). `python3 scripts/changelog-fragments.py lane-guard --base <ref>`
  checks it; a live `runtime.toml` is not rewritten by a release.
