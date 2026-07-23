# Root Cause: `Tool 'Execute' received unsupported field(s): args`

> Scope: repository-local MASC `Execute` tool validation path
> Error observed:
> `[WARN] [Keeper/issue_king] tool_policy_rejection: Execute — {"ok":false,"error":"Tool 'Execute' received unsupported field(s): args"}`
> Date: 2026-06-20

---

## 1. What the error means

The `Execute` tool received a JSON argument object that contains a field named `args`. The `Execute` tool schema is **closed** (`additionalProperties: false`), so any unexpected top-level field is rejected.

The error is built in:

- **`lib/tool_input_validation.ml:254`**
  `Some (Printf.sprintf "received unsupported field(s): %s%s" names_text hint)`
- **`lib/tool_input_validation.ml:411`**
  `~message:(Printf.sprintf "Tool '%s' %s" name message)`

which composes into:

```
Tool 'Execute' received unsupported field(s): args
```

---

## 2. What `Execute` actually accepts

Public name: `Execute`
Internal name: `tool_execute`
Schema location: `lib/tool_surface/tool_shard_types_schemas_execute.ml:233-278`

Allowed top-level fields:

| Field | Type | Required? |
|---|---|---|
| `argv` | non-empty array of strings | required for single-process branch; element 0 is the program |
| `pipeline` | array of `{argv}` stages | alternative branch; every stage has a non-empty process vector |
| `env` | object | optional |
| `cwd` | string | optional |
| `timeout_sec` | number | optional |
| `stdin` | redirect object | optional |
| `stdout` | redirect object | optional |
| `stderr` | redirect object | optional |

Schema properties:

- `additionalProperties: false`
- `oneOf`: either one non-empty `argv` **or** `pipeline`, never both.

Therefore **any of these inputs are rejected**:

```json
{"args": ["ls", "-la"]}
{"args": {"command": "ls -la"}}
{"command": "ls -la"}
{"cmd": "ls -la"}
{"executable": "ls", "argv": ["-la"]}
{"argv": ["ls", "-la"], "args": {}}
```

The correct shape is:

```json
{"argv": ["ls", "-la"]}
```

---

## 3. Where the rejection happens in the call chain

```
issue_king turn
  └─ OAS Agent.run_stream_blocks / run_blocks
       └─ Pipeline.run_turn
            └─ LLM provider response → ToolUse { name = "Execute"; input }
                 └─ Agent_tools.execute_tools
                      └─ Tool_input_validation.validate schema input
                           └─ unsupported_arg_names detects "args"
                                └─ Tool 'Execute' received unsupported field(s): args
```

The validation entry point in MASC is:

- `lib/keeper/keeper_tools_oas_handler.ml:94` (`pre_validate_input`)
- calls `lib/keeper/keeper_tool_descriptor_resolution.ml:112-122`
- calls `lib/tool_input_validation.ml:350-463` (`validation_action`)
- which calls `unsupported_arg_names` at `lib/tool_input_validation.ml:116-124`

---

## 4. Why `args` can appear in the input

The field name `args` is used in several places, but it is **never** a valid field inside the `Execute` schema. It can reach the validation boundary through these paths:

### 4.1 Gemini provider wire format (normal path already unwraps)

Gemini sends tool-call arguments under the key `functionCall.args`:

- Request: `oas/lib/llm_provider/backend_gemini.ml:177`
- Response: `oas/lib/llm_provider/backend_gemini.ml:436`
- Streaming: `oas/lib/llm_provider/streaming.ml:977`

The parser unwraps `args` into `ToolUse.input`:

```ocaml
ToolUse { id; name; input = args }
```

Therefore the normal Gemini parser path is **not** evidence that Gemini leaks the literal wrapper into MASC. A Gemini-specific parser edge case remains possible only if raw response capture shows the parser received a response shape where `ToolUse.input` still became `{"args": ...}` after parsing.

### 4.2 Model emits `args` inside a text block

