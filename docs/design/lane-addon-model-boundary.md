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

## Remaining Lane/Fusion wiring

- Declare model access explicitly in the package interface and resolve its
  host-owned model route from installation TOML. The generic MCP callback does
  not automatically grant Add-ons model access.
- Register the callback only for the exact installed package with model access.
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
