# Model access for isolated Lane packages

The next Fusion execution boundary uses standard
[MCP sampling](https://modelcontextprotocol.io/specification/2025-06-18/client/sampling):
the package sends a typed `sampling/createMessage` request over its existing
stdio connection. The host chooses model access and returns the response.
Provider credentials and model-runtime configuration do not enter the package.

## Implemented connection primitive

`Agent_core.Mcp.connect` accepts an optional typed `sampling_handler`. It
registers the callback with the pinned MCP client's implementation before
initialization. Only connections with this callback advertise sampling.
Unconfigured requests receive the SDK's protocol error. Host refusals return
an error to the requesting process rather than an invented model answer.
Callback exceptions also return protocol errors, preserving subsequent tool
framing; Eio cancellation still propagates to the caller.

The integration suite exercises an actual Python MCP subprocess with an empty
environment: initialization capability, exact request text and output limit,
host-selected response/model, host refusal, and disabled sampling. Native
execution remains pending CI. The supplied answer is fixture data, not model
execution or Docker isolation evidence.

## Remaining Lane/Fusion wiring

- Resolve the host-owned model route from installation TOML and supply the
  production callback. Package model-access declaration and worker-level
  callback admission are implemented below; they do not resolve a provider.
  Keep provider keys on the host and the worker's existing network isolation.
- Retain the model request before calling the provider, then retain actual
  model/runtime response identity, errors and source references separately.
- Connect panel and judge computation through named outputs. A panel failure
  remains a failure and preserves available evidence. Completion does not
  publish a report or message implicitly.
- Test the deployed container boundary, provider-backed computation, immutable
  output composition, explicit report/Broadcast delivery, and actual agent
  reading and use. Current stdio and Python fixture checks cannot establish
  those stages.

The pinned SDK invokes sampling callbacks while reading the tool response.
A callback must not recursively call the same MCP connection. Parallel panel
execution needs separate worker connections or an upstream asynchronous
sampling dispatcher; this primitive alone does not prove parallel fan-out.

## Package and worker access contract

The package manifest can declare `[interface] model_access = "host_sampling"`.
The typed alternative is `"disabled"`; omission also disables model access.
Unknown strings and booleans are rejected. Inspection serializes this mode,
and it participates in the package's semantic configuration revision.

`Lane_addon_worker.start` accepts the host callback only when the package
declares host sampling. A declared requirement with no callback, or a callback
supplied to a disabled package, is rejected before container creation. The
matching pair registers the callback before MCP initialization. Docker's
network isolation and environment arguments are unchanged.

The worker scenario uses real subprocess/stdio with a hermetic Docker control
fixture. It checks both rejected mismatches, capability advertisement, a
model request reaching the callback, and the returned host model identity.
It verifies requested isolation flags, not kernel enforcement or provider
execution. Native CI remains pending. The production runtime still needs its
installation-owned route/callback and durable request evidence bridge; merely
setting the manifest mode does not wire a provider.

## Retained host model requests

`Lane_addon_sampling.create` wraps a host-owned invocation callback for one
declared package, exact worker instance and explicit route. It retains the
sampling request before calling the callback and passes that immutable request
reference to the host. It then retains the actual response or error as a separate
record linked to the request. Provider credentials/configuration are outside
the callback's sampling payload and are not serialized by this boundary.

Successful sampling responses carry request/outcome references under
`_meta["masc.lane_sampling"]`. Host errors remain neutral `host_error` outcomes;
the string-error callback cannot establish whether an error was a policy refusal
or a provider failure. Unexpected invocation exceptions are `outcome_unknown`.
Error responses expose that status inline because a container cannot read the
host's evidence store. Cancellation propagates after a returned outcome has
been validated and indexed; interrupted invocations retain their pending request.
If terminal retention fails after invocation, package replies expose only a neutral
status. Host recovery indexes preserve the request and any terminal outcome; their
retained evidence is authoritative about whether the call returned. The first
terminal index includes exact outcome bytes before blob publication, allowing
recovery to restore an interrupted blob write without repeating the model call.

The package's existing byte envelope bounds request and outcome retention.
A request that cannot be retained is not invoked. Host filesystem writes are
offloaded from the Eio owner domain. When an error response or its inline
evidence references exceed the package envelope, the boundary returns a compact
bounded refusal without repeating the unbounded payload, preserving durable
terminal storage and index recovery. The worker stdio scenario inspects durable
request bytes inside the invocation callback, reads actual response/error records,
and exercises pre-invocation bounds and post-invocation retention uncertainty.
The model response remains synthetic fixture data and native execution is pending
CI. Installing provider routes in the production runtime and carrying these
references into package output publication are still required.
