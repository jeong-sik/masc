# Original Curator validation in the common Exact flow

E02 now has a mandatory trusted host validation port in `Lane_addon_exact.run`.
The existing Runtime registration carries the runner and this authority together;
server bootstrap installs both. No worker field or optional Hook selects the
authority. This adds no provider client, route registry or background owner.

The server's `Server_workspace_memory_addon_validation` binds the reserved
`workspace-curator` package and `curate` exported tool to classification and
briefing captures. `request` creates the original common Exact request with the
same host UUID, distinct `classification` or `briefing` output, one complete
captured rendered prompt and its original schema. The future package must use
that request unchanged. This contract is host code, not a worker's claim.

Before resolving a lane or writing a started attempt, the common Exact owner
asks the trusted host to resolve validation. The server strictly loads the
original capture, observes the current physical workspace, restores the captured
batch/template/schema, and checks its original installation/package/tool and
the full Exact request digest. Configured and manual installation identities use
the same `Lane_addon_tool_request_owner.installation_id` codec as Runtime retention
and worker-state ownership. A configured declaration's bare route ID is not its
retained installation identity.

Every Exact request checks the original Curator namespace. An existing capture
cannot escape validation by relabeling its package. A missing capture is allowed
for another package, whose existing package/request baseline still applies, but
is refused for `workspace-curator`. Read failure remains an error. This adds one
strict namespace lookup to other packages too, including the name-enumeration
cost described in [original request discovery](addon-original-request-discovery.md).
Corrupt Curator authority can consequently stop other Exact requests rather
than silently authorize a possible original request. This is not a latency claim.

Once bound, the returned validator is pure: `Capture.validate_output` decodes the
complete original classification decision and applies it to the captured ledger,
or decodes and accepts a briefing against its captured pass. It produces no save,
publication, observer completion or dispatch permission. The common Exact owner
first checks the mandatory package/request shape, then this domain validation.
Both HTTP `Reject_and_advance` and the original official-client CLI walk receive
the composed check before accepting a candidate. A domain-invalid answer is
rejected within the original request, without resetting candidate order or
retaining it as an answered terminal.

Every replay resolves host authority again and revalidates an answered terminal.
Missing/conflicting authority returns an error without changing the original
terminal. A previously retained schema-only answer that fails domain validation
is delivered as `Invalid_output`; it is neither committed nor sent again.
Started-attempt uncertainty and immutable request digest fences remain intact.

The five new scenarios in `test_lane_addon_exact_runner` use actual common Exact
storage and the real HTTP runner against loopback providers. They cover full fact
coverage, a valid-shaped decision joining a nonexistent original claim across
HTTP/CLI candidates, strict missing/changed/foreign workspace/installation and
package identity, retained schema-only rejection, and blank briefing rejection.
Only the official-client process edge is injected. Source parsing and independent
source review are separate from compiled execution, which must be recorded for
the actual candidate head.

The production Curator owner, worker package, accepted-work wake, domain commit
recovery and actual Off/reconnect/UI evidence are still required by E02. Captured source/configuration revisions are preserved; this port does not prove
that production metadata was collected correctly or that current export authority
is unchanged. Runtime owns live connection/selection checks, and the future
serialized Curator consumer still owns fresh authority before effects. This
port does not switch the current direct Curator execution or finish its extraction.
