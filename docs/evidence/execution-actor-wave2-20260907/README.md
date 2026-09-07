# Authenticated execution response serialization — 2026-09-07

Installed server binary: embedded 01ef94a84037f1aff6cf57d3f3919131e24a4f6f, SHA-256 3682cafbe7ffa434bf2707528cdc396ab8654626387f06ffa3f45dc96c2eb188. Each probe recorded unchanged runtime identity before/after. This already includes the default anonymous response preparation from PR #33972.

Authenticated execution still returned roughly 1.4 MB of identity JSON. Eight paced samples: p50 11.762ms, p95 31.856ms. That window overlapped an anonymous probe and live Keeper work; it is not a controlled before/after comparison. A later dedicated 30-read window with native sampling recorded p50 8.412ms, p95 268.782ms and maximum 444.426ms. Profiler overhead and changing load preclude comparison. Main-domain stacks include Yojson writing alongside filesystem retention, digest work, logging and substantial polling; the profile does not attribute every long response to serialization.

Source establishes the avoidable work: parameterized requests obtain cached JSON and decorate it, then H1/H2 serialize it again, despite Dashboard_cache already memoizing raw JSON and its ETag. The change stores the decorated response in that cache and preserves the matching bytes/tag for HTTP responses. Keys scope base path, workspace path, resolved MASC root (including cluster), publication generation and the full parsed query, including missing versus empty fixture and force. A computation retains its captured generation if invalidation occurs while it runs. Cache-generated timeout envelopes retain request metadata and remain uncached.

Default light snapshot handling is unchanged. Parameterized responses remain uncompressed; first-fill serialization still occurs on the requesting domain. This unit removes repeated warm-hit serialization and enables conditional revalidation. No post-change executable or speedup is measured yet, and the 0.1ms objective remains unmet.

Validation at submission: independent source review and diff check pass. Behavioral endpoint tests and compilation run in CI; no local Dune build.
