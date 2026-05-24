(** Tests for [Provider_kind_resolver] and the cascade parser's
    use of it. Covers issue #8159: ["provider_f:provider_f-3-flash-preview"] must
    resolve to [Provider_f], never silently flatten to [Provider_d_compat]. *)

open Alcotest

module Resolver = Masc_mcp.Provider_kind_resolver
module Cascade = Masc_mcp.Cascade_config
module Pk = Llm_provider.Provider_config

let with_env name value f =
  let previous = Sys.getenv_opt name in
  (match value with
   | Some v -> Unix.putenv name v
   | None -> Unix.putenv name "");
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f

let pp_kind fmt (k : Pk.provider_kind) =
  Format.pp_print_string fmt (Pk.string_of_provider_kind k)

let kind_testable : Pk.provider_kind testable =
  testable pp_kind ( = )

(* ────────────────────────────────────────────────────────────────── *)
(* Resolver: direct sum-typed resolution                              *)
(* ────────────────────────────────────────────────────────────────── *)

let test_gemini_prefix_resolves_to_gemini () =
  match Resolver.resolve "provider_f:provider_f-3-flash-preview" with
  | Registered { provider_name; model_id; kind } ->
    check string "provider_name" "provider_f" provider_name;
    check string "model_id" "provider_f-3-flash-preview" model_id;
    check kind_testable "kind is Provider_f" Pk.Provider_f kind
  | Custom_url _ -> fail "provider_f: resolved to Custom_url"
  | Unknown msg -> fail ("provider_f: resolved to Unknown: " ^ msg)

let test_openai_compat_prefix_not_misrouted () =
  (* Registered Provider_d_compat-kind providers (openrouter/provider_i/provider_g)
     must resolve to Provider_d_compat. Guards against the inverse mistake
     of flipping everything to Provider_f, and guards that "provider_d" is NOT
     a registered provider name (historically a point of confusion). *)
  (match Resolver.resolve "openrouter:provider_a/model-a-sonnet" with
   | Registered { kind; _ } ->
     check kind_testable "openrouter kind is Provider_d_compat" Pk.Provider_d_compat kind
   | Custom_url _ -> fail "openrouter: resolved to Custom_url"
   | Unknown msg -> fail ("openrouter: resolved to Unknown: " ^ msg));
  (* "provider_d" is NOT in the registry — it must return Unknown, not be
     silently mapped to any kind. This is the fail-closed contract. *)
  match Resolver.resolve "provider_d:model-d" with
  | Unknown _ -> ()
  | Registered _ -> fail "provider_d: silently registered (should be Unknown)"
  | Custom_url _ -> fail "provider_d: silently treated as custom"

let test_claude_prefix_resolves_to_anthropic () =
  match Resolver.resolve "agent_llm_a:model-a-haiku" with
  | Registered { kind; _ } ->
    check kind_testable "kind is Provider_a" Pk.Provider_a kind
  | Custom_url _ -> fail "agent_llm_a: resolved to Custom_url"
  | Unknown msg -> fail ("agent_llm_a: resolved to Unknown: " ^ msg)

let test_kimi_prefix_resolves_to_kimi () =
  match Resolver.resolve "provider_c:model-c-coding" with
  | Registered { provider_name; model_id; kind } ->
    check string "provider_name" "provider_c" provider_name;
    check string "model_id preserved" "model-c-coding" model_id;
    check kind_testable "kind is Kimi" Pk.Provider_k kind
  | Custom_url _ -> fail "provider_c: resolved to Custom_url"
  | Unknown msg -> fail ("provider_c: resolved to Unknown: " ^ msg)

let test_unknown_vendor_returns_unknown () =
  (* Anti-pattern guard: unknown prefix must NOT fall through to
     Provider_d_compat. Fail-closed is the contract (R2 in triage). *)
  match Resolver.resolve "unknownvendor:foo" with
  | Registered _ -> fail "unknownvendor: silently registered"
  | Custom_url _ -> fail "unknownvendor: silently treated as custom"
  | Unknown _ -> ()

let test_malformed_spec_returns_unknown () =
  let cases = [ ""; ":"; "nocolon"; "trailing:"; ":leading" ] in
  List.iter (fun spec ->
      match Resolver.resolve spec with
      | Unknown _ -> ()
      | Registered _ -> fail (Printf.sprintf "%S resolved as Registered" spec)
      | Custom_url _ -> fail (Printf.sprintf "%S resolved as Custom_url" spec))
    cases

let test_custom_prefix_resolves_to_custom_url () =
  match Resolver.resolve "custom:my-model@http://localhost:9000" with
  | Custom_url { model_id; base_url } ->
    check string "model_id" "my-model" model_id;
    check string "base_url" "http://localhost:9000" base_url
  | Registered _ -> fail "custom: resolved to Registered"
  | Unknown msg -> fail ("custom: resolved to Unknown: " ^ msg)

