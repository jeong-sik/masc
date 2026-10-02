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

The integration suite exercises an actual Python MCP subprocess with an empty
environment: initialization capability, exact request text and output limit,
host-selected response/model, host refusal, and disabled sampling. Native
execution remains pending CI. The supplied answer is fixture data, not model
execution or Docker isolation evidence.

## Remaining Fusion computation and verification

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
execution. Native CI remains pending. The installation-owned route and durable
request broker are wired by the server factory described below; manifest mode
alone does not grant a provider route.

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
offloaded from the Eio owner domain. The worker stdio scenario inspects durable
request bytes inside the invocation callback, reads actual response/error records,
and exercises pre-invocation bounds and post-invocation retention uncertainty.
The model response remains synthetic fixture data and native execution is pending
CI. Provider execution and carrying these references into package output
publication still require verification.

## Server runtime connection

The runtime now passes the exact validated installation binding to worker
startup. Model-capable workers request a sampling callback from the registered
server factory; disabled workers do not consult it. Server bootstrap registers
the factory before declaration maintenance starts.

The factory is bound to the registering workspace's Lane store and reads only
the explicit installation `binding.model_route` for routing. It resolves that
route against the loaded runtime configuration and walks its declared candidates
in order. Package model hints do not choose a different host route. The durable
broker surrounds each invocation; successful response metadata identifies the
actual runtime and model and retains earlier failed candidate details.

The installation's binding must include `model_route`, and its package binding
schema must accept that field. This selects an existing runtime assignment; it
does not create a route or grant credentials. For example, an installation can
bind `model_route = "lane_panel"` to a host declaration:

```toml
[runtime.lanes.lane_panel]
candidates = ["local.primary", "local.secondary"]
```

Both runtime candidates must already exist in the host configuration. An absent
or unknown route is a configuration issue before an instance is persisted or a
container is created. Validation constructs and discards a side-effect-free callback
with the proposed instance identity; actual worker startup constructs its callback
with its own lifetime switch. Updating the runtime route lets the unchanged
installation recover on the next reconciliation. The example
names are illustrative, not installed routes.

Native Agent Core requests use the runtime's inference-seeded provider binding,
requested output limit, supplied system prompt, and text/image messages. A
model-declared operator temperature wins; otherwise the request value is used.
Thinking-only responses are empty at this text boundary and continue to the next
declared candidate while retaining the provider stop reason. Unsupported stop sequences and sampling tools are refused. A passed
temperature is not a guarantee that the selected model applies it. Standard MCP
stop reasons are projected explicitly; other provider stop details remain in
metadata. No provider credential/configuration enters the package payload.

Official-client adapters currently lack a per-request output-limit channel,
required by the sampling request. Those candidates are refused before model I/O;
only a next candidate already declared in the route can be tried. Extending the
owner APIs remains necessary for full official-runtime support. This is an
explicit support gap, not a provider-free completion claim.

The authored server integration scenario uses a loopback HTTP provider fixture.
It checks the serialized system/text/image input, output limit and temperature,
HTTP refusal or thinking-only maxTokens followed by the declared secondary,
fixed model temperature overriding a supplied or omitted request value, actual response identity,
request retention before HTTP, terminal references, and rejection without I/O.
It invokes the same production handler assembly used by server registration.
Native execution remains pending CI. It does not establish live provider calls,
container enforcement, or production agent use.
