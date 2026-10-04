# Owned evidence and stdio readiness integration — Native Stack #40961

Integrated the independently reviewed #40960 owned-evidence repair and #41033 shared startup recovery into every actual downstream published head. All merges were clean. Normalized per-PR additions match the reviewed patches exactly; original descendant features, bounded query accounting and the full RPC envelope owner remain intact. #40943 is unchanged; #40981 remains Draft.

Focused OCaml 5.5.1 wrapper builds used DUNE_JOBS=2. The seven direct-consumer suites passed **141 tests**: worker, server sampling, receipt recovery, Lane Add-on runtime, source adapters, retained sequence queries and Agent Core MCP integration. The sequence-query suite exercises the shared reader's Sequence branch in addition to sampling Blob paths. Executions used their built test directories and declared isolated test environment. The stdio executable also linked; it was not launched.

checks.json records the exact tested source/tree, original parent mapping, commands' targets/working directories, binary identities and raw logs. The individual actual RED/GREEN records remain in the two #40960 response directories. The #41033 evidence distinguishes its source-order assertion from actual journal execution. This combined-leaf result does not establish separate execution of every PR head, malicious concurrent directory replacement protection, a full suite, hosted CI, live provider, deployment or release.

The separate P1 full-history maintenance scan remains open and is being repaired independently; it is not hidden by this readiness change.
