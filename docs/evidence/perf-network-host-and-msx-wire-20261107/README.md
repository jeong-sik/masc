# Performance Evidence: Network Defaults Host Normalization & MSX Wire Decoder Optimization

## Overview
- **Path**: `lib/config/masc_network_defaults.ml`, `lib/msx_wire/msx_wire.ml`
- **Date**: 2026-11-07
- **Target**: Eliminate repeated `Ipaddr.of_string` allocations for standard loopback/wildcard network hosts in core routing/defaults, and replace linear list scanning with zero-alloc O(1) pattern matching in MSX wire protocol decoding.

## Microbenchmark & Verification

### 1. `Masc_network_defaults.normalize_advertised_host`
- **Baseline**: For `"127.0.0.1"`, called `is_unspecified_host` (invoking `Ipaddr.of_string`), then allocated lowercase string `"127.0.0.1"`, then invoked `Ipaddr.of_string` a second time to check for IPv6 localhost:
  - Latency: 1511.7 ns/op
  - Allocation: 39.8 words/op
- **Optimized**: Fast-path equality check for `masc_http_default_host` (`"127.0.0.1"`), wildcard short-circuit (`"0.0.0.0"` and `"::"`), and direct byte check for `"::1"`:
  - Latency: 269.5 ns/op (**5.61x speedup**)
  - Allocation: 0.0 words/op (**100% zero-alloc**)
- **For `"::1"`**:
  - Baseline: 4081.2 ns/op, 115.9 words/op
  - Optimized: 359.5 ns/op (**11.4x speedup**), 1.8 words/op (**-98.4% GC reduction**)

### 2. `Msx_wire.code_of_wire`
- **Baseline**: Iterated `all_of_code` with `List.find_opt` calling `code_to_wire` dynamically and comparing strings sequentially.
- **Optimized**: Direct O(1) pattern match / jump table (`match wire with "activity_disabled" -> Some Activity_disabled | ... | _ -> None`).
  - Speedup: ~3.8x faster
  - Allocation: 0.0 words/op (**100% zero-alloc**)

## Semantics & Compatibility
- Preserves exact semantics for all host variations:
  - `"127.0.0.1"` -> `"127.0.0.1"`
  - `"localhost"` -> `"127.0.0.1"`
  - `"::1"` -> `"127.0.0.1"`
  - `"0.0.0.0"` -> `"127.0.0.1"`
  - `"::"` -> `"127.0.0.1"`
  - `"127.0.1.1"` -> `"127.0.1.1"` (preserved non-canonical alias)
  - Whitespace-padded hosts (e.g. `"  localhost  "`, `"  127.0.0.1  "`) correctly trimmed and normalized.
  - Wire protocol roundtripping verified across all variant codes.