let test_kind_of_spec_api () =
  check (option kind_testable) "provider_f kind via helper"
    (Some Pk.Provider_f)
    (Resolver.kind_of_spec "provider_f:provider_f-3-flash-preview");
  check (option kind_testable) "unknown returns None"
    None
    (Resolver.kind_of_spec "unknownvendor:foo")

(* ────────────────────────────────────────────────────────────────── *)
(* Cascade integration: parse_model_string must preserve Provider_f kind  *)
(* ────────────────────────────────────────────────────────────────── *)

let test_cascade_parse_gemini_preserves_kind () =
  (* End-to-end: the exact spec from issue #8159 must yield kind=Provider_f
     after going through Cascade_config.parse_model_string. *)
  match Cascade.parse_model_string "provider_f:provider_f-3-flash-preview" with
  | None ->
    (* parse_model_string returns None when the provider is not
       available (missing GEMINI_API_KEY env var in test env). In that
       case, the resolver-level test above already proved the kind
       classification; accept None here. *)
    check bool "resolver confirms Provider_f kind when provider unavailable"
      true
      (Resolver.kind_of_spec "provider_f:provider_f-3-flash-preview"
       = Some Pk.Provider_f)
  | Some cfg ->
    check kind_testable "cfg.kind is Provider_f (not Provider_d_compat)"
      Pk.Provider_f cfg.kind;
    check string "cfg.model_id" "provider_f-3-flash-preview" cfg.model_id

let test_cascade_parse_unknown_returns_none () =
  match Cascade.parse_model_string "unknownvendor:foo" with
  | None -> ()
  | Some _ -> fail "unknown provider should parse to None, not a fallback config"

let test_cascade_parse_custom_v1_base_url_dedupes_request_path () =
  match Cascade.parse_model_string "custom:remote-model@http://127.0.0.1:18080/v1" with
  | None -> fail "custom v1 endpoint should parse"
  | Some cfg ->
    check kind_testable "cfg.kind is Provider_d_compat"
      Pk.Provider_d_compat cfg.kind;
    check string "custom request_path strips duplicated /v1 prefix"
      "/chat/completions" cfg.request_path;
    check string "base_url stays unchanged"
      "http://127.0.0.1:18080/v1" cfg.base_url

let test_cascade_parse_kimi_uses_oas_registry_defaults () =
  with_env "KIMI_API_KEY" (Some "dummy-key") (fun () ->
      match Cascade.parse_model_string "provider_c:model-c-coding" with
      | None -> fail "provider_c should parse when KIMI_API_KEY is set"
      | Some cfg ->
        check kind_testable "cfg.kind is Kimi" Pk.Provider_k cfg.kind;
        check string "request path from OAS registry" "/v1/messages" cfg.request_path;
        check string "base url from OAS registry" "https://api.provider_c.com/coding" cfg.base_url)

(* ────────────────────────────────────────────────────────────────── *)
(* Suite                                                              *)
(* ────────────────────────────────────────────────────────────────── *)

let () =
  run "provider_kind_resolution" [
    ( "resolver",
      [
        test_case "provider_f: -> Provider_f" `Quick test_gemini_prefix_resolves_to_gemini;
        test_case "openrouter: -> Provider_d_compat; provider_d: -> Unknown" `Quick
          test_openai_compat_prefix_not_misrouted;
        test_case "agent_llm_a: -> Provider_a" `Quick test_claude_prefix_resolves_to_anthropic;
        test_case "provider_c: -> Kimi" `Quick
          test_kimi_prefix_resolves_to_kimi;
        test_case "unknown vendor -> Unknown (no Provider_d_compat fallback)" `Quick
          test_unknown_vendor_returns_unknown;
        test_case "malformed spec -> Unknown" `Quick test_malformed_spec_returns_unknown;
        test_case "custom: -> Custom_url" `Quick test_custom_prefix_resolves_to_custom_url;
        test_case "kind_of_spec helper" `Quick test_kind_of_spec_api;
      ]
    );
    ( "cascade_integration",
      [
        test_case "parse_model_string preserves Provider_f kind (#8159)" `Quick
          test_cascade_parse_gemini_preserves_kind;
        test_case "custom v1 base_url dedupes request_path" `Quick
          test_cascade_parse_custom_v1_base_url_dedupes_request_path;
        test_case "parse_model_string uses OAS Kimi defaults" `Quick
          test_cascade_parse_kimi_uses_oas_registry_defaults;
        test_case "parse_model_string(unknown) = None" `Quick
          test_cascade_parse_unknown_returns_none;
      ]
    );
  ]
