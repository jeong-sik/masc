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
- Added bullets carry a usage guide chapter or the spelled-out guideless
  marker. Spell that marker in Korean as
  `가이드 없음(<target doc or 문서 없음>)`; the release counter also
  recognises the legacy English `No guide yet (` spelling but new notes
  should use the Korean one.
- `python3 scripts/changelog-fragments.py check` validates the fragments; CI
  runs it on every pull request.
- At release, `scripts/bump-version.sh` runs
  `python3 scripts/changelog-fragments.py assemble`, which folds every
  fragment into `## [Unreleased]` of `CHANGELOG.md` (grouped by section, in
  pull request order, duplicates dropped) and deletes the fragments.
