# Mermaid grammar and rendering responsibility boundary

PR #42137.

Private masc_tui_mermaid_grammar owns canonical diagram/failure data and flowchart, sequence and state-diagram parsing (1156 lines). The root owns canvas, layout and drawing (1118 lines, previously 2134). Parser mutations are confined to per-call cursors, tables and accumulators; no terminal, filesystem or global runtime acquisition enters the grammar.

Fifteen manifest type re-exports with destructive signature substitution preserve canonical data identity. The existing public MLI is byte-identical. Extracted grammar body is exact apart from final newline normalization, and retained renderer code is unchanged. No wrapper functions, compatibility reader or default was added. Source responsibility separation does not itself prove every accepted grammar or layout policy correct.

Focused build `opam exec -- dune build test/test_tui_mermaid.exe` completed exit 0. `_build/default/test/test_tui_mermaid.exe --color=never`: 29 PASS, K1DZOHA2, exit 0. Existing cases cover reading flowchart statements, labels, strokes and shapes, sequences, state diagrams, subgraph width and refusals of malformed or unsupported input. They compute parsed diagrams and refusals without opening a real terminal. The actual output is retained.

Independent source review and final evidence delta are pending. Full CI, installation, actual TUI screen, formal GitHub approval and merge remain unverified. Parser/layout correctness and performance still require semantic audit; crossing below 2000 lines does not complete the original candidate or the 171-file campaign.