If the LLM emits tool-call-like JSON inside a text block, e.g.:

```json
{"name": "Execute", "args": {"command": "git status"}}
```

the OAS `tool_use_recovery.ml:103-144` does **not** recognize the `args` shape. It recognizes `input`, `arguments`, `parameters`, `tool_calls/function`, and bare `function`, but not `args`. The call would stay as text and not execute — unless MASC later parses it again somewhere else. However, if some intermediate layer tries to execute the text block as a tool call, the `args` field would reach validation.

### 4.3 OAS bridge flattens the schema

When MASC exposes `Execute` to OAS agents:

- `masc/lib/tool_bridge.ml:150-210` (`params_of_json_schema`)
- `masc/lib/runtime/runtime_agent.ml:1143-1178` (`run_with_masc_tools`)

The schema is flattened into a flat `tool_param list`. This loses `oneOf`, `additionalProperties: false`, and mutual-exclusion constraints. The model may therefore generate invalid shapes more easily, including adding spurious fields like `args`.

### 4.4 Retired aliases and wrappers

MASC does not normalize `execute_command`, `Bash`, `Shell`, `cmd`, `command`,
`args`, or the retired `executable` field into an Execute request. Provider and
tool-name boundaries must produce the canonical typed call directly. Any
non-canonical field that reaches MASC is rejected explicitly.

### 4.5 Persona / prompt examples

The `issue_king` persona (`config/personas/issue_king/profile.json`) and base keeper config (`config/keepers/base.toml`) explicitly instruct:

> "PR 생성은 준비된 작업 브랜치에서 git push 후 별도 실행 축이 아니라 Execute typed argv 경로로 수행한다."

This is correct, but if any few-shot example, memory, or older prompt template still shows an `args` or `command` wrapper, the model may copy it.

---

## 5. Most defensible cause for `issue_king`

`issue_king` is a normal keeper with no special `Execute` handling. It uses the same descriptor-backed tool surface as every other keeper.

The exact upstream source is **not yet proven** without a raw provider response or captured `ToolUse.input`. Given the current code, the defensible scenarios are:

1. **Model hallucinated `args`** — the flattened OAS bridge schema plus a confused prompt caused the model to emit `{"args": ...}` instead of the canonical `{"argv": ["program", ...]}`.
2. **Retired shape emitted** — the model called `Execute` while using a `command`, `args`, or `executable` field learned from another tool contract.
3. **Provider parser edge case** — possible only if capture proves a provider parser returned `ToolUse.input = {"args": ...}`. The normal Gemini non-streaming and streaming paths already unwrap `functionCall.args` into the inner object, so Gemini should not be treated as the leading suspect without that evidence.

The error says **`args`**, not `command`/`cmd`, which is consistent with a model-level envelope hallucination or an unverified provider-specific parser edge. MASC must preserve this as explicit invalid input rather than guessing a canonical request from it.

---

## 6. How to verify the exact cause

### 6.1 Capture the raw LLM response

Add temporary logging in the provider parser for the runtime used by `issue_king`:

- If OpenAI-compatible: `oas/lib/llm_provider/backend_openai_parse.ml:268-286`
- If Anthropic: `oas/lib/llm_provider/backend_anthropic.ml` / `oas/lib/llm_provider/api_common.ml:145-149`
- If Gemini: `oas/lib/llm_provider/backend_gemini.ml:433-438`
- If Ollama: `oas/lib/llm_provider/backend_ollama.ml:215-239`

Log the raw response JSON and the resulting `ToolUse.input` before it reaches MASC.

### 6.2 Capture the rejected input

Add a log line in `lib/tool_input_validation.ml:411` to print `name` and the full `input` JSON when validation fails. This will show exactly what object contained `args`.

### 6.3 Check provider binding for `issue_king`

Look at `config/keepers/issue_king.toml` and its runtime binding to see which provider/model is used. If it is a Gemini model, compare raw `functionCall.args` with parsed `ToolUse.input`; do not assume a parser bug unless the parsed input still contains the outer `args` wrapper.

