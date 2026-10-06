# Native #41052 consumed-fragment scope

Current five-member Native Stack retains its release-parent anchor and branch identities. #41018 is unchanged; documentation corrections begin at #41037 and propagate through #41040/#41043/#41045 with real local parent merges. No published history, source, release notes or tag is rewritten.

The official v0.49.0 release points to `8304fa2124ca3100958f6df8fb512963538678ab` and was published at2026-10-04T08:03:19Z. Its detailed notes already record #41040, #41043 and #41045, and partial-roster Item behavior under #40313/#41069. Current #41040/#41043 own diffs are solely restored fragments; #41037 and #41045 add only evidence/documents beside fragments. `62e106bfdc3a67aff06aa6908a2984d08f16505d` previously removed the consumed #41043/#41045 fragments.

`bump-version.sh` invokes the actual fragment assembler. Its deduplication compares only Unreleased and current fragments, not prior releases. The old targeted assembly consequently advertises these product repairs again. The corrected targeted assembly contains only #41037’s historical evidence/documentation addition; consumed #41040/#41043/#41045 product fragments stay absent. The actual tag’s #41043 bullet is shorter than the current parent’s archived full text, so this proof does not falsely claim those strings identical. Removal is supported by its already published entry, explicit consumed deletion and current zero implementation/fixture delta.

All five product-source trees (all tracked paths except docs/ and changelog.d/) are byte-identical to their respective published baseline heads. The real parent ancestry is verified. Historical native/PTy proof remains tied to its original qualified source and binaries; there was no new native build, behavior run, hosted CI, Full RC, release selection or TerminalBench execution.

Four raw logs preserve actual selected-fragment assembly before/after, fragment syntax check and four per-PR guards. Assembly uses temporary copies of CHANGELOG and only the four affected owner fragments; it never edits the repository’s published notes. This is targeted changelog validation, not a claim that every other fragment in the repository has been audited.

```sh
python3 scripts/changelog-fragments.py check --dir <selected-fragment-directory>
python3 scripts/changelog-fragments.py assemble --dir <selected-fragment-directory> --changelog <temporary-CHANGELOG>
python3 scripts/changelog-fragments.py pr-guard --base <prepared-parent> --head <prepared-child>
```

The final local head/parent/tree mapping is supplied separately to the publication reviewer; checks.json pins baseline heads, unchanged product-tree digests and raw logs without inventing a fresh product test result.
