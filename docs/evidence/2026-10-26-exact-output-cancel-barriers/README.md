# Exact-output cancellation dispatch boundaries

Relates to #25860 and its consolidated #27842 scope. Base:
`4ecf1de7a6a324bf9e55818c496768053f5edc4e`.

Replace the existing outer-flow cancellation test's response-delay 0.1s and
cancellation-timeout 0.01s race with two explicit Promise-controlled scenarios.
Before dispatch, the real `before_dispatch` callback holds the allocated attempt
until its own cancellation context is cancelled. After dispatch, the local HTTP
server records the POST and holds its response before the same explicit
cancellation. A fixture timeout detects a stalled boundary; it does not select
which side of dispatch was reached.

Both cases check the original cancellation reason escapes, exact provider POST
and allocated receipt dispatch counts (0 before, 1 after), and the public whole-
flow generation-dispatch fact. Once cancellation returns, the next invocation
of the same frozen flow must be rejected as already started without another
POST. The after-dispatch case additionally checks the published receipt count.
The production affine executor's `Fun.protect` finalizer owns its Terminal state;
this control observes cancellation completion and replay refusal, not a direct
read of that private Atomic state.

The server's optional pre-reply hook is only a test fixture seam. No production
API, state, wire schema or dispatch policy changes. Other measurement/duplicate-
flow timing tests are outside this scoped repair and are not claimed fixed.
Six source hashes bind the case and inspected production contracts. Parsing and
whitespace checks passed. Selected execution and independent source review are
pending at record creation. No local Dune build/typecheck, full regression,
persistence/restart, live provider/connector, installation or deployment proof.
