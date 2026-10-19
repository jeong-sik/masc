# Unicode symbol positions in Code and Keeper questions

Issue #43945 follows the rich TUI Code navigation work. The same position
owner serves the TUI's `/api/v1/lsp/question` route and `keeper_code_query`.

The question pool initializes with empty client capabilities. Its requests
therefore use the LSP default UTF-16 character coordinates, as described in the
[official position contract](https://github.com/microsoft/vscode-languageserver-node/blob/main/types/src/main.ts#L87-L127).
Previously `Lsp_position.column_of` returned the selected UTF-8 byte offset
without converting it. ASCII hid the mismatch; a short non-ASCII prefix can
also hide it by placing the incorrect offset inside the same identifier.

## Actual reproduction

An isolated Python project imports `bass_phrase` from `lib/phrases.py`, where
its definition is on line 51. The source contains this line:

```python
label = "한글 설명이 충분히 깁니다🙂"; notes = bass_phrase()
```

The name begins at byte offset 60 and UTF-16 offset 36. Direct requests to the
installed Pyright server, initialized with the pool's empty capabilities,
returned `null` at 60 and the actual definition at 36. The original short-prefix
attempt and both longer-prefix replies are retained in the local proof record.
These are real language-server requests, not fabricated location fixtures.

## Change and caller scope

Literal occurrence search still finds the exact UTF-8 byte starts. The selected
prefix is then counted in UTF-16 code units: a supplementary scalar uses two,
while a combining mark or tab uses one. This coordinate is neither a Unicode
scalar count nor a terminal-cell offset. Malformed UTF-8 lines and symbols are
refused before producing a request position.

`columns_of` retains its documented low-level byte offsets. `column_of` returns
the zero-based protocol coordinate, while callers convert the requested line
from one-based. The REST route and Keeper tool pass that result directly to
`Lsp_questions.ask`; neither indexes source bytes using the result. No display
column, occurrence selection, project-root resolution or output location
contract is changed by this correction.

## Focused evidence and limits

The exact production implementation prefix through line/column arithmetic was
compiled separately with the existing complete `test_lsp_position.ml` file,
using OCaml 5.5.1 and warnings 4, 32 and 69 with enabled warnings fatal. The old
implementation failed two of five cases; the corrected implementation passed
all five. Added cases cover Korean, supplementary characters, combining marks,
tabs, a repeated Unicode symbol and malformed UTF-8.

That prefix excludes the process-manager/project-root functions. It is a focused
arithmetic check, not a complete-module or MASC build. A wrapper using that exact
production prefix calculated 36 from the actual file, and a fresh Pyright
definition request using that returned coordinate resolved the definition.
The full implementation, interface and test file also passed syntax parsing and
whitespace checks. No local Dune build was run.

New-source native compilation, actual candidate TUI/REST and Keeper execution,
independent source review, guarded approval, integration and operator installation
remain separate evidence stages. The predecessor's native run does not prove
this source, and the wider music and nonmusic rich TUI goal remains active.
