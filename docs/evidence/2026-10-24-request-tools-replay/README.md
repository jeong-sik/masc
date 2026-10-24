# Replay selection from effective outgoing tools

The [official DeepSeek thinking-mode guide](https://api-docs.deepseek.com/guides/thinking_mode/), read 2026-10-24, says prior reasoning replay depends on whether the request carries tools. Tool-enabled requests must return reasoning from every previous turn; requests without tools do not need it and the endpoint ignores it. This includes prior plain-answer reasoning, not just assistant messages that contain ToolUse.

Five official DeepSeek catalog rows already described this rule in comments but selected a policy based on each historical assistant's ToolUse. The new `preserve_with_request_tools` declaration selects full-history eligibility and gates request-local replay on the effective outgoing tools array. Existing MiMo, self-hosted and Ollama Cloud declarations retain their own policies. No provider/model text inference is introduced.

The Chat builder resolves tools after `effective_tools`, including explicit `tool_choice=None_` suppression. Codec projections and read-only transmitted-history now take the same tools fact. Keeper request composition passes its actual tools into that read-only view. Anthropic prefix observation/stamping receives the same fact as serialization. Opaque Responses replay remains controlled by that transport's own policy.

Producing-source identity remains independent of request tools presence. The new official DeepSeek declaration changes its stable full-history replay identity relative to the old tool-call-only declaration. Existing source-compatibility checks therefore do not certify artifacts stamped under the old declaration. This layer does not migrate stored artifacts or certify resumed checkpoints; #27894 remains separate work.

## Validation scope

- OCaml parser checks cover the changed implementation/interface/test files; whitespace check passes.
- Python tomllib reads the actual catalog and confirms exactly the five official DeepSeek rows have the new declaration. This checks TOML syntax/data, not the OCaml catalog parser.
- Added source fixture calls the real Chat request builder in sync and stream modes. It distinguishes plain prior reasoning, old tool-call reasoning, a later real human query, outgoing tools, absent tools and explicit tool-choice suppression. It checks matching read-only projections and stable producing-source identity across request tools presence.
- Existing DeepSeek dialect/catalog source expectations now describe full-history eligibility; other provider policies are preserved.
- OCaml fixture execution, typecheck, Dune builds, CI and provider/runtime calls were not performed. Parser/data/source checks do not establish those results.

This is part of #27904. Qwen synthetic context/recovery/instruction wire lowering, Anthropic signed-prefix origin lowering, other envelopes, autonomous episode attribution, executable conformance and integration/runtime evidence remain open.
