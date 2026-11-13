### Fixed

- `scripts/bump-version.sh` starts its missing-fragment scan at the commit
  that folded the last release (the first-parent commit that set
  `dune-project` to the tag's version) or at the point the release branch
  left the current branch, whichever is the ancestor of the other. It looked
  for the fold by commit subject, found none for v0.70.0 to v0.72.0 and
  scanned from the tag, which skipped pull requests merged between a fold and
  a later release-branch cut. When neither commit can be identified the bump
  now stops with the reason instead of scanning from the tag (#PENDING).
