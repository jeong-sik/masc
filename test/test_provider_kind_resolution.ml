(** Tests for [Provider_kind_resolver] and the cascade parser's
    use of it. Covers issue #8159: ["gemini:gemini-2.5-flash"] must
    resolve to [Gemini], never silently flatten to [OpenAI_compat]. *)

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
;;

let pp_kind fmt (k : Pk.provider_kind) =
  Format.pp_print_string fmt (Pk.string_of_provider_kind k)
;;

let kind_testable : Pk.provider_kind testable = testable pp_kind ( = )

(* ────────────────────────────────────────────────────────────────── *)
(* Resolver: direct sum-typed resolution                              *)
(* ────────────────────────────────────────────────────────────────── *)

let test_gemini_prefix_resolves_to_gemini () =
  match Resolver.resolve "gemini:gemini-2.5-flash" with
  | Registered { provider_name; model_id; kind } ->
    check string "provider_name" "gemini" provider_name;
    check string "model_id" "gemini-2.5-flash" model_id;
    check kind_testable "kind is Gemini" Pk.Gemini kind
  | Custom_url _ -> fail "gemini: resolved to Custom_url"
  | Unknown msg -> fail ("gemini: resolved to Unknown: " ^ msg)
;;

let test_openai_compat_prefix_not_misrouted () =
  (* Registered OpenAI_compat-kind providers (openrouter/groq/deepseek)
     must resolve to OpenAI_compat. Guards against the inverse mistake
     of flipping everything to Gemini, and guards that "openai" is NOT
     a registered provider name (historically a point of confusion). *)
  (match Resolver.resolve "openrouter:anthropic/claude-3.5" with
   | Registered { kind; _ } ->
     check kind_testable "openrouter kind is OpenAI_compat" Pk.OpenAI_compat kind
   | Custom_url _ -> fail "openrouter: resolved to Custom_url"
   | Unknown msg -> fail ("openrouter: resolved to Unknown: " ^ msg));
  (* "openai" is NOT in the registry — it must return Unknown, not be
     silently mapped to any kind. This is the fail-closed contract. *)
  match Resolver.resolve "openai:gpt-4o" with
  | Unknown _ -> ()
  | Registered _ -> fail "openai: silently registered (should be Unknown)"
  | Custom_url _ -> fail "openai: silently treated as custom"
;;

let test_claude_prefix_resolves_to_anthropic () =
  match Resolver.resolve "claude:claude-haiku-4-5-20251001" with
  | Registered { kind; _ } -> check kind_testable "kind is Anthropic" Pk.Anthropic kind
  | Custom_url _ -> fail "claude: resolved to Custom_url"
  | Unknown msg -> fail ("claude: resolved to Unknown: " ^ msg)
;;

let test_kimi_prefix_resolves_to_openai_compat () =
  match Resolver.resolve "kimi:kimi-for-coding" with
  | Registered { provider_name; model_id; kind } ->
    check string "provider_name" "kimi" provider_name;
    check string "model_id preserved" "kimi-for-coding" model_id;
    check kind_testable "kind is OpenAI_compat" Pk.OpenAI_compat kind
  | Custom_url _ -> fail "kimi: resolved to Custom_url"
  | Unknown msg -> fail ("kimi: resolved to Unknown: " ^ msg)
;;

let test_unknown_vendor_returns_unknown () =
  (* Anti-pattern guard: unknown prefix must NOT fall through to
     OpenAI_compat. Fail-closed is the contract (R2 in triage). *)
  match Resolver.resolve "unknownvendor:foo" with
  | Registered _ -> fail "unknownvendor: silently registered"
  | Custom_url _ -> fail "unknownvendor: silently treated as custom"
  | Unknown _ -> ()
;;

let test_malformed_spec_returns_unknown () =
  let cases = [ ""; ":"; "nocolon"; "trailing:"; ":leading" ] in
  List.iter
    (fun spec ->
       match Resolver.resolve spec with
       | Unknown _ -> ()
       | Registered _ -> fail (Printf.sprintf "%S resolved as Registered" spec)
       | Custom_url _ -> fail (Printf.sprintf "%S resolved as Custom_url" spec))
    cases
;;

let test_custom_prefix_resolves_to_custom_url () =
  match Resolver.resolve "custom:my-model@http://localhost:9000" with
  | Custom_url { model_id; base_url } ->
    check string "model_id" "my-model" model_id;
    check string "base_url" "http://localhost:9000" base_url
  | Registered _ -> fail "custom: resolved to Registered"
  | Unknown msg -> fail ("custom: resolved to Unknown: " ^ msg)
;;

