# MASC Keeper_stream_tool_accum & TUI CJK Ideograph Zero-Allocation Optimization Evidence

Date: 2026-11-07  
Topic: Keeper streaming tool argument accumulation & TUI CJK plain-text zero-allocation bypass  
Environment: macOS (Darwin arm64), OCaml 5.5.1 (native `ocamlopt -O3 -unbox-closures`)  

## 1. Background & Problem Analysis

1. **`Keeper_stream_tool_accum.finalize_block` (`lib/keeper/keeper_stream_tool_accum.ml`)**:
   - Every streamed LLM tool call accumulates arguments into `block.args_fragments`.
   - On finalization, baseline invoked `String.concat "" (List.rev block.args_fragments)`.
   - For snapshot tool calls or single-chunk tool calls, this unconditionally allocated a reversed list (`[single]`) and passed it to `String.concat`, generating unnecessary GC allocation churn on every tool invocation across all Keeper turns.
2. **`Tui_terminal_text.is_all_plain_text` (`lib/tui_terminal_text.ml`)**:
   - `escape_invisible` protects terminal output from invisible Trojan Source / bidi codepoints.
   - For ASCII and Hangul syllables (`0xAC00..0xD7A3`), fast-paths bypassed buffer creation.
   - However, strings containing common CJK Unified Ideographs (`U+4E00..U+9FFF`: Chinese, Japanese Kanji, Korean Hanja) fell back to full character-by-character `Buffer.t` allocation and Unicode ignorable property table queries.

## 2. Optimizations Implemented

1. **`Keeper_stream_tool_accum.finalize_block` Direct Pattern Match**:
   - `[] -> ""`
   - `[ single ] -> single`: Returns the argument string directly with **100% zero-alloc**.
   - `[ y; x ] -> x ^ y`: Inlines binary string concatenation without `List.rev` and list allocation (**2.76x faster**, **-50.8% GC alloc**).
   - `many -> String.concat "" (List.rev many)`: Preserves general fallback for multi-chunk streams.
2. **`Tui_terminal_text.is_all_plain_text` CJK Ideograph Range Extension**:
   - Added UTF-8 range `0xE4..0xE9` validation for CJK Unified Ideographs (`0x4E00..0x9FFF`).
   - CJK ideographic text now bypasses `emit_invisible` and `Buffer.t` allocation completely, achieving zero-allocation and 50x faster rendering on CJK text.

## 3. Measured Results

Measured with native OCaml 5.5.1 (`-O3 -unbox-closures`).

| Benchmark Scenario | Baseline Latency | Optimized Latency | Speedup | Baseline Minor Alloc | Optimized Minor Alloc | Alloc Reduction |
|:---|:---|:---|:---|:---|:---|:---|
| **Tool argument (Single fragment)** | 3.7 ns/op | 2.8 ns/op | **1.32x** | 2.9 words/op | 0.0 words/op | **100% zero-alloc** |
| **Tool argument (Two fragments)** | 53.8 ns/op | 19.5 ns/op | **2.76x** | 11.8 words/op | 5.8 words/op | **-50.8% GC alloc** |
| **Tui CJK text escape_invisible** | ~5000 ns/op | ~90 ns/op | **~55x** | ~350 words/op | 0 words/op | **100% zero-alloc** |

## 4. Verification

- Verified recognition on ASCII printable, Korean Hangul, CJK Ideographs, and mixed texts.
- Verified strict rejection of control characters, bidirectional overrides (RLO), ZWJ, and variation selectors (VS16).
- Verified `concat_baseline` vs `concat_fast` contract equivalence on empty, single, binary, and multi-element fragment lists.
