# Pure grapheme segmentation boundary

PR #42138. Base: cd24c4319d5aec2e8e1a0fa17ff13c8edab54e2f. Code head: 66ce834c41148fc95b73322aeae10cd70af9b822.

Private masc_tui_grapheme_segmentation owns UTF-8 scalar decoding, ANSI parsing, Unicode widths and grapheme segmentation (340 lines). The root retains frame cache mutation, cached display pieces and message layout (2448 to 2109 lines). Parser cursors and buffers are invocation-local. Extracted calculation and retained root are exact apart from the include boundary and final newline normalization. Public MLI is byte-identical; no forwarding functions were added.

Focused build `opam exec -- dune build test/test_tui_message_layout.exe` completed exit 0. `_build/default/test/test_tui_message_layout.exe --color=never` completed exit 0: 115 PASS, Z39G7H3D. Existing cases use the public layout API to compute text cell widths, wrapping, slicing, rows and frame-cache behavior. This is in-process calculation evidence, not actual terminal rendering. Five source hashes, one executable hash and bounded output are retained.

Independent final source review is pending. Formal GitHub approval, merge, full CI, installation and actual TUI screen remain unverified. Segmentation, cache and layout policy/performance need further semantic audit. This candidate and the 171-file campaign remain incomplete.
