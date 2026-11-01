# Keeper image input, 2026-11-01

The failure occurred on installed binary
`61b4d5531d44cb780dff64158fdbf7d641f1658f`. A browser screenshot reached the
Keeper as an artifact; `keeper_image_read` was blocked before execution because
`glm-coding.glm-5.3-flash` had no model image declaration. The fallback delegated
reading then received an external HTTP 429 quota refusal. This did not establish
that GLM lacked vision.

The same Z.AI Coding endpoint returned `LIME 8472` from the synthetic
[probe image](probe.png). [The receipt](provider-image-probe.json) records the
image digest, HTTP status and observed answer. This is a direct provider probe,
separate from a complete Keeper turn.

The live model declaration was repaired using the runtime configuration API's
preview, revision-checked save and readback. An additional 24 model declarations
were recovered from exact OpenRouter input metadata or the installed native
Codex catalog. [The repair receipt](live-declaration-repair.json) records the
source revisions and readback. Explicit disables were preserved; no server
restart occurred. These are configuration observations, not pixel-reading
proof for every model.

[OpenRouter metadata](openrouter-model-inputs.json) was retrieved from
`https://openrouter.ai/api/v1/models`. Each of the seed's 19 OpenRouter image
declarations matches the exact model's reported `input_modalities`. This is
capability metadata, not a successful call to every account/model.

The implementation was based on `4595b5686b2` and repairs HTTP metadata parsing,
exact provider/model catalog joins, installer selection/rendering, the native
named-provider batch boundary, and resolved runtime image observations. It
retains the existing explicit-declaration and execution-transport admission
rules. See issue [#47094](https://github.com/jeong-sik/masc/issues/47094).

Validation:

- `python3 test/test_install_runtime_setup.py ModelSelection NamedCatalogSources`:
  26 passed, including discovery through selected-model rendering and explicit
  endpoint disables.
- The new HTTP image discovery cases reproduce missing metadata against the
  older installed executable. They have not been run against a newly built
  executable in this coding session.
- `ocamlc -stop-after parsing` checks changed OCaml syntax only. No local Dune
  build, typecheck, full regression or release validation was run.
- The isolated Keeper screenshot/read operation was cancelled when an external
  deployment replaced the server. [The replacement record](probe-server-replacement.json)
  keeps its failed operation and both binary identities separate. A further
  native image-goal operation was submitted to the replacement server; a queued
  or running operation is not a completed pixel reading.

Reference: [ZCode's documented image capability handling](https://zcode.z.ai/en/docs/configuration#how-image-support-is-decided)
identifies GLM-5.3-Flash on the Z.AI Coding Plan as supporting screenshot and
image input. Runtime declarations and actual selected transports still decide
whether MASC can deliver those pixels.
