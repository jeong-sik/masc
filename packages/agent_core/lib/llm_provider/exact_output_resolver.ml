module Caps = Capabilities
module PC = Provider_config
module Binding = Exact_output_catalog_binding
module String_map = Map.Make (String)
module String_set = Set.Make (String)

type target_ref = Target_ref of string
type catalog_generation = Catalog_generation of string
type catalog_evidence = Catalog_evidence of string

type target_identity =
  { target_ref : target_ref
  ; provider_id : string
  ; model_id : string
  ; base_url : string
  ; request_path : string
  ; fingerprint : string
  }

type resolver_io = { getenv : string -> (string option, unit) result }

type catalog_document =
  { source : string
  ; contents : string
  }

type resolver_catalog_input =
  | Embedded_default
  | Embedded_with_overlay of catalog_document
  | Full_replacement of catalog_document
  | Full_replacement_file of string

type target_ref_error =
  | Empty_target_ref
  | Invalid_target_ref

type resolver_catalog_source =
  | Embedded_catalog
  | Full_replacement_catalog
  | Overlay_catalog

type resolver_collision =
  | Duplicate_provider_identity
  | Duplicate_model_identity
  | Duplicate_target_identity
  | Provider_alias_shadow
  | Target_identity_shadow
  | Model_identity_shadow

type resolver_binding_component =
  | Target_provider
  | Target_model

type resolver_endpoint_error = Binding.endpoint_error =
  | Malformed_base_url
  | Base_url_userinfo_not_allowed
  | Base_url_query_not_allowed
  | Base_url_fragment_not_allowed
  | Invalid_request_path
  | Unsupported_gemini_request_path
  | Invalid_gemini_model_path

type resolver_snapshot_error =
  | Catalog_read_failed of
      { path : string
      ; detail : string
      }
  | Catalog_parse_failed of
      { source : resolver_catalog_source
      ; detail : string
      }
  | Target_catalog_invalid of
      { source : resolver_catalog_source
      ; detail : string
      }
  | Catalog_collision of resolver_collision
  | Target_binding_missing of
      { target_ref : string
      ; component : resolver_binding_component
      }
  | Target_endpoint_invalid of
      { target_ref : string
      ; cause : resolver_endpoint_error
      }
  | Environment_read_failed of { environment_variable : string }

type target_declaration =
  { target_ref : target_ref
  ; provider_ref : string
  ; model_id : string
  ; enable_thinking : bool option
  ; max_request_body_bytes : int option
  ; connect_timeout_s : float option
  ; body_timeout_s : float option
  }

type credential_outcome =
  | Credential_not_required
  | Credential_available of Secret.t
  | Credential_missing of string
  | Credential_invalid of string
  | Credential_read_failed of string

type frozen_target =
  { config : PC.t
  ; capabilities : Caps.capabilities
  ; anthropic_thinking_control : Caps.anthropic_thinking_control option
  ; body_timeout_s : float option
  ; credential : credential_outcome
  ; identity : target_identity
  }

type resolver_snapshot =
  { targets : frozen_target String_map.t
  ; generation : catalog_generation
  ; evidence : catalog_evidence
  }

type admitted_target =
  { target : frozen_target
  ; generation : catalog_generation
  ; evidence : catalog_evidence
  }

type projection_target =
  { config : PC.t
  ; capabilities : Caps.capabilities
  ; anthropic_thinking_control : Caps.anthropic_thinking_control option
  ; body_timeout_s : float option
  ; model_admitted : bool
  }

type selected_target =
  { config : PC.t
  ; capabilities : Caps.capabilities
  ; anthropic_thinking_control : Caps.anthropic_thinking_control option
  ; body_timeout_s : float option
  ; identity : target_identity
  ; generation : catalog_generation
  ; evidence : catalog_evidence
  }

type target_selection_error =
  | Missing_target_credential of
      { target_ref : string
      ; environment_variable : string
      }
  | Target_credential_invalid of
      { target_ref : string
      ; environment_variable : string
      }
  | Target_credential_read_failed of
      { target_ref : string
      ; environment_variable : string
      }

type target_catalog_admission_error =
  | Target_ref_rejected of target_ref_error
  | Target_not_in_catalog of string

let ( let* ) = Result.bind
let sha256 value = Digestif.SHA256.(to_hex (digest_string value))

