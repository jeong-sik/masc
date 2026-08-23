# Keeper user manual

Keeper is MASC's persistent autonomous agent unit. A Keeper has one canonical
name and one TOML declaration that carries everything, prompt included.

<!-- BEGIN GENERATED: agent-core-pin-manual -->
The typed agent engine is built from `packages/agent_core` as the internal
`masc.agent_core` library. It has no external opam pin or separately released
SDK version; the MASC commit and build identity are the source of truth.
<!-- END GENERATED: agent-core-pin-manual -->

## Configure a Keeper

For Keeper `reviewer`, create:

```text
<base-path>/.masc/config/keepers/reviewer.toml
```

Example TOML:

```toml
[keeper]
autoboot_enabled = true
proactive_enabled = true
sandbox_profile = "local"
allowed_paths = ["workspace/yousleepwhen/masc"]
mention_targets = ["operator"]
```

Example declaration:

```markdown
You are the review Keeper. Inspect the current change, identify concrete
failures, and report evidence with exact file paths and commands.
```

`keeper.instructions` becomes the Keeper's individual instructions. Do
not copy tool descriptions into it: agent core attaches the current tool schemas to
the turn independently.

## Create or update through MCP

```text
masc_keeper_up(
  name: "reviewer",
  instructions: "Review the current change and report concrete evidence.",
  sandbox_profile: "local",
  autoboot_enabled: true
)
```

On persistence, MASC writes operational fields to `reviewer.toml` and writes
the full instructions to `reviewer.toml`.

## Start and stop

```text
masc_keeper_up(name: "reviewer")
masc_keeper_down(name: "reviewer")
masc_keeper_status(name: "reviewer")
```

`autoboot_enabled = true` makes the server consider the Keeper during startup.
`proactive_enabled = true` enables autonomous turns when valid stimuli arrive.

## Runtime assignment

Keeper TOML does not select a model or runtime. Assign the Keeper in
`runtime.toml`:

```toml
[runtime.assignments]
reviewer = "coding"
```

The runtime identifier is opaque to MASC; agent core resolves the provider/model
binding.

## Validation rules

- A Keeper TOML must set a non-empty `keeper.instructions`.
- Keeper TOML accepts only the current fields documented in
  `KEEPER-FILE-MODEL.md`; any other key fails closed.
- `sandbox_profile` is required for a configured profile used by runtime
  dispatch.
- `local` and `docker` are the supported sandbox profiles.
- The live runtime root is `<base-path>/.masc`; use the same `--base-path` as
  the server when inspecting or controlling Keepers.

## Prompt assembly

During an autonomous turn, MASC loads the complete `keeper.instructions` into the
Keeper instruction block. World observation, memory selection, and current
tool schemas are separate inputs.
