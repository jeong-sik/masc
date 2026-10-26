# Native MiniMax Responses (experimental)

Use this setup with a build that includes the `minimax_responses` catalog
provider. The native Chat provider `minimax` is a separate protocol identity.
Offline replay and request-contract checks have passed; live MiniMax HTTP,
installed Keeper operation and production compatibility have not been verified.
This guide does not enable a provider or change any running workspace.

## Configure an explicit binding

Use your workspace's `<base-path>/.masc/config/runtime.toml`, through the normal
runtime configuration flow. See the [TOML reference](../RUNTIME-TOML-REFERENCE.md)
and [reload matrix](../TOML-RELOAD-MATRIX.md). Append or merge these tables into
that configuration; this snippet is not a replacement for the existing file.
Keep any existing lane selections until the candidate has been verified.

```toml
[providers.minimax_responses]
display-name = "MiniMax Responses (experimental)"
protocol = "openai-compatible-http"
endpoint = "https://api.minimax.io"
request-path = "/v1/responses"

[providers.minimax_responses.credentials]
type = "env"
key = "MINIMAX_API_KEY"

[models.minimax-responses-m3-1]
api-name = "MiniMax-M3.1-Flash"
max-context = 1000000
tools-support = true
thinking-support = true
streaming = true
reasoning-effort = "max"

[minimax_responses.minimax-responses-m3-1]
```

`MINIMAX_API_KEY` must be available to the server process, through its service
or shell environment. The TOML stores the variable name, not its secret value.
A key exported in a different terminal is not automatically available to an
already running service. Do not paste the key into this document or commit it.

Keep the provider id `minimax_responses`: the catalog binds that identity to the
native endpoint, required API-key authentication, model capabilities and replay
contract. The local model id `minimax-responses-m3-1` is an operator label;
`api-name` is the exact model id sent to MiniMax. No inline capability override
or vendor-name inference is needed. The resulting slot id is
`minimax_responses.minimax-responses-m3-1`; select it only where you intend to
trial this experimental runtime. Adding the tables alone does not replace the
fleet's selected slots.

## Supported candidate scope

The [official Responses schema](https://platform.minimax.io/docs/api-reference/text/api/openapi-responses.json)
directly names `MiniMax-M3` and `MiniMax-M3.1-Flash`. This candidate declares
only those two Responses models. Exact M2 Responses identities remain
unverified; the Chat model list is not a Responses availability list.

| Model | Reasoning control |
| --- | --- |
| `MiniMax-M3.1-Flash` | Always reasons. The example explicitly chooses `max`; the declared depths are `low`, `medium`, `high`, `xhigh`, `max`. Omission leaves the vendor default. `none` and disabling reasoning are refused. |
| `MiniMax-M3` | Non-`none` effort enables reasoning; it does not select a depth. The default is off unless reasoning is enabled explicitly. |

The documented Responses tool selection is `auto`. Required or named-function
selection is not declared. The SDK's typed `None_` selection creates a local
tool-free request rather than sending an undocumented wire `none` value.
This does not establish what the separate Chat endpoint accepts: its
[official guide](https://platform.minimax.io/docs/api-reference/text-openai-api)
and schema do not specify that tool-choice range.

Native Responses replay preserves the declared reasoning text across cache and
canonical message persistence, then emits it in the next Responses input.
Reuse only reasoning with the matching producing-source and consuming-request
contract. Changing endpoint/protocol is not permission to reuse opaque reasoning
from a previous source.

## When a trial fails

- An absent `minimax_responses` catalog provider means the build does not carry
  this candidate. Editing runtime TOML cannot add a missing SDK declaration.
- An unset declared environment variable or unavailable credential is surfaced
  before dispatch; configure the server's environment rather than changing the
  provider identity to bypass authentication.
- Unsupported effort, disabling M3.1 reasoning, required tool choice or named tool
  choice is a contract/admission refusal. Do not add capability overrides to
  make the unsupported request appear valid.
- A vendor HTTP refusal or uncertain dispatched outcome remains an observed
  failure. The offline fixtures are not evidence that a live request succeeded.

To stop using the candidate, remove its slot from the selected Keeper/lane
configuration through the normal runtime configuration flow. Once nothing
references the slot, remove the example binding, its dedicated model table and
provider/credential tables if they have no other users. Remove the environment
credential from the service if it is no longer needed. Do not delete durable
conversation or replay evidence as a way to disable a runtime.

## Evidence and limits

[The binding evidence](../evidence/2026-10-25-minimax-responses-binding/README.md)
records failed candidates and the corrected 42-case public contract run:
native binding/admission 4, sync replay 16 and SSE replay 22. It includes actual
cache/message-file/serializer assertions, not vendor HTTP or a complete Agent
restart. [Issue #27924](https://github.com/jeong-sik/masc/issues/27924) tracks
integration, Chat tool-choice and model-availability residuals.

This guide's TOML was checked for syntax and against the current parser,
catalog and adapter source. It has not been applied to a live workspace or
executed through the Runtime TOML loader. There is no new live-provider,
Dashboard, installation, full-regression or deployment claim.
