# PR40936 retained integration execution

The audit row refers to the later 2026-10-04 integration run, not the historical
2026-10-03 browser frames. These are unchanged copies of its retained local logs:

- `build.txt`: focused TUI/decoder build output (warnings only; completion was
  recorded by the authoring session, not encoded in this output).
- `decoder.txt`: three Keeper usage decoder cases passed; other groups skipped.
- `usage-studio.txt`: all nine fixture journeys reached the final PASS marker.
  The log records executable SHA256
  `877596d7eeddb8158541953740bdaf2ed7c6599c6e2805095565dbed6f9b3c1d`.
- `usage-rows.txt`: resize/scroll fixture reached its PASS marker after its
  obsolete Transport-label wait was replaced by the actual coverage row.

The source at publication is `37637b7131d296acb02c751b9e478787e5a47210`,
with parent `157fd3b296aac435363c47773f968c98388b3b7e`. During this evidence
reconciliation, the retained worktree executable still matches the Studio log's
hash. The logs do not contain a complete source-tree-to-binary build receipt;
the row fixture also does not record its own executable hash. Do not describe
these files as independently proving an exact-commit reproducible build.
`manifest.json` hashes the preserved log bytes, not newly executed tests.

No tests were rerun for this documentation correction. The historical comparison
frames and their manifest are unchanged. No current browser replay, installed
runtime, hosted CI or production behavior is established here.