let hash_parts parts =
  let material = Buffer.create 512 in
  List.iter
    (fun part ->
       Buffer.add_string material (string_of_int (String.length part));
       Buffer.add_char material ':';
       Buffer.add_string material part)
    parts;
  sha256 (Buffer.contents material)
;;

let valid_target_ref value =
  value <> ""
  && String.for_all
       (function
         | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' | '.' | ':' -> true
         | _ -> false)
       value
;;

let target_ref value =
  if value = ""
  then Error Empty_target_ref
  else if valid_target_ref value
  then Ok (Target_ref value)
  else Error Invalid_target_ref
;;

let target_ref_id (Target_ref value) = value
let catalog_generation_fingerprint (Catalog_generation value) = value
let catalog_evidence_sha256 (Catalog_evidence value) = value
let resolver_catalog_generation (snapshot : resolver_snapshot) = snapshot.generation
let resolver_catalog_evidence (snapshot : resolver_snapshot) = snapshot.evidence
let target_identity_fingerprint identity = identity.fingerprint
let selected_target_identity (target : selected_target) = target.identity
let selected_target_catalog_generation (target : selected_target) = target.generation
let selected_target_catalog_evidence (target : selected_target) = target.evidence

let selected_target_model_admitted (target : selected_target) =
  Binding.target_model_admitted target.capabilities ~model_id:target.config.model_id
;;

let target_catalog_error source detail = Error (Target_catalog_invalid { source; detail })

let target_result source =
  Result.map_error (fun detail -> Target_catalog_invalid { source; detail })
;;

let parse_target_declaration ~source toml =
  let* id =
    Binding.target_string_field ~target_label:"<unknown>" ~field:"id" toml
    |> target_result source
  in
  let* target_ref =
    match target_ref id with
    | Ok target_ref -> Ok target_ref
    | Error _ -> target_catalog_error source "target id is not canonical"
  in
  let known =
    [ "id"
    ; "provider_ref"
    ; "model_id"
    ; "enable_thinking"
    ; "max_request_body_bytes"
    ; "connect_timeout_s"
    ; "body_timeout_s"
    ]
  in
  let* () =
    match Otoml.list_table_keys_result toml with
    | Error _ -> target_catalog_error source "target declaration is not a table"
    | Ok keys ->
      (match List.filter (fun key -> not (List.mem key known)) keys with
       | [] -> Ok ()
       | _ ->
         target_catalog_error source (Printf.sprintf "target %s has unknown fields" id))
  in
  let* provider_ref =
    Binding.target_string_field ~target_label:id ~field:"provider_ref" toml
    |> target_result source
  in
  let* model_id =
    Binding.target_string_field ~target_label:id ~field:"model_id" toml
    |> target_result source
  in
  let* enable_thinking =
    Binding.target_bool_field ~target_label:id ~field:"enable_thinking" toml
    |> target_result source
  in
  let* max_request_body_bytes =
    Binding.target_positive_int_field
      ~target_label:id
      ~field:"max_request_body_bytes"
      toml
    |> target_result source
  in
  let* connect_timeout_s =
    Binding.target_float_field ~target_label:id ~field:"connect_timeout_s" toml
    |> target_result source
  in
  let* body_timeout_s =
    Binding.target_float_field ~target_label:id ~field:"body_timeout_s" toml
    |> target_result source
  in
  let* () =
    Binding.validate_timeout ~target_label:id ~field:"connect_timeout_s" connect_timeout_s
    |> target_result source
  in
  let* () =
    Binding.validate_timeout ~target_label:id ~field:"body_timeout_s" body_timeout_s
    |> target_result source
  in
  Ok
    { target_ref
    ; provider_ref
    ; model_id
    ; enable_thinking
    ; max_request_body_bytes
    ; connect_timeout_s
    ; body_timeout_s
    }
;;

let parse_target_catalog ~source contents =
  try
    let toml = Otoml.Parser.from_string contents in
    let declarations =
      match Otoml.find_opt toml (Otoml.get_array Fun.id) [ "targets" ] with
      | None -> []
      | Some declarations -> declarations
    in
    let* targets =
      List.fold_left
        (fun result declaration ->
           let* targets = result in
           let* target = parse_target_declaration ~source declaration in
           Ok (target :: targets))
        (Ok [])
        declarations
    in
    let* () =
      let rec unique seen = function
        | [] -> Ok ()
        | target :: rest ->
          let identity = target_ref_id target.target_ref |> String.lowercase_ascii in
          if String_set.mem identity seen
          then Error (Catalog_collision Duplicate_target_identity)
          else unique (String_set.add identity seen) rest
      in
      unique String_set.empty targets
    in
    Ok targets
  with
  | Otoml.Parse_error (_position, detail) ->
    Error (Target_catalog_invalid { source; detail })
  | Otoml.Type_error _ ->
    Error
      (Target_catalog_invalid
         { source; detail = "target catalog contains a value of the wrong type" })
