# Qwen control origins at the initial-System boundary

The official [Qwen3.6 template](https://huggingface.co/Qwen/Qwen3.6-35B-A3B/blob/995ad96eacd98c81ed38be0c5b274b04031597b0/chat_template.jinja) accepts a System frame only at the start and selects current reasoning relative to its latest caller query. A User containing a complete tool_response envelope is its tool-continuation representation. Sending dynamic context or recovery as a plain trailing User resets that native boundary.

## Implementation

The explicit `initial_system_latest_user_turn_tool_calls` catalog contract combines the selective replay rule with its required message lowering. It is declared for the five Qwen3.6/serving rows; consumers do not inspect model names, hosts, message prefixes or arbitrary metadata. Other contracts keep their placement policy. Anthropic, Gemini and Responses reject this initial-system contract rather than applying it to signed/opaque histories.

Before replay selection, canonical source stamps are validated and typed controls consolidate into one initial System frame. Current System_context and request-scoped Agent_instruction are active. Historical_system_context is quoted historical data. Recovery_instruction is active only after both the latest Conversation User and latest assistant response; answered recovery is historical even within the same caller query. Ordinary System instructions remain system instructions. Source occurrence coordinates survive consolidation for replay diagnostics. Canonical messages/checkpoints are unchanged.

Historical control text is a JSON array explicitly designated as reference, followed by active instructions. It is not recycled as a new caller instruction or assistant output. The configured system prompt is combined with that initial frame. Changing dynamic instructions changes the system/cache prefix: KV reuse does not take precedence over semantics.

At final wire serialization, typed Tool_result_followup media is enclosed in the template's tool_response protocol **after** modality ordering. No tool ID is invented. Ordinary Conversation User text is JSON quoted at this wire boundary, preserving its exact text value while preventing a caller's literal reserved tool_response syntax from being mistaken for tool output. Source identity is never parsed from these strings; it comes from the canonical enum. Media parts retain their native shapes. Ollama native images stay on their owning ToolResult (#45724); an unowned synthetic native media followup is rejected.

The template requires an actual caller-query frame. Controls do not fabricate a human when none exists. Non-text System controls also cannot be hoisted into a text-only System frame. Autonomous episode attribution and other providers' control lowering remain explicit unfinished #27904/#27915 work.

The transport-alias Qwen row previously declaring all-history tool-call replay now declares the same selective contract as its sibling rows. Existing source compatibility remains strict; this is no stored-artifact conversion or resumed-checkpoint guarantee.

## Executed reproduction and its boundary

```sh
python3 docs/evidence/2026-10-24-qwen-control-origin/run_fixture.py /path/to/chat_template.jinja
```

The runner compiles and executes the unchanged production `message_origin_lowering.ml` and its interface in a temporary directory, with an added namespace open for **isolated fixture dependencies** in fixture_support.ml. Those dependencies replace production Types/config/codec/sanitizer modules; fixture.ml is a declared wire adapter, not the production serializer. No Dune or project linking occurs. The runner records the production source SHA256 and checks the pinned template SHA256 before executing actual Jinja. The template is a local copy fetched from the official revision in the previous work unit; this run verifies those bytes, not fresh remote retrieval.

The native scoped-context layer updates the fixture enum dependency and reruns this reproduction against its current lowerer. The original source receipt remains available at #45743; result.json identifies the newly measured source hash.

result.json records seven passing groups: lowerer assertions, original failure reproduction, current reasoning retention, selective historical drop, an actual new caller containing reserved protocol syntax, media boundary preservation after modality ordering, and explicit full-history opt-in. Lowerer assertions also check historical versus active recovery, source coordinates, protocol admission failures, default identity and unsupported signed-codec policy. The harness caught a constructor rename mismatch during development; it was corrected before the recorded successful run.

This executes the real lowerer with fixture dependencies and the real reference template. It does **not** execute/link the production serializer, reasoning projector, full Core/MASC modules, native Ollama server or a model. No full-project typecheck, Dune build, CI, provider call, install or UI validation is claimed.

## Production-path fixture source

Updated test_provider_agnostic_reasoning_replay.ml calls the production Chat builder and projection APIs for current/old reasoning, answered/current recovery, historical/current context, actual new human with reserved syntax, configured/canonical System consolidation, preserve_thinking opt-in, canonical diagnostic coordinates, unsupported control content, missing caller and signed-codec refusal. A tool-image fixture uses Visual_first to check delimiter placement after media reordering. These Alcotest cases were not executed. Parser/whitespace checks and the isolated reproduction do not establish their success.
