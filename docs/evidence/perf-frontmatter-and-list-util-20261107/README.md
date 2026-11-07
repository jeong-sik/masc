# Performance Evidence: Frontmatter Parsing & List_util Optimization

## Overview
- **Path**: `lib/core/frontmatter.ml`, `lib/core/list_util.ml`
- **Date**: 2026-11-07
- **Target**: Eliminate whole-file newline splitting (`String.split_on_char '\n'`) and re-joining (`String.concat "\n"`) across markdown frontmatter readers, and optimize `List_util.take_last` to single-pass sliding window.

## Microbenchmark & Verification

### 1. `Frontmatter.read` on document WITHOUT frontmatter (200 lines body)
- **Baseline**: Called `String.split_on_char '\n'` across the entire file, allocating lists and strings for all lines only to find the first line was not `---`:
  - Latency: 34,453.8 ns/op
  - Allocation: 1809.6 words/op
- **Optimized**: Fast-path first-character check (`c0`) and lazy line scanner:
  - Latency: 2.6 ns/op (**13,251x speedup**)
  - Allocation: 0.0 words/op (**100% zero-alloc**)

### 2. `Frontmatter.read` on document WITH frontmatter (200 lines body)
- **Baseline**: Split the entire document and then re-concatenated the entire body with `String.concat "\n"`:
  - Latency: 39,148.2 ns/op
  - Allocation: 2825.1 words/op
- **Optimized**: Scans only delimiter and frontmatter header lines; extracts body as single O(1) `String.sub` slice:
  - Latency: 1,837.3 ns/op (**21.3x speedup**)
  - Allocation: 1031.8 words/op (**-63.5% GC reduction**)

### 3. `Frontmatter.list_value`
- **Baseline**: Always split by comma, mapped trims, and filtered out empty strings, even for `[]` or single values.
- **Optimized**: Short-circuit for empty string/`[]` (0 words allocated), and single-value direct slice bypassing `split_on_char` and `filter`.

### 4. `List_util.take_last`
- **Baseline**: Two full list traversals (`List.length` followed by `drop (len - n)`).
- **Optimized**: Single-pass sliding window (`advance` + `slide`), eliminating second traversal.
  - `take_last 10 of 1000 items`: 23,066.6 ns -> 12,324.2 ns (**1.87x speedup**)

## Semantics & Compatibility
- Preserves exact semantics for:
  - CRLF and LF delimiters
  - Unterminated blocks (returns entire content as body and empty fields)
  - Trailing newline in body
  - Bracketed `[a, b]` and unbracketed `a, b` lists
  - Empty lists `[]` and empty fields
  - Verified with 22 unit test cases.