;;

let normalize_identity value = String.lowercase_ascii (String.trim value)

let ensure_unique ~collision ~key entries =
  let rec loop seen = function
    | [] -> Ok ()
    | entry :: rest ->
      let identity = key entry in
      if String_set.mem identity seen
      then Error (Catalog_collision collision)
      else loop (String_set.add identity seen) rest
  in
  loop String_set.empty entries
;;

let provider_namespace providers =
  let wire_kind_labels = List.map PC.string_of_provider_kind PC.all_provider_kinds in
  List.fold_left
    (fun result (provider : Model_catalog.provider_entry) ->
       let* namespace = result in
       let* () =
         if
           List.exists
             (fun alias -> List.mem (normalize_identity alias) wire_kind_labels)
             provider.aliases
         then Error (Catalog_collision Provider_alias_shadow)
         else Ok ()
       in
       let labels = provider.id :: provider.aliases in
       List.fold_left
         (fun result label ->
            let* namespace = result in
            let label = normalize_identity label in
            match String_map.find_opt label namespace with
            | None -> Ok (String_map.add label provider.id namespace)
            | Some owner when String.equal owner provider.id -> Ok namespace
            | Some _ -> Error (Catalog_collision Provider_alias_shadow))
         (Ok namespace)
         labels)
    (Ok String_map.empty)
    providers
;;

let validate_catalog_source catalog targets =
  let* () =
    ensure_unique
      ~collision:Duplicate_provider_identity
      ~key:(fun (entry : Model_catalog.provider_entry) -> normalize_identity entry.id)
      (Model_catalog.provider_entries catalog)
  in
  let* () =
    if Binding.model_identities_unique (Model_catalog.model_entries catalog)
    then Ok ()
    else Error (Catalog_collision Duplicate_model_identity)
  in
  let* () =
    ensure_unique
      ~collision:Duplicate_target_identity
      ~key:(fun entry -> target_ref_id entry.target_ref |> normalize_identity)
      targets
  in
  let* _ = provider_namespace (Model_catalog.provider_entries catalog) in
  Ok ()
;;

let validate_overlay_collisions ~base ~base_targets ~overlay ~overlay_targets =
  let* base_namespace = provider_namespace (Model_catalog.provider_entries base) in
  let* () =
    List.fold_left
      (fun result (provider : Model_catalog.provider_entry) ->
         let* () = result in
         List.fold_left
           (fun result label ->
              let* () = result in
              match String_map.find_opt (normalize_identity label) base_namespace with
              | None -> Ok ()
              | Some owner when String.equal owner provider.id -> Ok ()
              | Some _ -> Error (Catalog_collision Provider_alias_shadow))
           (Ok ())
           (provider.id :: provider.aliases))
      (Ok ())
      (Model_catalog.provider_entries overlay)
  in
  let base_targets =
    List.fold_left
      (fun values entry ->
         let id = target_ref_id entry.target_ref in
         String_map.add (normalize_identity id) id values)
      String_map.empty
      base_targets
  in
  let* () =
    List.fold_left
      (fun result entry ->
         let* () = result in
         let id = target_ref_id entry.target_ref in
         match String_map.find_opt (normalize_identity id) base_targets with
         | None -> Ok ()
         | Some base_id when String.equal base_id id -> Ok ()
         | Some _ -> Error (Catalog_collision Target_identity_shadow))
      (Ok ())
      overlay_targets
  in
  if
    Binding.validate_overlay_model_identities
      ~base:(Model_catalog.model_entries base)
      ~overlay:(Model_catalog.model_entries overlay)
  then Ok ()
  else Error (Catalog_collision Model_identity_shadow)
;;

let merge_target_declarations ~base ~overlay =
  let overlay_ids = List.map (fun target -> target_ref_id target.target_ref) overlay in
  overlay
  @ List.filter
      (fun target -> not (List.mem (target_ref_id target.target_ref) overlay_ids))
      base
;;

