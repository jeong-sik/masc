; Per-file dune stanza for the JSONL retention-window suite.

(test
 (name test_jsonl_retention_window)
 (modules test_jsonl_retention_window)
 ; jsonl_writer names the day files the prune pass test writes, so the
 ; fixture uses the writer's own layout rather than a copy of the format.
 (libraries alcotest masc_test_deps jsonl_writer))
