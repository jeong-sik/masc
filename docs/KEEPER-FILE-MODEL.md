# Keeper file model

Each configured Keeper has exactly two authored files under the resolved MASC
config root:

```text
<config-root>/
  keepers/
    <name>.toml
    <name>/
```

`<config-root>` is `MASC_CONFIG_DIR` when explicitly set. Otherwise it is
`<base-path>/.masc/config`.

## `keepers/<name>.toml` — `keeper.instructions`

`keeper.instructions` is the Keeper's complete individual prompt. Its full UTF-8 content
is loaded into `keeper_meta.instructions` and included in autonomous turns.

The file is mandatory whenever `keepers/<name>.toml` exists. Missing, empty,
or placeholder content is a typed profile error. Prompt text is not accepted
inside Keeper TOML.

## `keepers/<name>.toml`

The TOML file contains operational configuration only. The filename is the
canonical Keeper name; `[keeper].name` is optional.

```toml
[keeper]
autoboot_enabled = true
proactive_enabled = true
sandbox_profile = "docker"
mention_targets = ["operator"]
```

Current `[keeper]` fields:

- `name`
- `autoboot_enabled`
- `mention_targets`
- `proactive_enabled`
- `sandbox_profile`
- `sandbox_image`
- `network_mode`
- `max_context_override`
- `telemetry_feedback_enabled`
- `telemetry_feedback_window_hours`
- `always_allow`
- `[keeper.agent_core_env]` scalar entries

Any other TOML key fails closed as `unknown keeper TOML keys`.

## Runtime and tool context

Runtime assignment lives only in `runtime.toml` under
`[runtime.assignments]`. Tool definitions do not live in Keeper files. agent core
supplies the current tool schemas separately for each turn, so the prompt
should describe behavior and boundaries without copying a tool catalog.

An official Codex subscription runtime declares a CLI transport and no
credentials. The Codex CLI owns ChatGPT login; MASC removes API-key variables
from the child environment and refuses non-subscription accounts. Model IDs
containing dots must be quoted as TOML table keys.

```toml
[providers.codex_subscription]
display-name = "Codex ChatGPT Subscription"
protocol = "codex-app-server"
command = "codex"
is-non-interactive = true

[models."gpt-5.3-codex-spark"]
api-name = "gpt-5.3-codex-spark"
max-context = 131072
tools-support = true

[codex_subscription."gpt-5.3-codex-spark"]

# A Keeper assignment must still name a materialized runtime. To add ordered
# failover, give the lane the same ID; runtime resolution prefers the lane.
[runtime.lanes."codex_subscription.gpt-5.3-codex-spark"]
candidates = [
  "codex_subscription.gpt-5.3-codex-spark",
  "glm-coding.glm-5-turbo",
]

[runtime.assignments]
sangsu = "codex_subscription.gpt-5.3-codex-spark"
```

The fallback candidate must already be a valid binding in the same file.
There is intentionally no `[providers.codex_subscription.credentials]` table.
An unspecified reasoning effort is omitted from the app-server request so the
official client can choose a value supported by the selected model. MASC does
not project the provider-neutral `enable_thinking` toggle into official
clients. A hook that needs control must supply a typed `reasoning_effort`;
supplying `enable_thinking` at that boundary fails before dispatch.

## Creation and update

`masc_keeper_up` accepts `name` and, for first creation or an explicit prompt
update, `instructions`. Persistence writes operational values to
`keepers/<name>.toml` and writes the prompt atomically to
`keepers/<name>.toml`.

```text
masc_keeper_up(
  name: "reviewer",
  instructions: "Review the current change and report concrete evidence.",
  sandbox_profile: "docker",
  autoboot_enabled: true
)
```

The system-owned runtime snapshot remains separate under the Keeper state
directory. It is not an authored configuration source.