let%test "exact target id overlay replaces the complete base declaration" =
  let fixture ~model_id ~target_id =
    Printf.sprintf
      "[[providers]]\n\
       id = \"inline-provider\"\n\
       kind = \"openai_compat\"\n\
       base_url = \"https://inline.example\"\n\
       request_path = \"/v1/chat/completions\"\n\
       api_key_env = \"\"\n\n\
       [[models]]\n\
       id_prefix = %S\n\
       provider_name = \"inline-provider\"\n\
       supports_response_format_json = true\n\n\
       [[targets]]\n\
       id = %S\n\
       provider_ref = \"inline-provider\"\n\
       model_id = %S\n"
      model_id
      target_id
      model_id
  in
  let parse source contents =
    match
      ( Model_catalog.of_toml_string
          ~source:"exact target replacement inline test"
          contents
      , parse_target_catalog ~source contents )
    with
    | Ok catalog, Ok targets ->
      (match validate_catalog_source catalog targets with
       | Ok () -> Some (catalog, targets)
       | Error _ -> None)
    | Error _, _ | _, Error _ -> None
  in
  match
    ( parse Embedded_catalog (fixture ~model_id:"base-model" ~target_id:"inline-target")
    , parse Overlay_catalog (fixture ~model_id:"overlay-model" ~target_id:"inline-target")
    )
  with
  | Some (base, base_targets), Some (overlay, overlay_targets) ->
    (match validate_overlay_collisions ~base ~base_targets ~overlay ~overlay_targets with
     | Ok () ->
       merge_target_declarations ~base:base_targets ~overlay:overlay_targets
       = overlay_targets
     | Error _ -> false)
  | None, _ | _, None -> false
;;

let%test "case-only target overlay shadow fails closed" =
  let fixture target_id =
    Printf.sprintf
      "[[providers]]\n\
       id = \"inline-provider\"\n\
       kind = \"openai_compat\"\n\
       base_url = \"https://inline.example\"\n\
       request_path = \"/v1/chat/completions\"\n\
       api_key_env = \"\"\n\n\
       [[models]]\n\
       id_prefix = \"inline-model\"\n\
       provider_name = \"inline-provider\"\n\
       supports_response_format_json = true\n\n\
       [[targets]]\n\
       id = %S\n\
       provider_ref = \"inline-provider\"\n\
       model_id = \"inline-model\"\n"
      target_id
  in
  let parse source contents =
    match
      ( Model_catalog.of_toml_string ~source:"target shadow inline test" contents
      , parse_target_catalog ~source contents )
    with
    | Ok catalog, Ok targets ->
      (match validate_catalog_source catalog targets with
       | Ok () -> Some (catalog, targets)
       | Error _ -> None)
    | Error _, _ | _, Error _ -> None
  in
  match
    ( parse Embedded_catalog (fixture "inline-target")
    , parse Overlay_catalog (fixture "INLINE-TARGET") )
  with
  | Some (base, base_targets), Some (overlay, overlay_targets) ->
    (match validate_overlay_collisions ~base ~base_targets ~overlay ~overlay_targets with
     | Error (Catalog_collision Target_identity_shadow) -> true
     | Ok () | Error _ -> false)
  | None, _ | _, None -> false
;;

let endpoint_result ~target_ref =
  Result.map_error (fun cause ->
    Target_endpoint_invalid { target_ref = target_ref_id target_ref; cause })
;;

let validate_base_url ~target_ref value =
  Binding.validate_base_url value |> endpoint_result ~target_ref
;;

let validate_request_path ~target_ref ~kind value =
  Binding.validate_request_path ~kind value |> endpoint_result ~target_ref
;;

let validate_model_path ~target_ref kind model_id =
  Binding.validate_model_path kind model_id |> endpoint_result ~target_ref
;;

let option_float = function
  | None -> "none"
  | Some value -> Printf.sprintf "some:%.17g" value
;;

let option_string = function
  | None -> "none"
  | Some value -> "some:" ^ value
;;

let option_bool = function
  | None -> "none"
  | Some value -> "some:" ^ Binding.bool_string value
;;

let canonical_supported_models = function
  | None -> "none"
  | Some models -> "some:" ^ String.concat "," (List.sort_uniq String.compare models)
;;

let option_price = function
  | None -> "none"
  | Some value -> Printf.sprintf "some:%.17g" value
;;

