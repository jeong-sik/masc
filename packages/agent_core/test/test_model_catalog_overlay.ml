open Alcotest
module Model_catalog = Llm_provider.Model_catalog

let catalog_of ~suite toml =
  match Model_catalog.of_toml_string ~source:(suite ^ " inline catalog") toml with
  | Ok catalog -> catalog
  | Error msg -> failf "%s: inline catalog should parse: %s" suite msg
;;

let with_clean_model_catalog_override f =
  Model_catalog.clear_global ();
  Fun.protect ~finally:Model_catalog.clear_global f
;;

let scoped_row ?(extra = "") ~provider ~model ~max_context () =
  Printf.sprintf
    "[[models]]\nid_prefix = %S\nprovider_name = %S\nmax_context_tokens = %d\n%s"
    model
    provider
    max_context
    extra
;;

let bare_row ~model ~max_context =
  Printf.sprintf "[[models]]\nid_prefix = %S\nmax_context_tokens = %d\n" model max_context
;;

let provider_entry ?(aliases = []) ~id ~base_url () =
  let aliases =
    match aliases with
    | [] -> ""
    | aliases ->
      Printf.sprintf
        "aliases = [%s]\n"
        (String.concat ", " (List.map (Printf.sprintf "%S") aliases))
  in
  Printf.sprintf
    "[[providers]]\n\
     id = %S\n\
     %skind = \"openai_compat\"\n\
     base_url = %S\n\
     request_path = \"/v1/chat/completions\"\n\
     api_key_env = \"\"\n\
     capabilities_base = \"openai_chat\"\n"
    id
    aliases
    base_url
;;

let max_context ~suite ~what = function
  | None -> failf "%s: expected %s row" suite what
  | Some (entry : Model_catalog.model_entry) -> entry.max_context_tokens
;;

(* --- merge --- *)

let test_merge_overlay_row_replaces_same_key () =
  let suite = "merge same key" in
  let base =
    catalog_of
      ~suite
      (scoped_row ~provider:"prov-a" ~model:"model-1" ~max_context:100 ()
       ^ scoped_row ~provider:"prov-a" ~model:"model-2" ~max_context:300 ())
  in
  let overlay =
    catalog_of ~suite (scoped_row ~provider:"prov-a" ~model:"model-1" ~max_context:200 ())
  in
  let merged = Model_catalog.merge ~base ~overlay in
  check
    (option int)
    "overlay row wins on the shared (provider_name, id_prefix) key"
    (Some 200)
    (max_context
       ~suite
       ~what:"overridden"
       (Model_catalog.lookup_for_provider
          merged
          ~provider_name:"prov-a"
          ~model_id:"model-1"));
  check
    (option int)
    "base row with a different key survives"
    (Some 300)
    (max_context
       ~suite
       ~what:"untouched"
       (Model_catalog.lookup_for_provider
          merged
          ~provider_name:"prov-a"
          ~model_id:"model-2"));
  check
    int
    "no duplicate rows for the shared key"
    2
    (List.length (Model_catalog.model_entries merged))
;;

let test_merge_keeps_bare_and_scoped_rows_distinct () =
  let suite = "merge bare vs scoped" in
  let base = catalog_of ~suite (bare_row ~model:"model-1" ~max_context:100) in
  let overlay =
    catalog_of ~suite (scoped_row ~provider:"prov-a" ~model:"model-1" ~max_context:200 ())
  in
  let merged = Model_catalog.merge ~base ~overlay in
  check
    (option int)
    "bare row remains reachable through the bare lookup"
    (Some 100)
    (max_context ~suite ~what:"bare" (Model_catalog.lookup merged "model-1"));
  check
    (option int)
    "scoped overlay row is reachable through the provider lookup"
    (Some 200)
    (max_context
       ~suite
       ~what:"scoped"
       (Model_catalog.lookup_for_provider
          merged
          ~provider_name:"prov-a"
          ~model_id:"model-1"))
;;

let test_merge_provider_entries_replace_by_id () =
  let suite = "merge provider entries" in
  let base =
    catalog_of
      ~suite
      (provider_entry ~id:"prov-a" ~base_url:"https://base.example" ()
       ^ provider_entry ~id:"prov-b" ~base_url:"https://other.example" ())
  in
  let overlay =
    catalog_of ~suite (provider_entry ~id:"prov-a" ~base_url:"https://overlay.example" ())
  in
  let merged = Model_catalog.merge ~base ~overlay in
  check
    int
    "one entry per provider id"
    2
    (List.length (Model_catalog.provider_entries merged));
  let prov_a =
    List.find_opt
      (fun (entry : Model_catalog.provider_entry) -> String.equal entry.id "prov-a")
      (Model_catalog.provider_entries merged)
  in
  match prov_a with
  | None -> failf "%s: merged catalog should keep prov-a" suite
  | Some entry ->
    check string "overlay provider entry wins" "https://overlay.example" entry.base_url
