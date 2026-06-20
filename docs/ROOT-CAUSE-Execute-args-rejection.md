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
| `executable` | string | required for single-process branch |
| `argv` | array of strings | yes (single-process branch) |
| `pipeline` | array of `{executable, argv}` stages | alternative branch |
| `env` | object | optional |
| `cwd` | string | optional |
| `timeout_sec` | number | optional |
| `stdin` | redirect object | optional |
| `stdout` | redirect object | optional |
| `stderr` | redirect object | optional |

Schema properties:

- `additionalProperties: false`
- `oneOf`: either `executable`/`argv` **or** `pipeline`, never both.

Therefore **any of these inputs are rejected**:

```json
{"args": ["ls", "-la"]}
{"args": {"command": "ls -la"}}
{"command": "ls -la"}
{"cmd": "ls -la"}
{"executable": "ls", "argv": ["-la"], "args": {}}
```

The correct shape is:

```json
{"executable": "ls", "argv": ["-la"]}
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

The field name `args` is used in several places, but it is **never** a valid field inside the `Execute` schema. It can leak into the tool input through these paths:

### 4.1 Gemini provider wire format

Gemini sends tool-call arguments under the key `functionCall.args`:

- Request: `oas/lib/llm_provider/backend_gemini.ml:177`
- Response: `oas/lib/llm_provider/backend_gemini.ml:436`
- Streaming: `oas/lib/llm_provider/streaming.ml:977`

The parser unwraps `args` into `ToolUse.input`:

```ocaml
ToolUse { id; name; input = args }
```

If this unwrap has a bug (e.g., reading the wrong nesting level, or the response shape differing from expectation), the literal `{"args": ...}` object can become `ToolUse.input`, and MASC validation rejects it.

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

### 4.4 Legacy alias `execute_command` / `Bash` / `Shell`

OAS has an alias layer (`oas/lib/agent/agent_tool_name_alias.ml:88-110`) that normalizes:

- `execute_command` / `Bash` / `Shell` → `Execute`
- Rewrites `{"command":"git status --short"}` → `{"executable":"git","argv":["status","--short"]}`

But if the alias layer is **not** invoked (e.g., the model calls `Execute` directly, or the tool name is already `Execute`), no normalization happens. A `command`/`cmd`/`args` legacy field then reaches MASC validation and is rejected.

### 4.5 Persona / prompt examples

The `issue_king` persona (`config/personas/issue_king/profile.json`) and base keeper config (`config/keepers/base.toml`) explicitly instruct:

> "PR 생성은 준비된 작업 브랜치에서 git push 후 별도 실행 축이 아니라 Execute typed argv 경로로 수행한다."

This is correct, but if any few-shot example, memory, or older prompt template still shows an `args` or `command` wrapper, the model may copy it.

---

## 5. Most likely cause for `issue_king`

`issue_king` is a normal keeper with no special `Execute` handling. It uses the same descriptor-backed tool surface as every other keeper.

Given the error, the most likely scenarios are:

1. **Gemini parser edge case** — if `issue_king` is configured to use a Gemini-compatible provider, the `args` field from `functionCall.args` is being passed through without unwrap under some response shape.
2. **Model hallucinated `args`** — the flattened OAS bridge schema plus a confused prompt caused the model to emit `{"args": ...}` instead of `{"executable": ..., "argv": ...}`.
3. **Legacy alias not applied** — the model called `Execute` directly while thinking it was `execute_command`/`Bash`, and included a `command` or `args` field. (The error would normally say `command`/`cmd` is unsupported, but if the field is `args`, this scenario is also possible.)

The error says **`args`**, not `command`/`cmd`, which points most strongly to **scenario 1 (Gemini)** or a model-level JSON hallucination.

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

Look at `config/keepers/issue_king.toml` and its runtime binding to see which provider/model is used. If it is a Gemini model, focus on `backend_gemini.ml`.

### 6.4 Check trajectory / telemetry

Search `.masc/trajectories/`, `logs/`, or telemetry for the affected `issue_king` turn. The raw tool-call JSON should be present in the trajectory.

---

## 7. Recommended fixes

### Immediate mitigation

1. **Add defensive normalization in MASC for `Execute`**
   - In `lib/keeper/keeper_tool_descriptor_resolution.ml` or `lib/keeper/keeper_tools_oas_handler.ml`, before calling `Tool_input_validation.validate`, normalize legacy shapes:
     - If `input` has `args` object, unwrap it.
     - If `input` has `command`/`cmd` string, rewrite to `executable`/`argv` (reuse OAS alias logic).
   - This mirrors what OAS already does for `execute_command`/`Bash`/`Shell` aliases.

2. **Improve `tool_use_recovery.ml` to recognize `args`**
   - Add `args` as an accepted tool-call envelope in text-block recovery.

3. **Fix Gemini parser if `args` is leaking**
   - Add an assertion in `backend_gemini.ml` that `ToolUse.input` never literally equals `{"args": ...}`.
   - Add regression test with a mocked Gemini response containing nested `args`.

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
4. Apply the fix corresponding to the actual leak path (most likely Gemini `args` unwrap or model hallucination via flattened schema).
