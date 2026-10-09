# Mermaid grammar and rendering responsibility boundary

Base: c472b890c5134ffe9af43534650c273dbf296f46.

Private masc_tui_mermaid_grammar owns canonical diagram/failure data and flowchart, sequence and state-diagram parsing (1156 lines). The root owns canvas, layout and drawing (1118 lines, previously 2134). Parser mutations are confined to per-call cursors, tables and accumulators; no terminal, filesystem or global runtime acquisition enters the grammar.

Fifteen manifest type re-exports with destructive signature substitution preserve canonical data identity. The existing public MLI is byte-identical. Extracted grammar body is exact apart from final newline normalization, and retained renderer code is unchanged. No wrapper functions, compatibility reader or default was added. Source responsibility separation does not itself prove every accepted grammar or layout policy correct.

Focused build `opam exec -- dune build test/test_tui_mermaid.exe` completed exit 0. `_build/default/test/test_tui_mermaid.exe --color=never`: 62 PASS, BEFUO2CP, exit 0. Existing cases cover parsing/rendering of flowcharts, nested groups, sequences, states, direction/shape/edge handling, text/cell widths and malformed/unsupported inputs. They compute returned diagrams/rows without opening a real terminal. Five source hashes, one executable hash and actual output are retained.

Independent source review and final evidence delta are pending. Full CI, installation, actual TUI screen, formal GitHub approval and merge remain unverified. Parser/layout correctness and performance still require semantic audit; crossing below 2000 lines does not complete the original candidate or the 171-file campaign.
