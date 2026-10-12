# Chat event-boundary complexity refresh

Source head: `19cbf8a6aa6f9ac746128dddf95612b2086bd949`. Meter unchanged from #42570. Parsed 11 complete production files and measured 417 top-level function bindings, without a build. No source filtering beyond those explicitly listed files.

| Function | Inclusive decision score | Branch nesting | Field/ref writes |
|---|---:|---:|---:|
| `bin/masc_tui_keeper_chat_transcript.ml::apply_delta` | 154 | 9 | 70 |
| `lib/keeper/keeper_chat_agent_core_stream_bridge.ml::translate` | 107 | 7 | 0 |
| `lib/keeper/keeper_muse_runtime.ml::run_without_lifecycle` | 91 | 5 | 21 |
| `bin/masc_tui_keeper_chat_live.ml::custom_deltas_unvalidated` | 81 | 7 | 0 |
| `lib/keeper/keeper_antigravity_runtime.ml::run_without_lifecycle` | 72 | 4 | 17 |
| `lib/keeper/keeper_codex_runtime.ml::run_without_lifecycle` | 71 | 4 | 15 |
| `lib/keeper/keeper_claude_code_runtime.ml::run_without_lifecycle` | 70 | 4 | 17 |
| `lib/keeper/keeper_chat_event_log.ml::keeper_chat_event_of_json` | 60 | 4 | 0 |
| `bin/masc_tui_keeper_chat_projection.ml::decode_data_event` | 44 | 5 | 0 |
| `lib/keeper/keeper_chat_event_log.ml::keeper_chat_event_to_json` | 41 | 2 | 0 |
| `lib/server/server_keeper_chat_agui_projection.ml::project` | 40 | 2 | 0 |
| `lib/keeper/keeper_codex_runtime.ml::codex_stream_callback` | 39 | 3 | 4 |

These are AST syntactic metrics, not formal McCabe complexity, defects, or acceptance thresholds. Nested closures count in their enclosing top-level function. Match/function cases add case-count minus one; exceptions add one per case; guards, if, loops and short-circuit booleans add one. Score begins at one. Record-field writes and ref assignment count; Buffer/Hashtbl effects do not. Definitions remain those of the unchanged meter.

The earlier six-file inventory omitted the producer bridge, shared journal codec and provider runtime boundaries. This expanded inventory identifies bridge.translate (107 decisions, depth7) and runtime callbacks as concrete next inspection surfaces alongside the reducer. Live.custom_deltas_unvalidated is now 81 versus 88 in the prior source snapshot after shared decoding changes; this reduction alone proves no correctness improvement. Runtime functions include orchestration unrelated to rendering and are not evidence that every provider path is covered.

Current source inspection confirms the bridge owns MessageStart replay suppression, per-scope terminal poisoning and content-block closure. Future probes should exercise actual bridge transitions with reducer decisions, including terminal ContentBlockStop/MessageDelta/MessageStop, late native completion, and input continuation. Existing narrowly interpreted reducer/codec results do not prove those combined paths.

## Reproduce

Run at the frozen source head. The result includes every source hash and meter hash.

```sh
python3 - <<'PY'
from pathlib import Path
import json, subprocess
result = json.loads(Path('docs/evidence/2026-10-12-chat-event-boundary-complexity/result.json').read_text())
compiler = Path(subprocess.check_output(['ocamlc', '-where'], text=True).strip()) / 'compiler-libs'
yojson = subprocess.check_output(['ocamlfind', 'query', 'yojson'], text=True).strip()
raw = subprocess.check_output(['ocaml', '-I', str(compiler), '-I', yojson, 'ocamlcommon.cma', 'yojson.cma', 'scripts/benchmarks/chat-ast-complexity/measure.ml', *result['source_sha256']], text=True)
print(raw)
PY
```

Direct measurement executed; JSON parsed and all recorded hashes checked. No full typecheck, registered behavior fixtures, provider execution, CI, formal approval, merge, installation, runtime or screenshot proof. Previous behavior fixes and the full goal remain separately unverified at those boundaries.
