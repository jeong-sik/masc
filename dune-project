(lang dune 3.22)

(using menhir 3.0)

(name masc_mcp)
(version 0.19.17)

(generate_opam_files true)
(implicit_transitive_deps false)
(executables_implicit_empty_intf false)

(source
 (github jeong-sik/masc-mcp))

(authors "Jeongsik Yun")

(maintainers "Jeongsik Yun")

(license MIT)

(documentation https://github.com/jeong-sik/masc-mcp)

(package
 (name masc_mcp)
 (synopsis "Multi-Agent Streaming Coordination MCP Server in OCaml")
 (description "MASC Protocol: File-based coordination for Claude, Gemini, and Codex agents")
 (depends
  (ocaml (>= 5.4))
  ; [dune] dependency is implicit from [(lang dune 3.22)] above —
  ; declaring it again here makes the generated .opam emit
  ; [{>= "3.22" & >= "3.22"}] (audited continuous-loop iter #10).
  ; External dependencies (opam pin)
  (mcp_protocol (>= 1.3.0))
  (ocaml-webrtc (>= 0.2.3))
  (grpc-direct-core (>= 0.1.0))
  (grpc-direct (>= 0.1.0))
  ; Standard dependencies
  (re (>= 1.10))
  (yojson (>= 2.0))
  (otoml (>= 1.0))
  (graphql (>= 0.14.0))
  (graphql_parser (>= 0.14.0))
  (cmdliner (>= 1.1))
  (cohttp (>= 5.0))
  (cohttp-eio (>= 6.0))
  (agent_sdk (>= 0.193.12))
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
  (integers (>= 0.7))
  (zstd (>= 0.4))
  (httpun (>= 0.2))
  (httpun-eio (>= 0.2))
  (httpun-ws (>= 0.2))
  (httpun-ws-eio (>= 0.2))
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