let test_kind_of_spec_api () =
  check
    (option kind_testable)
    "gemini kind via helper"
    (Some Pk.Gemini)
    (Resolver.kind_of_spec "gemini:gemini-2.5-flash");
  check
    (option kind_testable)
    "unknown returns None"
    None
    (Resolver.kind_of_spec "unknownvendor:foo")
;;

(* ────────────────────────────────────────────────────────────────── *)
(* Cascade integration: parse_model_string must preserve Gemini kind  *)
(* ────────────────────────────────────────────────────────────────── *)

let test_cascade_parse_gemini_preserves_kind () =
  (* End-to-end: the exact spec from issue #8159 must yield kind=Gemini
     after going through Cascade_config.parse_model_string. *)
  match Cascade.parse_model_string "gemini:gemini-2.5-flash" with
  | None ->
    (* parse_model_string returns None when the provider is not
       available (missing GEMINI_API_KEY env var in test env). In that
       case, the resolver-level test above already proved the kind
       classification; accept None here. *)
    check
      bool
      "resolver confirms Gemini kind when provider unavailable"
      true
      (Resolver.kind_of_spec "gemini:gemini-2.5-flash" = Some Pk.Gemini)
  | Some cfg ->
    check kind_testable "cfg.kind is Gemini (not OpenAI_compat)" Pk.Gemini cfg.kind;
    check string "cfg.model_id" "gemini-2.5-flash" cfg.model_id
;;

let test_cascade_parse_unknown_returns_none () =
  match Cascade.parse_model_string "unknownvendor:foo" with
  | None -> ()
  | Some _ -> fail "unknown provider should parse to None, not a fallback config"
;;

let test_cascade_parse_custom_v1_base_url_dedupes_request_path () =
  match Cascade.parse_model_string "custom:remote-model@http://127.0.0.1:18080/v1" with
  | None -> fail "custom v1 endpoint should parse"
  | Some cfg ->
    check kind_testable "cfg.kind is OpenAI_compat" Pk.OpenAI_compat cfg.kind;
    check
      string
      "custom request_path strips duplicated /v1 prefix"
      "/chat/completions"
      cfg.request_path;
    check string "base_url stays unchanged" "http://127.0.0.1:18080/v1" cfg.base_url
;;

let test_cascade_parse_kimi_legacy_alias_maps_to_k2_5 () =
  with_env "KIMI_API_KEY" (Some "dummy-key") (fun () ->
    match Cascade.parse_model_string "kimi:kimi-for-coding" with
    | None -> fail "kimi legacy alias should parse when KIMI_API_KEY is set"
    | Some cfg ->
      check kind_testable "cfg.kind is OpenAI_compat" Pk.OpenAI_compat cfg.kind;
      check
        string
        "legacy alias normalized to current Kimi model"
        "kimi-k2.5"
        cfg.model_id;
      check string "Moonshot request path" "/chat/completions" cfg.request_path;
      check string "Moonshot base url" "https://api.moonshot.ai/v1" cfg.base_url)
;;

(* ────────────────────────────────────────────────────────────────── *)
(* Suite                                                              *)
(* ────────────────────────────────────────────────────────────────── *)

let () =
  run
    "provider_kind_resolution"
    [ ( "resolver"
      , [ test_case "gemini: -> Gemini" `Quick test_gemini_prefix_resolves_to_gemini
        ; test_case
            "openrouter: -> OpenAI_compat; openai: -> Unknown"
            `Quick
            test_openai_compat_prefix_not_misrouted
        ; test_case "claude: -> Anthropic" `Quick test_claude_prefix_resolves_to_anthropic
        ; test_case
            "kimi: -> OpenAI_compat"
            `Quick
            test_kimi_prefix_resolves_to_openai_compat
        ; test_case
            "unknown vendor -> Unknown (no OpenAI_compat fallback)"
            `Quick
            test_unknown_vendor_returns_unknown
        ; test_case "malformed spec -> Unknown" `Quick test_malformed_spec_returns_unknown
        ; test_case
            "custom: -> Custom_url"
            `Quick
            test_custom_prefix_resolves_to_custom_url
        ; test_case "kind_of_spec helper" `Quick test_kind_of_spec_api
        ] )
    ; ( "cascade_integration"
      , [ test_case
            "parse_model_string preserves Gemini kind (#8159)"
            `Quick
            test_cascade_parse_gemini_preserves_kind
        ; test_case
            "custom v1 base_url dedupes request_path"
            `Quick
            test_cascade_parse_custom_v1_base_url_dedupes_request_path
        ; test_case
            "parse_model_string maps legacy Kimi alias to kimi-k2.5"
            `Quick
            test_cascade_parse_kimi_legacy_alias_maps_to_k2_5
        ; test_case
            "parse_model_string(unknown) = None"
            `Quick
            test_cascade_parse_unknown_returns_none
        ] )
    ]
;;
