# Dashboard observations and operation quota

The installed `2578d7fec3061b0a8a05301eb465ae0521ce5461` runtime returned five
per-agent 429 responses during normal Keeper workspace hydration. Four were GET
API reads; the fifth was a dashboard JavaScript asset. `observed-before.json`
preserves the allowlisted failing paths, without credentials or private content.

The H1 ingress charged every bearer request against the same agent bucket,
including static assets. Protected read handlers then charged that bucket again.
Product defaults are unchanged: the agent bucket has a 50-request burst and
20 requests/second refill; the per-IP bucket has a 150-request burst and
100 requests/second refill.

The repair uses the existing exact MCP transport route/method classifier at H1
ingress. Other API operations are charged by their authorization wrappers.
Already-classified read endpoints use a shared typed GET/HEAD observation policy
in H1 and H2. Authorization, IP ingress checks, MCP/SSE admission and stream
resource boundaries are unchanged.

`test_dashboard_observation_quota.py` starts a real CI-built server with isolated
configuration and no provider calls. It performs a burst of 60 asset reads and
four authenticated API reads, then checks that all four configured operation
tokens remain available for actual MCP `masc_status` calls. A fifth MCP request
and a mutation route must receive the agent 429 while GETs remain available.
Invalid credentials must still fail, and subsequent asset reads must exhaust the
separate IP bucket. Zero-refill fixture settings make those assertions independent
of elapsed time; no sleeps or 429 retries occur in the burst.

The repaired fixture passed the complete H1 scenario against the existing
macOS arm64 executable from CI run `34692595258`, source `94276567e4`, whose
production code is unchanged by the fixture repairs. The binary SHA-256,
fixture SHA-256, exit status and requests are in `native-artifact-proof.json`.
This used a downloaded CI artifact in an isolated workspace, with no local
build. Python syntax and diff checks also passed. Linux exact-head CI is
dispatched separately. H2 source uses the same method policy but this fixture
does not establish an H2 wire result. No installed runtime or live configuration
was changed.
