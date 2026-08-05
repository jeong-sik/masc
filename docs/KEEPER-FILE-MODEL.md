# Keeper file model

Each configured Keeper has exactly two authored files under the resolved MASC
config root:

```text
<config-root>/
  keepers/
    <name>.toml
    <name>/
      AGENT.md
```

`<config-root>` is `MASC_CONFIG_DIR` when explicitly set. Otherwise it is
`<base-path>/.masc/config`.

## `keepers/<name>/AGENT.md`

`AGENT.md` is the Keeper's complete individual prompt. Its full UTF-8 content
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
sandbox_profile = "local"
mention_targets = ["operator"]
allowed_paths = ["workspace/yousleepwhen/masc"]
```

Current `[keeper]` fields:

- `name`
- `autoboot_enabled`
- `mention_targets`
- `proactive_enabled`
- `allowed_paths`
- `sandbox_profile`
- `sandbox_image`
- `network_mode`
- `multimodal_policy`
- `active_goal_ids`
- `max_context_override`
- `telemetry_feedback_enabled`
- `telemetry_feedback_window_hours`
- `always_allow`
- `[keeper.oas_env]` scalar entries

Any other TOML key fails closed as `unknown keeper TOML keys`.

## Runtime and tool context

Runtime assignment lives only in `runtime.toml` under
`[runtime.assignments]`. Tool definitions do not live in Keeper files. OAS
supplies the current tool schemas separately for each turn, so `AGENT.md`
should describe behavior and boundaries without copying a tool catalog.

## Creation and update

`masc_keeper_up` accepts `name` and, for first creation or an explicit prompt
update, `instructions`. Persistence writes operational values to
`keepers/<name>.toml` and writes the prompt atomically to
`keepers/<name>/AGENT.md`.

```text
masc_keeper_up(
  name: "reviewer",
  instructions: "Review the current change and report concrete evidence.",
  sandbox_profile: "local",
  autoboot_enabled: true
)
```

The system-owned runtime snapshot remains separate under the Keeper state
directory. It is not an authored configuration source.