(* Evidence is derived only from parsed, validated fields. Raw TOML bytes,
   comments, unknown keys, overlay source labels, and credential values never
   enter this projection. Pricing remains evidence-only. *)
let canonical_catalog_evidence catalog model_entries target_declarations =
  let providers =
    Model_catalog.provider_entries catalog
    |> List.sort (fun (a : Model_catalog.provider_entry) b -> String.compare a.id b.id)
    |> List.concat_map (fun (provider : Model_catalog.provider_entry) ->
      [ "provider"
      ; provider.id
      ; String.concat "," (List.sort_uniq String.compare provider.aliases)
      ; PC.string_of_provider_kind provider.kind
      ; String.concat
          ","
          (provider.identity_kinds
           |> List.map PC.string_of_provider_kind
           |> List.sort_uniq String.compare)
      ; provider.base_url
      ; option_string provider.base_url_env
      ; provider.request_path
      ; provider.api_key_env
      ; option_string provider.default_model
      ; option_string provider.capabilities_base
      ; String.concat "," (List.sort_uniq String.compare provider.identity_hosts)
      ])
  in
  let models =
    model_entries
    |> List.sort Binding.compare_model_entries
    |> List.concat_map (fun (model : Model_catalog.model_entry) ->
      [ "model"
      ; option_string model.provider_name
      ; model.id_prefix
      ; option_string model.base_label
      ; Binding.option_int model.max_context_tokens
      ; Binding.option_int model.max_output_tokens
      ; option_bool model.supports_response_format_json
      ; option_bool model.supports_structured_output
      ; option_bool model.supports_multimodal_inputs
      ; option_bool model.supports_image_input
      ; option_bool model.supports_audio_input
      ; option_bool model.supports_video_input
      ; option_bool model.supports_document_input
      ; option_string model.modality_priority
      ; (match model.task with
         | None -> "none"
         | Some task -> Binding.task_string (Some task))
      ; "supported_models=" ^ canonical_supported_models model.supported_models
      ; option_bool model.supports_system_prompt
      ; Binding.anthropic_thinking_control_string
          (Binding.catalog_anthropic_thinking_control model.anthropic_thinking_control)
      ; "input_per_million=" ^ option_price model.input_per_million
      ; "output_per_million=" ^ option_price model.output_per_million
      ; "cache_write_multiplier=" ^ option_price model.cache_write_multiplier
      ; "cache_read_multiplier=" ^ option_price model.cache_read_multiplier
      ])
  in
  let targets =
    target_declarations
    |> List.sort (fun a b ->
      String.compare (target_ref_id a.target_ref) (target_ref_id b.target_ref))
    |> List.concat_map (fun target ->
      [ "target"
      ; target_ref_id target.target_ref
      ; target.provider_ref
      ; target.model_id
      ; option_bool target.enable_thinking
      ; Binding.option_int target.max_request_body_bytes
      ; option_float target.connect_timeout_s
      ; option_float target.body_timeout_s
      ])
  in
  ("oas-exact-output-catalog-evidence-v4" :: providers) @ models @ targets
;;

let frozen_environment ~io names =
  String_set.fold
    (fun name values -> String_map.add name (io.getenv name) values)
    names
    String_map.empty
;;

let read_full_replacement_file path =
  let path = String.trim path in
  if String.equal path ""
  then Error (Catalog_read_failed { path; detail = "catalog path is empty" })
  else (
    try
      Ok { source = path; contents = In_channel.with_open_bin path In_channel.input_all }
    with
    | exn ->
      Reserved_exn.reraise_if_reserved exn;
      Error (Catalog_read_failed { path; detail = Printexc.to_string exn }))
;;