;;

(* --- global composition --- *)

let overlay_only_row_provider = "overlay-only-provider"
let overlay_only_row_model = "overlay-only-model"

let tiny_overlay ~suite =
  catalog_of
    ~suite
    (scoped_row
       ~provider:overlay_only_row_provider
       ~model:overlay_only_row_model
       ~max_context:4242
       ())
;;

let test_global_overlay_composes_with_embedded () =
  let suite = "global overlay" in
  with_clean_model_catalog_override
  @@ fun () ->
  let embedded =
    match Model_catalog.load_default () with
    | Ok catalog -> catalog
    | Error msg -> failf "%s: embedded catalog should load: %s" suite msg
  in
  Model_catalog.set_global_overlay (tiny_overlay ~suite);
  match Model_catalog.global () with
  | None -> failf "%s: global catalog should be available" suite
  | Some merged ->
    check
      (option int)
      "overlay delta row resolves through the global catalog"
      (Some 4242)
      (max_context
         ~suite
         ~what:"overlay"
         (Model_catalog.lookup_for_provider
            merged
            ~provider_name:overlay_only_row_provider
            ~model_id:overlay_only_row_model));
    check
      int
      "every embedded row stays visible next to the delta"
      (List.length (Model_catalog.model_entries embedded) + 1)
      (List.length (Model_catalog.model_entries merged))
;;

let test_set_global_still_wins_over_overlay () =
  let suite = "set_global precedence" in
  with_clean_model_catalog_override
  @@ fun () ->
  Model_catalog.set_global_overlay (tiny_overlay ~suite);
  let replacement =
    catalog_of ~suite (scoped_row ~provider:"prov-a" ~model:"model-1" ~max_context:7 ())
  in
  Model_catalog.set_global replacement;
  match Model_catalog.global () with
  | None -> failf "%s: global catalog should be available" suite
  | Some catalog ->
    check
      int
      "full replacement hides both embedded and overlay rows"
      1
      (List.length (Model_catalog.model_entries catalog));
    check
      bool
      "overlay delta row is not reachable through a full replacement"
      true
      (Option.is_none
         (Model_catalog.lookup_for_provider
            catalog
            ~provider_name:overlay_only_row_provider
            ~model_id:overlay_only_row_model))
;;

let test_clear_global_drops_overlay () =
  let suite = "clear_global overlay" in
  with_clean_model_catalog_override
  @@ fun () ->
  Model_catalog.set_global_overlay (tiny_overlay ~suite);
  Model_catalog.clear_global ();
  match Model_catalog.global () with
  | None -> failf "%s: global catalog should be available" suite
  | Some catalog ->
    check
      bool
      "overlay delta row is gone after clear_global"
      true
      (Option.is_none
         (Model_catalog.lookup_for_provider
            catalog
            ~provider_name:overlay_only_row_provider
            ~model_id:overlay_only_row_model))
;;

(* --- alias-canonicalized provider lookup --- *)

let test_lookup_for_provider_resolves_declared_alias () =
  let suite = "alias lookup" in
  let catalog =
    catalog_of
      ~suite
      (provider_entry
         ~id:"serving-contract"
         ~aliases:[ "deployment-alias" ]
         ~base_url:"https://serving.example"
         ()
       ^ scoped_row ~provider:"serving-contract" ~model:"model-1" ~max_context:111 ())
  in
  check
    (option int)
    "alias resolves to the serving-contract row"
    (Some 111)
    (max_context
       ~suite
       ~what:"alias-resolved"
       (Model_catalog.lookup_for_provider
          catalog
          ~provider_name:"deployment-alias"
          ~model_id:"model-1"));
  check
    bool
    "an undeclared provider name still misses"
    true
    (Option.is_none
       (Model_catalog.lookup_for_provider
          catalog
          ~provider_name:"unrelated"
          ~model_id:"model-1"))
;;

let test_lookup_for_provider_prefers_verbatim_over_alias () =
  let suite = "alias precedence" in
  let catalog =
    catalog_of
      ~suite
      (provider_entry
         ~id:"serving-contract"
         ~aliases:[ "deployment-alias" ]
         ~base_url:"https://serving.example"
         ()
       ^ scoped_row ~provider:"serving-contract" ~model:"model-1" ~max_context:222 ()
       ^ scoped_row ~provider:"deployment-alias" ~model:"model-1" ~max_context:111 ())
  in
  check
    (option int)
    "a verbatim provider row wins over alias canonicalization"
    (Some 111)
    (max_context
       ~suite
       ~what:"verbatim"
       (Model_catalog.lookup_for_provider
          catalog
          ~provider_name:"deployment-alias"
          ~model_id:"model-1"))
