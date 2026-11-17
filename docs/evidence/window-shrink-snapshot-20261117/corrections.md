# Evidence response notes

The original source and evidence reviews are retained with their original
snapshot hashes. Later wording and fixture repairs do not rewrite those
earlier reviews.

- The two evidence findings in `review-response-r1.json` are resolved by the
  executed `cost-r4` source: the baseline full fold is unconditional, and the
  working/unread fixtures use `Agent_instruction` with positive predicate
  assertions. `review-response-r2.json` independently verifies the fixes and
  the corrected statistics. The entire earlier cost series stays superseded.
- The README wording reported in r2 now explicitly says no **live runtime**
  profile or forced-GC request occurred. Owned weak-root tests and benchmark
  collections are described separately. No runtime-GC observation is inferred.
- The cost review's README snapshot was followed only by an adapter-report
  link and clarification that the archive map is not a closed dependency
  graph. A later paragraph links the cost/response reports. The source,
  measured rows and calculated results are unchanged.
- The later adapter attempts are both failed compilation attempts with zero
  actual adapter calls. Their incompatible dependency assumptions do not
  invalidate the distinct earlier successful typing receipt, nor establish
  an executed adapter or installed candidate.

Source commit `8509f161b1d498fbc0001c3fdfae047b012de3b6` contains the exact seven
final source/test blobs reviewed by the response and cost reviewers. Any
later changelog-only head must be checked against these same blobs before
reusing their source and measurement findings.

## Correction: maintained test dependency visibility

Merge compile run `44083963891`, job `134041528895`, failed for
`30123545d27f87309c640efbb335ebf6b74e3b5a` because the new test named the
wrapped Keeper codec as a bare module. Earlier Window+codec alias checks missed
the declared-library visibility error. They did not prove that the original
maintained test compiled as declared. The codec is not explicitly listed in
`lib/dune`'s `private_modules`.

Commit `2d580ed1dd08efb8417e349941018f7aa5998e61` changes only that test's
renderer to the public Checkpoint JSON encoder. Product four files and the
other two tests retain their original blobs; the claim that all seven blobs
are unchanged no longer applies. The README and `ci-test-correction.json`
record the new unmodified-test typecheck with CI include visibility, original
failure reproduction and separate Window-only-alias 41-test execution. No old
receipt is rewritten, no performance recapture is claimed, and current-head CI
was not rerun by this repair.
