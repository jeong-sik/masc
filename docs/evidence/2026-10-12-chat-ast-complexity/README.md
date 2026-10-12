# AST complexity inventory for chat-state audit

Parsed six complete production files with installed OCaml 5.5.1 compiler-libs, without a build. Result records source head/hashes, meter hash and definitions inspected. Of 769 top-level function bindings measured, the report selects all functions in the five Keeper-chat modules and `chat_*` functions in the shared types module (254). Shared-types functions for unrelated product surfaces are excluded from chat ranking.

| Function | Inclusive decision score | Branch nesting | Field/ref assignment sites |
|---|---:|---:|---:|
| Transcript.apply_delta | 154 | 9 | 70 |
| Live.custom_deltas_unvalidated | 88 | 7 | 0 |
| Projection.decode_data_event | 44 | 5 | 0 |
| Log.delta_of_journaled | 37 | 4 | 0 |

These are syntactic metrics, not formal control-flow cyclomatic complexity or bug verdicts. Score starts at one, adds case-count minus one for matches/function-case dispatch, one per exception case, guard, conditional, loop and short-circuit boolean. Nested local functions/closures are included in the containing top-level function. Nesting includes case dispatch and booleans. Assignment counts include record-field writes and `:=`; Buffer/Hashtbl calls and other effects are not counted. Large exhaustive typed-event matches naturally have high scores.

The measured concentration supports prioritizing the transcript reducer's terminal/checkpoint/runtime-attempt/content/approval interactions, then comparing Live and strict CUSTOM decoding contracts. Existing source-only fixes do not prove all their cross-products, all providers, input interleaving, broadcast/asynchronous work or runtime rendering. Refactoring merely to lower this number is not acceptance.

Reproduce from the repository root:

```sh
python3 - <<'PY'
from pathlib import Path
import json, subprocess
compiler = Path(subprocess.check_output(['ocamlc', '-where'], text=True).strip()) / 'compiler-libs'
yojson = subprocess.check_output(['ocamlfind', 'query', 'yojson'], text=True).strip()
files = ['bin/masc_tui_keeper_chat_transcript.ml', 'bin/masc_tui_keeper_chat_live.ml',
         'bin/masc_tui_keeper_chat_projection.ml', 'bin/masc_tui_types.ml',
         'bin/masc_tui_keeper_chat_log.ml', 'bin/masc_tui_keeper_chat_queue.ml']
raw = subprocess.check_output(['ocaml', '-I', str(compiler), '-I', yojson,
    'ocamlcommon.cma', 'yojson.cma', 'scripts/benchmarks/chat-ast-complexity/measure.ml', *files], text=True)
rows = json.loads(raw)
selected = [row for row in rows if row['file'] != 'bin/masc_tui_types.ml'
            or row['function'].startswith('chat_')]
print(json.dumps(selected, indent=2))
PY
```

Desktop capability discovery found no computer-use access/capture/enable tools in this session. The computer-use skill's unavailable-tool flow was followed; no desktop action or screenshot was performed. Actual TUI screenshots remain missing. Parsing/metrics establish neither typechecking nor behavior, CI, approval, installation or merge.
