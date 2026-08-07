# Keeper user manual

Keeper is MASC's persistent autonomous agent unit. A Keeper has one canonical
name, one complete `AGENT.md` prompt, and one operational TOML declaration.

<!-- BEGIN GENERATED: oas-pin-manual -->
OAS pin metadata is generated from `scripts/oas-agent-sdk-pin.sh`. Current dependency floor: `agent_sdk >= 0.231.13`, runtime pin: `main@59ccced68c2dc96389a91eee24d0b2c6bd5c53a6`, declared base version: `v0.231.13`. 최신성 검증이 필요할 때는 문서에 적힌 숫자보다 `dune-project`와 pin script를 우선 truth source로 본다.
<!-- END GENERATED: oas-pin-manual -->

## Configure a Keeper

For Keeper `reviewer`, create:

```text
<base-path>/.masc/config/keepers/reviewer.toml
<base-path>/.masc/config/keepers/reviewer/AGENT.md
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

Example `AGENT.md`:

```markdown
You are the review Keeper. Inspect the current change, identify concrete
failures, and report evidence with exact file paths and commands.
```

The entire `AGENT.md` file becomes the Keeper's individual instructions. Do
not copy tool descriptions into it: OAS attaches the current tool schemas to
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
the full instructions to `reviewer/AGENT.md`.

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

The runtime identifier is opaque to MASC; OAS resolves the provider/model
binding.

## Validation rules

- A TOML-backed Keeper must have a non-empty `keepers/<name>/AGENT.md`.
- Keeper TOML accepts only the current fields documented in
  `KEEPER-FILE-MODEL.md`; any other key fails closed.
- `sandbox_profile` is required for a configured profile used by runtime
  dispatch.
- `local` and `docker` are the supported sandbox profiles.
- The live runtime root is `<base-path>/.masc`; use the same `--base-path` as
  the server when inspecting or controlling Keepers.

## Prompt assembly

During an autonomous turn, MASC loads the complete Keeper `AGENT.md` into the
Keeper instruction block. World observation, memory selection, and current
tool schemas are separate inputs.