let load_resolver_snapshot ~io ?(catalog = Embedded_default) () =
  let parse_model_catalog ~source ~parser_source contents =
    match Model_catalog.of_toml_string ~source:parser_source contents with
    | Ok catalog -> Ok catalog
    | Error detail -> Error (Catalog_parse_failed { source; detail })
  in
  let embedded_document =
    { source = "embedded exact-output catalog"
    ; contents = Model_catalog_embedded.contents
    }
  in
  let* base_source, base_document, overlay =
    match catalog with
    | Embedded_default -> Ok (Embedded_catalog, embedded_document, None)
    | Embedded_with_overlay overlay ->
      Ok (Embedded_catalog, embedded_document, Some overlay)
    | Full_replacement document -> Ok (Full_replacement_catalog, document, None)
    | Full_replacement_file path ->
      let* document = read_full_replacement_file path in
      Ok (Full_replacement_catalog, document, None)
  in
  let* base =
    parse_model_catalog
      ~source:base_source
      ~parser_source:base_document.source
      base_document.contents
  in
  let* base_targets = parse_target_catalog ~source:base_source base_document.contents in
  let* () = validate_catalog_source base base_targets in
  let* catalog_models_and_targets =
    match overlay with
    | None -> Ok (base, Model_catalog.model_entries base, base_targets)
    | Some overlay ->
      let* overlay_catalog =
        parse_model_catalog
          ~source:Overlay_catalog
          ~parser_source:overlay.source
          overlay.contents
      in
      let* overlay_targets =
        parse_target_catalog ~source:Overlay_catalog overlay.contents
      in
      let* () = validate_catalog_source overlay_catalog overlay_targets in
      let* () =
        validate_overlay_collisions
          ~base
          ~base_targets
          ~overlay:overlay_catalog
          ~overlay_targets
      in
      Ok
        ( Model_catalog.merge ~base ~overlay:overlay_catalog
        , Binding.merge_exact_model_entries
            ~base:(Model_catalog.model_entries base)
            ~overlay:(Model_catalog.model_entries overlay_catalog)
        , merge_target_declarations ~base:base_targets ~overlay:overlay_targets )
  in
  let catalog, model_entries, target_declarations = catalog_models_and_targets in
  let* structural =
    List.fold_left
      (fun result (target : target_declaration) ->
         let* bindings = result in
         match
           Binding.resolve_exact
             ~catalog
             ~model_entries
             ~provider_ref:target.provider_ref
             ~model_id:target.model_id
         with
         | Error Binding.Provider_missing ->
           Error
             (Target_binding_missing
                { target_ref = target_ref_id target.target_ref
                ; component = Target_provider
                })
         | Error Binding.Model_missing ->
           Error
             (Target_binding_missing
                { target_ref = target_ref_id target.target_ref; component = Target_model })
         | Ok (provider, model) -> Ok ((target, provider, model) :: bindings))
      (Ok [])
      target_declarations
  in
  let environment_names =
    List.fold_left
      (fun names
        (_, (provider : Model_catalog.provider_entry), (_ : Model_catalog.model_entry)) ->
         let names =
           match provider.base_url_env with
           | Some name when name <> "" -> String_set.add name names
           | Some _ | None -> names
         in
         if provider.api_key_env = ""
         then names
         else String_set.add provider.api_key_env names)
      String_set.empty
      structural
  in
  let environment = frozen_environment ~io environment_names in
  let observed_environment name =
    match String_map.find_opt name environment with
    | Some observation -> observation
    | None -> Ok None
  in
  let getenv name =
    match observed_environment name with
    | Ok value -> value
    | Error () -> None
  in
  let* targets =
    List.fold_left
      (fun result
        ( (target : target_declaration)
        , (provider : Model_catalog.provider_entry)
        , (model : Model_catalog.model_entry) ) ->
         let* targets = result in
         let capabilities = Binding.capabilities_of_catalog_binding provider model in
         let anthropic_thinking_control =
           Binding.anthropic_thinking_control_of_model model
         in
         let* () =
           match provider.base_url_env with
           | Some name when name <> "" ->
             (match observed_environment name with
              | Ok _ -> Ok ()
              | Error () ->
                Error (Environment_read_failed { environment_variable = name }))
           | Some _ | None -> Ok ()
         in
         let base_url = Model_provider_catalog.resolved_base_url ~getenv provider in
         let* () = validate_base_url ~target_ref:target.target_ref base_url in
         let* () =
           validate_request_path
             ~target_ref:target.target_ref
             ~kind:provider.kind
             provider.request_path
         in
         let* () =
           validate_model_path ~target_ref:target.target_ref provider.kind target.model_id
         in
         let projection_config =
           PC.make
             ~kind:provider.kind
             ~provider_id:provider.id
             ~model_id:target.model_id
             ~base_url
             ~headers:[]
             ~request_path:provider.request_path
             ?max_tokens:capabilities.max_output_tokens
             ?max_context:capabilities.max_context_tokens
             ?enable_thinking:target.enable_thinking
             ?max_request_body_bytes:target.max_request_body_bytes
             ~supports_structured_output_override:capabilities.supports_structured_output
             ~model_capabilities_override:capabilities
             ?connect_timeout_s:target.connect_timeout_s
             ()
         in
         let codec =
           Provider_http_codec.of_config projection_config
           |> Provider_http_codec.fingerprint_tag
         in
         let identity_fingerprint =
           hash_parts
             ([ "oas-exact-output-target-v4"
              ; target_ref_id target.target_ref
              ; provider.id
              ; PC.string_of_provider_kind provider.kind
              ; target.model_id
              ; base_url
              ; provider.request_path
              ; provider.api_key_env
              ; option_bool target.enable_thinking
              ; Binding.option_int target.max_request_body_bytes
              ; option_float target.connect_timeout_s
              ; option_float target.body_timeout_s
              ; codec
              ; "content-type\000application/json"
              ]
              @ Binding.functional_capability_projection
                  capabilities
                  ~anthropic_thinking_control)
         in
         let identity =
           { target_ref = target.target_ref
           ; provider_id = provider.id
           ; model_id = target.model_id
           ; base_url
           ; request_path = provider.request_path
           ; fingerprint = identity_fingerprint
           }
         in
         let credential =
           if provider.api_key_env = ""
           then Credential_not_required
           else (
             match observed_environment provider.api_key_env with
             | Error () -> Credential_read_failed provider.api_key_env
             | Ok (Some value) when Binding.has_control value ->
               Credential_invalid provider.api_key_env
             | Ok (Some value) ->
               (match Cli_common_env.trim_non_empty value with
                | Some credential -> Credential_available (Secret.of_string credential)
                | None -> Credential_missing provider.api_key_env)
             | Ok None -> Credential_missing provider.api_key_env)
         in
         let target_id = target_ref_id target.target_ref in
         Ok
           (String_map.add
              target_id
              { config = projection_config
              ; capabilities
              ; anthropic_thinking_control
              ; body_timeout_s = target.body_timeout_s
              ; credential
              ; identity
              }
              targets))
      (Ok String_map.empty)
      structural
  in
  let generation =
    String_map.bindings targets
    |> List.concat_map (fun (id, (target : frozen_target)) ->
      [ id; target.identity.fingerprint ])
    |> fun material ->
    Catalog_generation (hash_parts ("oas-catalog-generation-v1" :: material))
  in
  let evidence_material =
    canonical_catalog_evidence catalog model_entries target_declarations
  in
  let evidence = Catalog_evidence (hash_parts evidence_material) in
  Ok { targets; generation; evidence }