;;

(* --- review hardening (oas#2604 Codex P2s) --- *)

let test_merge_overlay_provider_wins_endpoint_identity () =
  let suite = "merge endpoint identity" in
  let base =
    catalog_of
      ~suite
      (provider_entry ~id:"embedded-prov" ~base_url:"https://shared.example" ())
  in
  let overlay =
    catalog_of
      ~suite
      (provider_entry ~id:"deployment-prov" ~base_url:"https://shared.example" ())
  in
  let merged = Model_catalog.merge ~base ~overlay in
  check
    (option string)
    "overlay provider entry wins order-sensitive endpoint identity"
    (Some "deployment-prov")
    (Model_catalog.provider_label_for_base_url
       merged
       ~kind:Llm_provider.Provider_kind.OpenAI_compat
       ~base_url:"https://shared.example")
;;

let test_wire_kind_label_is_never_alias_canonicalized () =
  let suite = "wire-kind alias guard" in
  let catalog =
    catalog_of
      ~suite
      (provider_entry
         ~id:"hijack-prov"
         ~aliases:[ "openai_compat" ]
         ~base_url:"https://hijack.example"
         ()
       ^ scoped_row ~provider:"hijack-prov" ~model:"model-1" ~max_context:333 ())
  in
  check
    bool
    "an alias claiming a wire-kind label captures nothing"
    true
    (Option.is_none
       (Model_catalog.lookup_for_provider
          catalog
          ~provider_name:"openai_compat"
          ~model_id:"model-1"));
  check
    (option int)
    "the provider's own id still resolves its scoped row"
    (Some 333)
    (max_context
       ~suite
       ~what:"verbatim"
       (Model_catalog.lookup_for_provider
          catalog
          ~provider_name:"hijack-prov"
          ~model_id:"model-1"))
;;

let test_overlay_swap_replaces_merged_cache () =
  let suite = "overlay swap" in
  with_clean_model_catalog_override
  @@ fun () ->
  let lookup_overlay_row () =
    match Model_catalog.global () with
    | None -> failf "%s: global catalog should be available" suite
    | Some catalog ->
      max_context
        ~suite
        ~what:"overlay"
        (Model_catalog.lookup_for_provider
           catalog
           ~provider_name:overlay_only_row_provider
           ~model_id:overlay_only_row_model)
  in
  Model_catalog.set_global_overlay (tiny_overlay ~suite);
  check (option int) "first overlay serves its row" (Some 4242) (lookup_overlay_row ());
  let replacement =
    catalog_of
      ~suite
      (scoped_row
         ~provider:overlay_only_row_provider
         ~model:overlay_only_row_model
         ~max_context:7777
         ())
  in
  Model_catalog.set_global_overlay replacement;
  check
    (option int)
    "swapped overlay replaces the cached merge"
    (Some 7777)
    (lookup_overlay_row ())
;;

let () =
  run
    "model_catalog_overlay"
    [ ( "merge"
      , [ test_case
            "overlay row replaces same key"
            `Quick
            test_merge_overlay_row_replaces_same_key
        ; test_case
            "bare and scoped rows stay distinct"
            `Quick
            test_merge_keeps_bare_and_scoped_rows_distinct
        ; test_case
            "provider entries replace by id"
            `Quick
            test_merge_provider_entries_replace_by_id
        ; test_case
            "overlay provider wins endpoint identity"
            `Quick
            test_merge_overlay_provider_wins_endpoint_identity
        ] )
    ; ( "global"
      , [ test_case
            "overlay composes with embedded"
            `Quick
            test_global_overlay_composes_with_embedded
        ; test_case
            "set_global wins over overlay"
            `Quick
            test_set_global_still_wins_over_overlay
        ; test_case "clear_global drops overlay" `Quick test_clear_global_drops_overlay
        ; test_case
            "overlay swap replaces merged cache"
            `Quick
            test_overlay_swap_replaces_merged_cache
        ] )
    ; ( "alias"
      , [ test_case
            "declared alias resolves to serving contract"
            `Quick
            test_lookup_for_provider_resolves_declared_alias
        ; test_case
            "verbatim row wins over alias"
            `Quick
            test_lookup_for_provider_prefers_verbatim_over_alias
        ; test_case
            "wire-kind label never canonicalized"
            `Quick
            test_wire_kind_label_is_never_alias_canonicalized
        ] )
    ]
;;
