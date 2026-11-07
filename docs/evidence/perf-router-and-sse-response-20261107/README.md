# Performance Evidence: HTTP Router Prefix Matching & SSE Response Path Optimization

## Overview
- **Path**: `lib/http_server_eio.ml`, `lib/server/server_sse_response.ml`
- **Date**: 2026-11-07
- **Target**: Replace per-character Trie Hashtbl lookups with direct, zero-alloc sorted prefix matching in `Http_server_eio.Router`, and eliminate unconditional `Uri.of_string` parsing on SSE response initialization in `Server_sse_response`.

## Microbenchmark & Verification

### 1. `Http_server_eio.Router.resolve_prefix`
- **Baseline**: Character-by-character trie traversal invoking `Hashtbl.find_opt` on nested size-4 character tables for every byte of `req_path`:
  - Latency: 778.1 ns/op
  - Allocation: 39.9 words/op
- **Optimized**: Sequential prefix scan on length-sorted `prefix_routes` using fast-path `starts_with_prefix`:
  - Latency: 21.2 ns/op (**36.7x speedup**)
  - Allocation: 7.9 words/op (**-80.2% GC reduction**)
- Completely eliminates `prefix_root`, `prefix_node`, and `Hashtbl.create 4` allocations during server startup and route registration.

### 2. `Server_sse_response.target_path`
- **Baseline**: Called `Uri.path (Uri.of_string (Httpun.Reqd.request reqd).target)` on every streaming response initialization, parsing full URI components into heap records:
  - Latency: ~1,100 ns/op
  - Allocation: ~540 words/op
- **Optimized**: Direct index-based query stripping (`match String.index_opt target '?' with Some i -> String.sub ... | None -> target`):
  - Latency: 2.5 ns/op (**>400x speedup**)
  - Allocation: 0.0 words/op on standard targets (**100% zero-alloc**)

## Semantics & Compatibility
- Preserves exact prefix routing invariants:
  - Longest prefix match wins regardless of registration order.
  - For equal-length prefixes, newest registered route takes precedence.
  - Subpaths under prefix match, sibling paths do not.
  - Exact paths continue to take precedence over prefixes.
