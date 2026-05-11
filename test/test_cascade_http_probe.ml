(** Unit tests for [Cascade_http_probe].

    The HTTP probe path itself is intentionally not unit-tested
    here — it depends on a live ollama daemon and is covered by
    manual smoke tests.  The unit surface focuses on:

    - URL classification ([is_ollama_url]);
    - JSON parsing ([parse_response]);
    - cache lifecycle ([cached_capacity], [cache_size],
      [cache_clear]) with explicit [now] for deterministic TTL
      behaviour. *)

open Alcotest
module P = Masc_mcp.Cascade_http_probe
module Throttle = Masc_mcp.Cascade_throttle

(* ── URL classification ─────────────────────────────────────── *)

let test_is_ollama_url_positive () =
  check bool "127.0.0.1:11434 → ollama" true
    (P.is_ollama_url "http://127.0.0.1:11434");
  check bool "localhost:11434 → ollama" true
    (P.is_ollama_url "http://localhost:11434/api");
  check bool "remote:11434 → ollama" true
    (P.is_ollama_url "https://gpu.example.com:11434/v1")

let test_is_ollama_url_negative () =
  check bool "no port → not ollama" false
    (P.is_ollama_url "http://gemini.example.com");
  check bool "wrong port → not ollama" false
    (P.is_ollama_url "http://127.0.0.1:11435");
  check bool "empty → not ollama" false
    (P.is_ollama_url "")

(* ── parse_response ─────────────────────────────────────────── *)

let test_parse_response_one_loaded () =
  let json = Yojson.Safe.from_string {|{"models":[{"name":"qwen3-coder:30b"}]}|} in
  match P.parse_response json with
  | None -> fail "expected Some"
  | Some info ->
    check int "total default 1" 1 info.total;
    check int "process_active = models length" 1 info.process_active;
    check int "process_available = 0" 0 info.process_available

let test_parse_response_empty_models () =
  let json = Yojson.Safe.from_string {|{"models":[]}|} in
  match P.parse_response json with
  | None -> fail "expected Some"
  | Some info ->
    check int "process_active = 0" 0 info.process_active;
    check int "process_available = 1" 1 info.process_available

let test_parse_response_total_override () =
  let json = Yojson.Safe.from_string
    {|{"models":[{"name":"a"},{"name":"b"}]}|}
  in
  match P.parse_response ~total:4 json with
  | None -> fail "expected Some"
  | Some info ->
    check int "custom total" 4 info.total;
    check int "active = 2" 2 info.process_active;
    check int "available = total - active" 2 info.process_available

let test_parse_response_overload_clamps_to_zero () =
  let json = Yojson.Safe.from_string
    {|{"models":[{"name":"a"},{"name":"b"},{"name":"c"}]}|}
  in
  match P.parse_response ~total:1 json with
  | None -> fail "expected Some"
  | Some info ->
    check int "active higher than total" 3 info.process_active;
    check int "available clamped to 0" 0 info.process_available

let test_parse_response_invalid_shapes () =
  let cases = [
    {|null|};
    {|[]|};
    {|"models"|};
    {|{}|};                                (* no models key *)
    {|{"models":"not an array"}|};
    {|{"models":42}|};
  ] in
  List.iter (fun s ->
      let json = Yojson.Safe.from_string s in
      check bool ("invalid shape: " ^ s) true
        (P.parse_response json = None))
    cases

(* ── source discriminator ───────────────────────────────────── *)

let test_parse_response_source_is_discovered () =
  let json = Yojson.Safe.from_string {|{"models":[]}|} in
  match P.parse_response json with
  | None -> fail "expected Some"
  | Some info ->
    let src_str = match info.source with
      | Llm_provider.Provider_throttle.Discovered -> "Discovered"
      | Llm_provider.Provider_throttle.Fallback -> "Fallback"
    in
    check string "ollama probe is Discovered (not Fallback)"
      "Discovered" src_str

(* ── Cache TTL ──────────────────────────────────────────────── *)

let test_cache_lookup_empty () =
  P.cache_clear ();
  check bool "no entries → None" true
    (P.cached_capacity "http://127.0.0.1:11434" = None)

let test_cache_size_after_clear () =
  P.cache_clear ();
  check int "cleared cache size = 0" 0 (P.cache_size ())

(* The actual store path is exercised by [try_probe], which we do
   not unit-test.  We can still verify the TTL semantic by reading
   cache_size after a manual store:  not exposed publicly, so just
   verify the empty/clear lifecycle here. *)

(* ── Explicit URL registry — Http_probe.can_probe no longer uses
   substring scan. Proves three invariants kept across the migration:
   - default URL works without explicit register (module-load side-effect)
   - non-:11434 ollama URL still probeable once registered
   - substring-only matches (vLLM on :11434) are rejected unless
     the caller has explicitly registered them. *)

let test_default_url_registered_at_load () =
  check bool "ollama_default_url registered on module load" true
    (P.is_registered ~url:Masc_network_defaults.ollama_default_url);
  check bool "Http_probe.can_probe accepts default url" true
    (P.Http_probe.can_probe ~url:Masc_network_defaults.ollama_default_url)

let test_register_url_non_default_port () =
  let url = "http://127.0.0.1:51234" in
  check bool "non-default url not auto-registered" false
    (P.is_registered ~url);
  P.register_url ~url;
  check bool "registered after explicit call" true (P.is_registered ~url);
  check bool "Http_probe.can_probe accepts registered url" true
    (P.Http_probe.can_probe ~url);
  P.registry_clear ();
  P.register_url ~url:Masc_network_defaults.ollama_default_url

let test_can_probe_rejects_substring_only_match () =
  let foreign_url = "http://vllm.example.com:11434/v1" in
  P.registry_clear ();
  check bool "substring :11434 alone does not register" false
    (P.is_registered ~url:foreign_url);
  check bool "Http_probe.can_probe rejects substring-only :11434" false
    (P.Http_probe.can_probe ~url:foreign_url);
  (* Restore default for the rest of the suite. *)
  P.register_url ~url:Masc_network_defaults.ollama_default_url

let () =
  run "cascade_http_probe" [
    "is_ollama_url", [
      test_case "positive matches" `Quick test_is_ollama_url_positive;
      test_case "negative cases" `Quick test_is_ollama_url_negative;
    ];
    "Http_probe URL registry", [
      test_case "ollama_default_url registered at load" `Quick
        test_default_url_registered_at_load;
      test_case "explicit register accepts non-default port" `Quick
        test_register_url_non_default_port;
      test_case "can_probe rejects substring-only :11434" `Quick
        test_can_probe_rejects_substring_only_match;
    ];
    "parse_response", [
      test_case "one loaded model" `Quick test_parse_response_one_loaded;
      test_case "empty models array" `Quick test_parse_response_empty_models;
      test_case "total override" `Quick test_parse_response_total_override;
      test_case "overload clamps available to 0" `Quick
        test_parse_response_overload_clamps_to_zero;
      test_case "invalid shapes return None" `Quick
        test_parse_response_invalid_shapes;
      test_case "source = Discovered (not Fallback)" `Quick
        test_parse_response_source_is_discovered;
    ];
    "cache", [
      test_case "lookup on empty cache" `Quick test_cache_lookup_empty;
      test_case "size after clear is 0" `Quick test_cache_size_after_clear;
    ];
  ]
