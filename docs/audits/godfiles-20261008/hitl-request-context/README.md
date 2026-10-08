# HITL judgment request/context owner, 2026-10-09

Parent: `d2c318d470b5d388fb04848606c8af5527271833` (#41987).
Issue: [#41857](https://github.com/jeong-sik/masc/issues/41857).

`Hitl_summary_worker` combined exact-output execution and durable queue
terminalization with request JSON construction, thinking retention, host-observed
context acquisition and domain response parsing. `Hitl_summary_request` now owns
that domain boundary. The worker calls it directly before flow admission and
from HTTP and CLI success validation. The existing test consumer calls the same
owner directly; two testing-only forwarding exports are removed.

The public acquisition entrypoint reads `Keeper_gate_host_context.for_approval`
once and reads thinking retention only when request context is present. The
private projection receives these captured values; it does no configuration,
repository, filesystem, prompt or queue reads. Host observation remains before
configuration acquisition, including observation for context-less requests.
The request-identity allocation is now after acquisition; that moved allocation
uses only pure codecs and immutable entry fields. The bundle's fields, ordering,
exact input/refusal/context, partial-context semantics, thinking selection and
omission count remain unchanged. Neither this projection nor the domain parser
authorizes an external effect or mutates an approval.

The worker's prepared flow still stores the captured bundle. HTTP candidates
and CLI fallback reuse it; this extraction does not reread host facts on retry.
The summary version, generation time and exact run identity remain caller/host
owned. Domain-invalid judgment data remains an explicit error through the same
canonical decoder. Candidate admission, grants, completion/fsync, cancellation,
queue settlement and worker lifecycle stay in the existing execution owner.

`Hitl_summary_worker.ml` changes from 2,066 to 1,883 lines. The new owner is
192 lines. [extraction.json](extraction.json) records body comparisons: thinking
helpers and domain parser match exactly, request projection matches after lifting
the two acquisition calls and changing its signature, and remaining worker
matches after declared extraction/direct-call/forwarder/comment edits.
[source-sha256.json](source-sha256.json) fingerprints the five changed source
files and six unchanged helpers/interfaces inspected for acquisition and decoding.

## Direct checks

| Changed boundary | Existing direct consumer / meaningful behavior | Executed result |
| --- | --- | --- |
| Context acquisition and pure projection | Exact input, optional refusal, real repository/task/destination facts, partial context, thinking retention and omission | Domain cases 2-12 passed |
| Domain response decoder | Typed judgments and invalid judgment rejection | Domain cases 0-1 passed |
| Worker flow preparation and HTTP success validation | Context-less admission, closed schema, actual canonical request over a loopback fixture server | Domain cases 13-15 passed |
| Prepared request and CLI validation | Catalog exhaustion, CLI-only flow, malformed HTTP response fallback, domain-invalid CLI advancement with durable dispatch identities | CLI cases 1-4 passed |

[checks.json](checks.json) records terminal exit codes, exact selections and the
executable SHA256. The final focused build succeeded. An initial focused build
also succeeded; the final build incorporated a section-comment relocation made
while the initial build was running. Both are scoped to the one direct-consumer
executable and compile its necessary dependencies, not all Dune targets.

The existing sixteen domain and four CLI cases all passed. Assertions, payload
variants, real local storage reads and durable completion checks are preserved.
Skipped cases are not counted. No new source-shape or extraction-mirroring test
was added. These are temporary-workspace/loopback/injected-CLI fixtures, not a
live provider call or deployed Keeper judgment.

## Remaining scope

This is one bounded partial repair among the original 171 candidates. Falling
below 2,000 lines is not a semantic completion verdict. Other HITL exact-output
execution, identity/rejection, persistence, CLI walk, concurrency and lifecycle
responsibilities and the rest of the large fixture still require semantic review.
Full suites, full builds, CI, live startup recovery, deployment and runtime
continuity are unverified here. No live approval, queue, operation or Keeper
configuration was changed.
