# Backlog encoding worker evidence

The source change sends only snapshot JSON projection, UTF-8 sanitization and
pretty encoding through the shared CPU helper. Writes, revision stamping,
cache invalidation and callbacks remain on the caller. Source-head focused
CI passed 148 cases, including the pooled UTF-8/copy/revision/callback scenario.

The [completed Linux comparison](comparison/README.md) retains all 2,400 timed
requests and shows mixed results without a consistent latency benefit. The
PR is held as draft. The first execution GET's p95 was higher in all four
conditions, and concurrent liveness did not consistently improve. This is
not a general causal regression claim, and no production change is inferred.

The 0.1 ms goal remains unmet. Source correctness, compiled tests, generated
artifacts, fixture behavior and operating-runtime performance are separate
claims; the evidence here covers the first four within its documented scope.