;;

let admit_target_ref snapshot value =
  match target_ref value with
  | Error error -> Error (Target_ref_rejected error)
  | Ok (Target_ref id) ->
    (match String_map.find_opt id snapshot.targets with
     | None -> Error (Target_not_in_catalog id)
     | Some target ->
       Ok { target; generation = snapshot.generation; evidence = snapshot.evidence })
;;

let admitted_target_identity (admitted : admitted_target) = admitted.target.identity
let admitted_target_catalog_generation (admitted : admitted_target) = admitted.generation
let admitted_target_catalog_evidence (admitted : admitted_target) = admitted.evidence

let projection_target (admitted : admitted_target) =
  let target = admitted.target in
  { config = target.config
  ; capabilities = target.capabilities
  ; anthropic_thinking_control = target.anthropic_thinking_control
  ; body_timeout_s = target.body_timeout_s
  ; model_admitted =
      Binding.target_model_admitted target.capabilities ~model_id:target.config.model_id
  }
;;

let resolve_target (admitted : admitted_target) =
  let target = admitted.target in
  let target_ref = target_ref_id target.identity.target_ref in
  let select frozen_api_key =
    let config = { target.config with api_key = frozen_api_key } in
    let selected : selected_target =
      { config
      ; capabilities = target.capabilities
      ; anthropic_thinking_control = target.anthropic_thinking_control
      ; body_timeout_s = target.body_timeout_s
      ; identity = target.identity
      ; generation = admitted.generation
      ; evidence = admitted.evidence
      }
    in
    Ok selected
  in
  match target.credential with
  | Credential_missing environment_variable ->
    Error (Missing_target_credential { target_ref; environment_variable })
  | Credential_invalid environment_variable ->
    Error (Target_credential_invalid { target_ref; environment_variable })
  | Credential_read_failed environment_variable ->
    Error (Target_credential_read_failed { target_ref; environment_variable })
  | Credential_not_required -> select Secret.empty
  | Credential_available frozen_api_key -> select frozen_api_key
;;