### 6.4 Check trajectory / telemetry

Search `.masc/trajectories/`, `logs/`, or telemetry for the affected `issue_king` turn. The raw tool-call JSON should be present in the trajectory.

---

## 7. Recommended fixes

### Immediate mitigation

1. **Keep one canonical MASC input contract**
   - Accept only `{"argv": ["program", ...]}` or the typed `pipeline` branch.
   - Keep `{"command": ...}`, `{"cmd": ...}`, `{"args": ...}`, `{"executable": ...}`, JSON-string composites, and mixed envelopes rejected.
   - Normalize provider-specific function-call envelopes at the provider codec boundary before constructing `ToolUse.input`; never guess process tokens in MASC.

2. **Only consider `tool_use_recovery.ml` changes with separate evidence**
   - Text-block recovery currently does not recognize `args`, so text that merely resembles a tool call should stay text.
   - Add `args` as a recovery envelope only if there is evidence that valid provider/tool-call content is otherwise stranded in text blocks, and keep the same narrow inner-object validation.

3. **Add provider parser regression only if capture proves a leak**
   - The normal Gemini parser already unwraps `functionCall.args` into `ToolUse.input`.
   - If capture proves any provider returns parsed `ToolUse.input = {"args": ...}`, add a provider-local assertion/regression for that exact parser edge.

### Structural improvements

4. **Preserve `additionalProperties: false` in the OAS bridge**
   - Modify `lib/tool_bridge.ml` / `params_of_json_schema` to carry the closed-schema constraint into the OAS tool description, so the model is less likely to hallucinate extra fields.

5. **Add a typed pre-check before OAS bridge**
   - For `Execute`, validate/coerce the input immediately after provider parsing and before exposing it to the model loop, so bad shapes fail fast with a clearer error.

6. **Audit persona/memory examples**
   - Search all `.json` / `.toml` / `.md` under `config/` for any `Execute` example that uses `args`, `command`, or `cmd`, and replace with `executable`/`argv`.

---

## 8. Files to inspect / modify

| File | Why |
|---|---|
| `config/keepers/issue_king.toml` | Provider/runtime binding for `issue_king` |
| `config/personas/issue_king/profile.json` | Prompt examples mentioning Execute |
| `config/keepers/base.toml` | Base prompt examples |
| `oas/lib/llm_provider/backend_gemini.ml` | If provider is Gemini, check `args` unwrap |
| `oas/lib/llm_provider/backend_openai_parse.ml` | If provider is OpenAI-compatible |
| `oas/lib/llm_provider/backend_anthropic.ml` | If provider is Anthropic |
| `oas/lib/llm_provider/backend_ollama.ml` | If provider is Ollama |
| `oas/lib/agent/agent_tool_name_alias.ml` | Existing alias/normalization logic |
| `oas/lib/agent/tool_use_recovery.ml` | Add `args` recognition |
| `masc/lib/tool_bridge.ml` | Schema flattening issue |
| `masc/lib/keeper/keeper_tool_descriptor_resolution.ml` | Where validation is invoked |
| `masc/lib/keeper/keeper_tools_oas_handler.ml` | Pre-validation hook |
| `masc/lib/tool_input_validation.ml` | Error origin; add diagnostic logging |
| `masc/lib/tool_surface/tool_shard_types_schemas_execute.ml` | Canonical Execute schema |
| `masc/lib/keeper/keeper_tool_execute_typed_input.ml` | Typed parsing rejection logic |

---

## 9. Next step

1. Identify which provider `issue_king` was using for the affected turn.
2. Add a one-line diagnostic log in `lib/tool_input_validation.ml:411` to print the rejected `input` JSON.
3. Reproduce or wait for the next occurrence; inspect the raw LLM response.
4. Apply the fix corresponding to the actual leak path (most likely model hallucination via flattened schema unless capture proves a provider parser edge).
