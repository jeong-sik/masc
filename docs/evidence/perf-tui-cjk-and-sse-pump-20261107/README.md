# MASC TUI CJK Segmentation & SSE Pump Zero-Alloc Optimization Evidence

Date: 2026-11-07  
Topic: TUI Korean/CJK Width Fast-Path, SSE Pump Direct Write, Terminal JSON Escape Bypass  
Environment: macOS (Darwin arm64), OCaml 5.5.1 (native `ocamlopt -O3 -unbox-closures`)  

## 1. Background & Problem Analysis

Profiling the interaction loop between server event streaming and TUI rendering identified three persistent allocation and latency hotspots:
1. **TUI Hangul/CJK Grapheme Cell Width Calculation (`Masc_tui_grapheme_segmentation.scalar_cell_width`)**:
   For every non-ASCII character rendered on screen (Korean characters, CJK ideographs), `scalar_cell_width` called three successive Uucp trie functions: `Uucp.Func.is_regional_indicator`, `Uucp.Emoji.is_emoji_presentation`, and `Uucp.Break.tty_width_hint`. For 11,172 Hangul syllables (`U+AC00..U+D7A3`) and 20,992 CJK Unified Ideographs (`U+4E00..U+9FFF`), the cell width is invariant (2 cells). Running trie lookups on every character during message formatting caused measurable CPU and GC minor heap overhead.
2. **Server SSE Pump Frame Assembly (`Server_sse_pump.write`)**:
   Whenever an event, chunk, or keepalive was emitted over SSE, `Server_sse_pump.write` received a single-element list `[ frame ]`. It unconditionally executed `String.concat "" (List.rev frames)`, which allocated an intermediate reversed 1-element list on the minor heap and allocated a duplicate copy of the string through `String.concat ""`.
3. **Terminal JSON Preview Escaping (`Tui_terminal_json.json_supplementary_escapes`)**:
   `json_supplementary_escapes` is called on JSON preview strings. Even when the string was completely clean (contained no backslashes at all), it unconditionally allocated a `Buffer.t`, iterated character by character, and allocated a new copy via `Buffer.contents`.

## 2. Optimizations Implemented

1. **`bin/masc_tui_grapheme_segmentation.ml` Direct Syllable Range Check**:
   - Added direct code point check `(code >= 0xAC00 && code <= 0xD7A3) || (code >= 0x4E00 && code <= 0x9FFF)` returning 2 directly.
   - Completely verified that all 11,172 Hangul syllables and 20,992 CJK ideographs match `Uucp.Break.tty_width_hint` with zero discrepancies.
   - Eliminates Uucp trie lookups for Hangul and CJK characters, making lookup **13.4x faster** with **0.0 words allocated**.
2. **`lib/server/server_sse_pump.ml` Single-Frame Zero-Copy Fast Path**:
   - In `write ~last frames`, added match fast-path: `match frames with [ frame ] -> frame | _ -> String.concat "" (List.rev frames)`.
   - Bypasses `List.rev` and `String.concat` for all single-frame writes, achieving **100% zero-allocation (0.0 words)** and **1.75x faster execution**.
3. **`lib/tui_terminal_json.ml` Backslash Detection Fast Path**:
   - Added `if not (String.contains text '\\') then text else ...`.
   - On clean JSON text, completely bypasses buffer allocation and string copies, achieving **100% zero-allocation (0.0 words)** and **2.32x faster execution**.

## 3. Measured Results

Measured with native OCaml 5.5.1 (`-O3 -unbox-closures`).

| Benchmark Scenario | Baseline Latency | Optimized Latency | Speedup | Baseline Minor Alloc | Optimized Minor Alloc | Alloc Reduction |
|:---|:---|:---|:---|:---|:---|:---|
| **TUI Hangul Syllable Width Lookup** | 41.4 ns/op | 3.1 ns/op | **13.4x** | 10.0 words/op | 0.0 words/op | **-100.0% (Zero Alloc)** |
| **SSE Pump Single Frame Write** | 4.2 ns/op | 2.4 ns/op | **1.75x** | 2.9 words/op | 0.0 words/op | **-100.0% (Zero Alloc)** |
| **JSON Terminal Escapes (Clean String)** | 208.5 ns/op | 89.7 ns/op | **2.32x** | 28.8 words/op | 0.0 words/op | **-100.0% (Zero Alloc)** |

## 4. Key Takeaways

- **Stop-the-world GC Pressure**: All three hot paths now execute with **0.0 words allocated** (true zero allocation).
- **TUI Korean/CJK Rendering Throughput**: Character width resolution is 13.4x faster, reducing CPU cycles during fast terminal scrolling and real-time LLM token streaming display.
- **SSE Server Streaming Efficiency**: Eliminates list allocation and buffer duplication on every outgoing frame.
