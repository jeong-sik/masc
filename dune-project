(lang dune 3.22)

(using menhir 3.0)

(name masc)
(version 0.20.1)

(generate_opam_files true)
(implicit_transitive_deps false)
(executables_implicit_empty_intf false)

(source
 (github jeong-sik/masc))

(authors "Jeongsik Yun")

(maintainers "Jeongsik Yun")

(license MIT)

(documentation https://github.com/jeong-sik/masc)

(package
 (name masc)
 (synopsis "Multi-Agent Shared Context MCP Server in OCaml")
 (description "MASC Protocol: File-based workspace collaboration for Claude, Gemini, and Codex agents")
 (depends
  (ocaml (>= 5.5))
  ; [dune] dependency is implicit from [(lang dune 3.22)] above —
  ; declaring it again here makes the generated .opam emit
  ; [{>= "3.22" & >= "3.22"}] (audited continuous-loop iter #10).
  ; External dependencies (opam pin)
  (mcp_protocol (>= 1.3.0))
  (ocaml-webrtc (>= 0.2.3))
  (grpc-direct-core (>= 0.1.0))
  (grpc-direct (>= 0.1.0))
  (ws-direct-core (>= 0.1.0))
  (ws-direct-gluten (>= 0.1.0))
  (ws-direct-eio (>= 0.1.0))
  ; Standard dependencies
  (re (>= 1.10))
  (yojson (>= 2.0))
  (otoml (>= 1.0))
  (graphql (>= 0.14.0))
  (graphql_parser (>= 0.14.0))
  (cmdliner (>= 1.1))
  (cohttp (>= 5.0))
  (cohttp-eio (>= 6.0))
  ; RFC-0107 Phase D — pooled keep-alive HTTP transport. piaf provides
  ; per-endpoint persistent client (Client.t) + h1/h2 + Eio integration;
  ; multi-host pool layer (Host_key map, idle eviction, TLS cache) is
  ; built on top in lib/masc_http_client/pool.ml.  macOS install needs
  ; brew openssl@3 + CPATH=/opt/homebrew/opt/openssl@3/include
  ; LIBRARY_PATH=/opt/homebrew/opt/openssl@3/lib environment overrides
  ; (upstream piaf 0.2.0 missing conf-libssl dependency on macOS arm64).
  (piaf (>= 0.2.0))
  (eio-ssl (>= 0.3.0))
  ;; Pinned to OAS v0.209.1 (tag v0.209.1, #2510). The patch repairs the
  ;; oas#2499 library build while preserving the catalog-driven capability,
  ;; typed empty-completion, and Hooks.Block 0.209 public boundary.
  ;; Exact pin sha lives
  ;; in scripts/oas-agent-sdk-pin.sh (SSOT); see check-oas-pin.sh.
  (agent_sdk (>= 0.210.0))
  (uri (>= 4.4))
  (tls (>= 2.0))
  (tls-eio (>= 2.0))
  (domain-name (>= 0.4))
  (ca-certs (>= 0.2))
  (ppx_deriving_yojson (>= 3.6))
  (ppx_let (>= v0.17.0))
  (ppx_deriving (>= 5.2))
  (ppxlib (>= 0.30))
  (sqlite3 (>= 5.1))
  (mirage-crypto (>= 1.0))
  (mirage-crypto-rng (>= 1.0))
  (mirage-crypto-pk (>= 1.0))
  (x509 (>= 1.0))
  (integers (>= 0.7))
  (zstd (>= 0.4))
  (httpun (>= 0.2))
  (httpun-eio (>= 0.2))
  (bigstringaf (>= 0.10))
  (eio (>= 1.0))
  (eio_main (>= 1.0))
  (eio_posix (>= 0.16))
  (cstruct (>= 6.0))
  (digestif (>= 1.1))
  (ocaml-protoc-plugin (>= 4.0))
  (pbrt (and (>= 3.0) (< 4.0)))
  ; [ctypes] + [ctypes-foreign] removed: zero callers in lib/ bin/ test/
  ; since webrtc_bindings.ml was removed (per lib/dune:252 comment).
  ; Confirmed by `rg '\bctypes\b' lib/ bin/ test/` = empty.  Audited
  ; continuous-loop iter #17 (2026-05-15).  Re-add if native FFI work
  ; resumes.
  ; [pbrt_services] removed: no caller in lib/ bin/ test/ since
  ; continuous-loop iter #11 audit (2026-05-15).  Re-add if gRPC
  ; service support resumes.
  (h2 (>= 0.13))
  (h2-eio (>= 0.13))
  (alcotest (and :with-test (>= 1.6)))
  (qcheck-core (and :with-test (>= 0.21)))
  (qcheck-alcotest (and :with-test (>= 0.21)))
  (bisect_ppx (and :with-test (>= 2.8)))
  (mtime (>= 2.0))
  (uuidm (>= 0.9))
  ; RFC-0004 Phase A0.1 typed SSE event library (lib/sse_event/).
  ; atdgen runs at build-time (codegen for sse_event.atd →
  ; sse_event_{t,j}.{ml,mli}); atdgen-runtime is linked into the
  ; generated _j module.  Promoted from sse_event_poc :with-test
  ; gating once the typed lib became production-required (PR-1).
  (atdgen (and :build (>= 4.2.0)))
  (atdgen-runtime (>= 4.2.0))
  ; RFC-0004 Phase A0.2 PR-2: atdts generates TypeScript decoders
  ; from sse_event.atd for the dashboard (committed at
  ; dashboard/src/schemas/sse_event_generated.ts).  Build-time only;
  ; no runtime linkage.  CI invokes it via dashboard/scripts/gen-sse-types.sh.
  (atdts (and :build (>= 4.2.0)))
  ; [neo4j_bolt_eio] removed: no caller in lib/ bin/ test/ since
  ; continuous-loop iter #12 audit (2026-05-15).  Same shape as
  ; pbrt_services (iter #11): declared but never imported.  Re-add
  ; when Neo4j Bolt support resumes.
  ; OpenTelemetry observability + OTLP exporter
  (opentelemetry (>= 0.13))
  (ambient-context-eio (>= 0.2))
  ; Build-time embedder for default config seeds (init subcommand)
  (crunch (and :build (>= 4.0)))))
 
; Formatting
