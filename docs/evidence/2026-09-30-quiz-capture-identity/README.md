# Quiz identities follow immutable captures

The first repair refused grading an old question against a replacement deck.
A further review found that the question ID still omitted the captured deck:
an answerer who had graded the old question could not answer the freshly
captured question when the declared incarnation stayed the same.

Question and row IDs now include source ID, incarnation, fact ID and immutable
snapshot URI/SHA-256. Stable captures retain stable IDs. Different captures
produce distinct questions and preserve the old grade and its exact references.
The generic row helper is unchanged. Both Quiz manifests and worker metadata
use version 0.1.2; preparing their images and applying installations remain
separate work.

Actual measurements retained here:

- `stdio-tests.log`: 27 package-worker stdio scenarios pass, including old grade,
  rotated capture, new question, the same answerer and two correct grades with
  the old grade unchanged. Existing claim/namespace and large-reply cases pass.
- `original-grader-negative-control.log`: the three first-repair regression
  cases still fail against the original grader, using the current questioner.
- `original-workers-identity-negative-control.log`: the new identity journey
  fails against both original workers because the earlier grade blocks it.
- `shared-protocol-offline-tests.log`: 13 existing example-package cases pass.
  A full 14-case run hit a PermissionError while binding 127.0.0.1 in the
  remaining WebLayer case. The retained offline run explicitly excludes that
  case; its network behavior is unverified in this environment.

Commands, original commits, exact source hashes and exclusions are recorded in
`provenance.json`. The earlier 26-case first-repair evidence remains unchanged
in `../2026-09-30-quiz-snapshot-binding`, pinned by its source hashes and the
first candidate commit 5d1c20d90bd1bd28f6aecdcc3a35c709cd61c631.

These are Python worker tests with synthetic host-shaped inputs, without a
Docker image, native host, Keeper, live data mutation or CI build.
