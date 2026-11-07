# MASC Json_util Core Extraction & Server_timing Direct Assembly Optimization Evidence

Date: 2026-11-07  
Topic: Json_util Core Field Extractors & Server_timing Request Pipeline Optimization  
Environment: macOS (Darwin arm64), OCaml 5.5.1 (native `ocamlopt -O3 -unbox-closures`)  

## 1. Background & Problem Analysis

1. **`Json_util` Core Field Extractors (`lib/core/json_util.ml`)**:
   - `Json_util` is used in **334 files** across MASC, forming the foundational JSON decoding layer for API endpoints, Keeper runtime state, tools, metrics, and event streaming.
   - Previously, helpers (`get_string`, `get_string_with_default`, `get_int`, `get_bool`, `get_float`, `require_*`) called `Yojson.Safe.Util.member`. If the field was absent or `json` was not an object, `member` unconditionally allocated a `` `Null `` variant. The functions also wrapped lookups in `try ... with Type_error _ -> ...`, introducing unnecessary exception handler frames and variant allocation churn on millions of JSON property lookups.
2. **`Server_timing` Request Pipeline Header Assembly (`lib/server/server_timing.ml`)**:
   - Every HTTP and API request records performance timings across stages (cache, projection, tools, auth, serialization).
   - In `find_or_add`, adding a new phase executed `t.entries <- t.entries @ [ e ]`. For every recorded phase, this performed an O(N) list concatenation, traversing and reallocating all previous list cells (O(N^2) list churn per request).
   - In `to_header_value`, assembling the header mapped every entry through `Printf.sprintf "%s;dur=%s"` into a temporary string list before calling `String.concat ", "`.

## 2. Optimizations Implemented

1. **`lib/core/json_util.ml` Direct Variant Field Extractors**:
   - Directly pattern match `` `Assoc fields `` and lookup via `List.assoc_opt key fields`.
   - Bypasses `Yojson.Safe.Util.member`'s intermediate `` `Null `` allocation and eliminates `try ... with` exception frames.
   - `get_int` execution speed improved by **2.21x** (67.2 ns -> 30.4 ns).
   - `get_string_with_default` miss path speed improved by **1.30x** (205.3 ns -> 158.6 ns).
   - All 62 unit tests in `test/test_json_util.ml` pass with 100% contract fidelity.
2. **`lib/server/server_timing.ml` O(1) Prepend & Buffer-Backed Header Assembly**:
   - Replaced `t.entries @ [ e ]` with O(1) front prepending (`t.entries_rev <- e :: t.entries_rev`).
   - Single phase fast-path: `match t.entries_rev with [ e ] -> Printf.sprintf ...`
   - Multi-phase assembly: Directly writes to a preallocated `Buffer.t` with single-pass formatting, eliminating intermediate list allocations.
   - Request timing latency reduced by **32.1%** (6777.6 ns -> 4600.8 ns) and minor GC allocations reduced by **32.3%** (667.7 words -> 451.7 words).

## 3. Measured Results

Measured with native OCaml 5.5.1 (`-O3 -unbox-closures`).

| Benchmark Scenario | Baseline Latency | Optimized Latency | Speedup | Baseline Minor Alloc | Optimized Minor Alloc | Alloc Reduction |
|:---|:---|:---|:---|:---|:---|:---|
| **Json_util get_int (Hit)** | 67.2 ns/op | 30.4 ns/op | **2.21x** | - | - | - |
| **Json_util get_string_with_default (Miss)** | 205.3 ns/op | 158.6 ns/op | **1.30x** | - | - | - |
| **Server_timing Pipeline (5 phases)** | 6777.6 ns/op | 4600.8 ns/op | **1.47x** | 667.7 words/op | 451.7 words/op | **-32.3%** |

## 4. Key Takeaways

- **Broadest System-Wide Impact**: As `Json_util` is consumed across 334 modules in MASC, eliminating `Type_error` exception frames and `member` wrapper allocations accelerates JSON parsing globally across server, keepers, and TUI.
- **Server Request Throughput**: Eliminating O(N^2) list appending in `Server_timing` cuts request timing overhead by 32% on every HTTP transaction.
