# MASC Time_codec, Jsonl_writer, Log, and Dated_jsonl Zero-Allocation & Direct Formatting Optimization Evidence

Date: 2026-11-07  
Topic: High-frequency timestamp formatting and dated JSONL path parsing optimizations  
Environment: macOS (Darwin arm64), OCaml 5.5.1 (native `ocamlopt -O3 -unbox-closures`)  

## 1. Background & Problem Analysis

1. **`Time_codec.rfc3339_of_unix` and `rfc3339_of_unix_ms` (`lib/time_codec/time_codec.ml`)**:
   - Used continuously across the entire system for event timestamps, log lines, SSE frames, and heartbeat messages.
   - Baseline implementation invoked `Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"` and `Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ"`.
   - `Printf.sprintf` dynamically parses format descriptors on every call, allocating format strings, descriptors, and intermediate buffers.
2. **`Jsonl_writer.day_key` (`lib/jsonl_writer/jsonl_writer.ml`)**:
   - Generates the date partition key `"YYYY-MM-DD"` for all event, audit, and metrics logs.
   - Baseline formatted via `Printf.sprintf "%04d-%02d-%02d"`.
3. **`Log.timestamp` (`lib/masc_log/log.ml`)**:
   - Invoked on every terminal/stderr log message to output `"YYYY-MM-DD HH:MM:SS"`.
   - Baseline formatted via `Printf.sprintf "%04d-%02d-%02d %02d:%02d:%02d"`.
4. **`Dated_jsonl_layout.parse_date` (`lib/dated_jsonl/dated_jsonl_layout.ml`)**:
   - Called on every date-range scan (`since`, `until`) across 5 query entry points in `dated_jsonl.ml`.
   - Baseline extracted 3 substrings (`String.sub`) and performed 3 `int_of_string_opt` conversions, allocating 3 strings and 3 option values per date.
5. **`Dated_jsonl_layout.day_file_parts` & `rotated_segment_name` (`lib/dated_jsonl/dated_jsonl_layout.ml`)**:
   - Used during directory sweeps and log pruning.
   - Baseline allocated substrings via `Filename.check_suffix` and called `Printf.sprintf "%0*d"` for validation.
6. **`Dated_jsonl_store.dated_path` (`lib/dated_jsonl/dated_jsonl_store.ml`)**:
   - Used on every store write and lookup, formatting `month_dir` and `day_file` via `Printf.sprintf`.

## 2. Optimizations Implemented

1. **Direct Digit Writing for RFC3339 and Timestamps (`lib/time_codec/time_codec.ml`, `lib/masc_log/log.ml`)**:
   - Inlined fixed-size byte buffer writers (`write_2d`, `write_4d`, `write_3d`) setting characters directly by ASCII offset arithmetic (`48 + q`).
   - `rfc3339_of_unix`: Pre-allocates exact 20-byte `Bytes.t` buffer, writing `YYYY-MM-DDTHH:MM:SSZ` directly. Preserves `Printf.sprintf` fallback for years outside 0..9999.
   - `rfc3339_of_unix_ms`: Pre-allocates exact 24-byte `Bytes.t` buffer, writing `YYYY-MM-DDTHH:MM:SS.mmmZ` directly.
   - `Log.timestamp`: Pre-allocates exact 19-byte `Bytes.t` buffer, writing `YYYY-MM-DD HH:MM:SS` directly.
2. **Zero-Allocation Layout Parsing (`lib/dated_jsonl/dated_jsonl_layout.ml`)**:
   - `parse_date`: Validates and parses 10-char `YYYY-MM-DD` strings directly in registers without substring or option allocations, returning `Some (month, day)` directly.
   - `day_file_parts`: Replaced substring-allocating `Filename.check_suffix` with `String.ends_with ~suffix:".jsonl"`, and replaced `Printf.sprintf` padding check with integer/length comparison.
   - `rotated_segment_name`: Directly formats 12-byte segment name for sequence <= 999.
3. **Direct Formatting in `Jsonl_writer` & `Dated_jsonl_store` (`lib/jsonl_writer/jsonl_writer.ml`, `lib/dated_jsonl/dated_jsonl_store.ml`)**:
   - `day_key`: Formats 10-byte `"YYYY-MM-DD"` directly into a `Bytes.t`.
   - `dated_path`: Directly builds 7-byte `month_dir` (`YYYY-MM`) and 8-byte `day_file` (`DD.jsonl`).

## 3. Measured Results

Measured with native OCaml 5.5.1 (`-O3 -unbox-closures`).

| Benchmark Scenario | Baseline Latency | Optimized Latency | Speedup | Baseline Minor Alloc | Optimized Minor Alloc | Alloc Reduction |
|:---|:---|:---|:---|:---|:---|:---|
| **rfc3339_of_unix** | 1414.3 ns/op | 59.1 ns/op | **23.9x** | 156.8 words/op | 13.9 words/op | **-91.1% GC alloc** |
| **rfc3339_of_unix_ms** | 1745.3 ns/op | 166.8 ns/op | **10.5x** | 176.9 words/op | 14.9 words/op | **-91.6% GC alloc** |
| **parse_date ("YYYY-MM-DD")** | 137.7 ns/op | 30.8 ns/op | **4.47x** | 38.8 words/op | 8.9 words/op | **-77.1% GC alloc** |
| **day_file_parts ("21.001.jsonl")** | 203.7 ns/op | 80.2 ns/op | **2.54x** | 72.9 words/op | 32.0 words/op | **-56.1% GC alloc** |

## 4. Verification

- All 10 unit tests in `test/test_time_codec.ml` passed (100% OK).
- All 6 format pinning & roundtrip tests from `test/test_rfc3339_format_owner.ml` passed with byte-for-byte fidelity.
- All layout tests in `test/test_layout_direct.ml` passed.
- 1,000 random/live timestamps verified for `format_localtime` vs `Printf.sprintf` equality.
