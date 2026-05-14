(** Cascade provider metadata read from [cascade.toml]. *)

type provider_metadata =
  { id : string
  ; labels : string list
  ; telemetry_bucket : string option
  ; telemetry_model_prefixes : string list
  ; tool_policy : tool_policy_metadata
  }

and tool_policy_metadata =
  { supports_runtime_mcp_http_headers : bool
  ; requires_per_keeper_bridging_for_bound_actor_tools : bool
  ; identity_runtime_mcp_header_keys : string list
  ; argv_prompt_preflight : bool
  ; uses_anthropic_caching : bool
  ; max_turns_per_attempt : int option
  ; tolerates_bound_actor_fallback : bool
  }

type model_ref =
  { model_id : string
  ; api_name : string
  ; match_prefixes : string list
  ; telemetry_bucket : string option
  }

type binding =
  { provider_id : string
  ; model_id : string
  }

type snapshot =
  { path : string
  ; mtime : float
  ; providers : provider_metadata list
  ; models : model_ref list
  ; bindings : binding list
  }

let normalize_label value = String.trim value |> String.lowercase_ascii

let trim_nonempty value =
  let value = String.trim value in
  if String.equal value "" then None else Some value
;;

let starts_with_ci ~prefix value =
  let prefix = normalize_label prefix in
  let value = normalize_label value in
  let prefix_len = String.length prefix in
  String.length value >= prefix_len
  && String.equal (String.sub value 0 prefix_len) prefix
;;

let add_unique value values =
  match trim_nonempty value with
  | None -> values
  | Some value ->
    let normalized = normalize_label value in
    if List.exists (fun existing -> normalize_label existing = normalized) values
    then values
    else value :: values
;;

let add_unique_all values acc = List.fold_left (fun acc value -> add_unique value acc) acc values

let table_opt = function
  | Otoml.TomlTable fields | Otoml.TomlInlineTable fields -> Some fields
  | _ -> None
;;

let find_table_opt key fields = Option.bind (List.assoc_opt key fields) table_opt

let find_any_table_opt keys fields =
  List.find_map (fun key -> find_table_opt key fields) keys
;;

let string_opt key fields =
  match List.assoc_opt key fields with
  | Some (Otoml.TomlString value) -> trim_nonempty value
  | _ -> None
;;

let string_any_opt keys fields =
  List.find_map (fun key -> string_opt key fields) keys
;;

let bool_any_opt keys fields =
  List.find_map
    (fun key ->
       match List.assoc_opt key fields with
       | Some (Otoml.TomlBoolean value) -> Some value
       | _ -> None)
    keys
;;

let int_any_opt keys fields =
  List.find_map
    (fun key ->
       match List.assoc_opt key fields with
       | Some (Otoml.TomlInteger value) -> Some value
       | _ -> None)
    keys
;;

let string_list_opt key fields =
  match List.assoc_opt key fields with
  | Some (Otoml.TomlArray values) ->
    Some
      (List.filter_map
         (function
           | Otoml.TomlString value -> trim_nonempty value
           | _ -> None)
         values)
  | _ -> None
;;

let string_list_any_opt keys fields =
  List.find_map (fun key -> string_list_opt key fields) keys
;;

let existing_file_opt path =
  try
    if Sys.file_exists path && not (Sys.is_directory path) then Some path else None
  with
  | Sys_error _ -> None
;;

let env_file env_var suffix =
  Option.bind (Sys.getenv_opt env_var) (fun root ->
      trim_nonempty root |> Option.map (fun root -> Filename.concat root suffix))
;;

let absolute_path path =
  if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path else path
;;

let rec ancestor_dirs path =
  let dir = absolute_path path in
  let parent = Filename.dirname dir in
  if String.equal parent dir then [ dir ] else dir :: ancestor_dirs parent
;;

let ancestor_config_path_opt start =
  ancestor_dirs start
  |> List.find_map (fun dir ->
      existing_file_opt (Filename.concat dir "config/cascade.toml"))
;;

let executable_config_path_opt () =
  Sys.executable_name |> Filename.dirname |> ancestor_config_path_opt
;;

let cascade_path_opt () =
  [ env_file "MASC_CONFIG_DIR" "cascade.toml"
  ; env_file "MASC_BASE_PATH" ".masc/config/cascade.toml"
  ; (Sys.getenv_opt "DUNE_SOURCEROOT"
     |> Option.map (fun root -> Filename.concat root "config/cascade.toml"))
  ; executable_config_path_opt ()
  ; Some (Filename.concat (Sys.getcwd ()) "config/cascade.toml")
  ; ancestor_config_path_opt (Sys.getcwd ())
  ; Config_dir_resolver.cascade_path_opt ()
  ]
  |> List.filter_map Fun.id
  |> List.find_map existing_file_opt
;;

let file_mtime path =
  try (Unix.stat path).Unix.st_mtime with
  | Unix.Unix_error _ -> 0.0
;;

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))
;;

let raw_toml_fields path =
  try
    match Otoml.Parser.from_string_result (read_file path) with
    | Ok toml -> table_opt toml |> Option.value ~default:[]
    | Error _ -> []
  with
  | Sys_error _ | End_of_file -> []
;;

let parse_provider_metadata provider_id provider_fields =
  let telemetry_bucket =
    string_any_opt [ "telemetry-bucket"; "telemetry_bucket" ] provider_fields
  in
  let telemetry_model_prefixes =
    string_list_any_opt [ "telemetry-model-prefixes"; "telemetry_model_prefixes" ]
      provider_fields
    |> Option.value ~default:[]
  in
  let telemetry_aliases =
    string_list_any_opt [ "telemetry-aliases"; "telemetry_aliases" ] provider_fields
    |> Option.value ~default:[]
  in
  let mcp_client_fields =
    find_any_table_opt [ "mcp_client_config"; "mcp-client-config" ] provider_fields
  in
  let spawn_fields = find_table_opt "spawn" provider_fields in
  let labels =
    []
    |> add_unique provider_id
    |> add_unique_all telemetry_aliases
    |> (fun labels ->
      match string_any_opt [ "provider-name"; "provider_name" ] provider_fields with
      | Some value -> add_unique value labels
      | None -> labels)
    |> (fun labels ->
      match mcp_client_fields with
      | None -> labels
      | Some fields ->
        labels
        |> (fun labels ->
          match string_any_opt [ "client-name"; "client_name" ] fields with
          | Some value -> add_unique value labels
          | None -> labels)
        |> (fun labels ->
          match string_any_opt [ "agent-name"; "agent_name" ] fields with
          | Some value -> add_unique value labels
          | None -> labels)
        |> add_unique_all
             (string_list_any_opt [ "legacy-agent-names"; "legacy_agent_names" ] fields
              |> Option.value ~default:[]))
    |> (fun labels ->
      match spawn_fields with
      | None -> labels
      | Some fields ->
        labels
        |> (fun labels ->
          match string_any_opt [ "agent-name"; "agent_name" ] fields with
          | Some value -> add_unique value labels
          | None -> labels)
        |> add_unique_all
             (string_list_any_opt [ "aliases" ] fields |> Option.value ~default:[]))
    |> List.rev
  in
  let tool_policy =
    match find_table_opt "capabilities" provider_fields with
    | None ->
      { supports_runtime_mcp_http_headers = false
      ; requires_per_keeper_bridging_for_bound_actor_tools = false
      ; identity_runtime_mcp_header_keys = []
      ; argv_prompt_preflight = false
      ; uses_anthropic_caching = false
      ; max_turns_per_attempt = None
      ; tolerates_bound_actor_fallback = false
      }
    | Some fields ->
      { supports_runtime_mcp_http_headers =
          bool_any_opt
            [ "supports-runtime-mcp-http-headers"
            ; "supports_runtime_mcp_http_headers"
            ]
            fields
          |> Option.value ~default:false
      ; requires_per_keeper_bridging_for_bound_actor_tools =
          bool_any_opt
            [ "requires-per-keeper-bridging-for-bound-actor-tools"
            ; "requires_per_keeper_bridging_for_bound_actor_tools"
            ]
            fields
          |> Option.value ~default:false
      ; identity_runtime_mcp_header_keys =
          string_list_any_opt
            [ "identity-runtime-mcp-header-keys"
            ; "identity_runtime_mcp_header_keys"
            ]
            fields
          |> Option.value ~default:[]
      ; argv_prompt_preflight =
          bool_any_opt [ "argv-prompt-preflight"; "argv_prompt_preflight" ] fields
          |> Option.value ~default:false
      ; uses_anthropic_caching =
          bool_any_opt [ "uses-anthropic-caching"; "uses_anthropic_caching" ] fields
          |> Option.value ~default:false
      ; max_turns_per_attempt =
          int_any_opt [ "max-turns-per-attempt"; "max_turns_per_attempt" ] fields
      ; tolerates_bound_actor_fallback =
          bool_any_opt
            [ "tolerates-bound-actor-fallback"; "tolerates_bound_actor_fallback" ]
            fields
          |> Option.value ~default:false
      }
  in
  { id = provider_id
  ; labels
  ; telemetry_bucket
  ; telemetry_model_prefixes
  ; tool_policy
  }
;;

let parse_providers root_fields =
  match find_table_opt "providers" root_fields with
  | None -> []
  | Some providers ->
    providers
    |> List.filter_map (fun (provider_id, provider_value) ->
      Option.map (parse_provider_metadata provider_id) (table_opt provider_value))
;;

let parse_models root_fields =
  match find_table_opt "models" root_fields with
  | None -> []
  | Some models ->
    models
      |> List.filter_map (fun (model_id, model_value) ->
        Option.bind (table_opt model_value) (fun fields ->
          Some
            { model_id
            ; api_name =
                string_any_opt [ "api-name"; "api_name"; "model-name"; "model_name" ] fields
                |> Option.value ~default:model_id
            ; match_prefixes =
                string_list_any_opt [ "match-prefixes"; "match_prefixes" ] fields
                |> Option.value ~default:[]
            ; telemetry_bucket =
                string_any_opt [ "telemetry-bucket"; "telemetry_bucket" ] fields
            }))
;;

let parse_bindings root_fields (providers : provider_metadata list) (models : model_ref list) =
  let model_ids = List.map (fun (model : model_ref) -> model.model_id) models in
  providers
  |> List.concat_map (fun provider ->
    match find_table_opt provider.id root_fields with
    | None -> []
    | Some provider_bindings ->
      provider_bindings
      |> List.filter_map (fun (model_id, binding_value) ->
        match table_opt binding_value with
        | None -> None
        | Some _ when List.exists (String.equal model_id) model_ids ->
          Some { provider_id = provider.id; model_id }
        | Some _ -> None))
;;

let empty_snapshot path mtime =
  { path; mtime; providers = []; models = []; bindings = [] }
;;

let load_snapshot_uncached path =
  let mtime = file_mtime path in
  let root_fields = raw_toml_fields path in
  let providers = parse_providers root_fields in
  let models = parse_models root_fields in
  { path; mtime; providers; models; bindings = parse_bindings root_fields providers models }
;;

let snapshot_cache : snapshot option ref = ref None
let snapshot_mutex = Mutex.create ()

let load_snapshot () =
  match cascade_path_opt () with
  | None -> empty_snapshot "" 0.0
  | Some path ->
    let mtime = file_mtime path in
    (match !snapshot_cache with
     | Some snapshot
       when String.equal snapshot.path path && Float.equal snapshot.mtime mtime -> snapshot
     | _ ->
       Mutex.lock snapshot_mutex;
       Fun.protect
         ~finally:(fun () -> Mutex.unlock snapshot_mutex)
         (fun () ->
            match !snapshot_cache with
            | Some snapshot
              when String.equal snapshot.path path && Float.equal snapshot.mtime mtime ->
              snapshot
            | _ ->
              let snapshot = load_snapshot_uncached path in
              snapshot_cache := Some snapshot;
              snapshot))
;;

let reset_cache_for_test () = snapshot_cache := None

let provider_for_label snapshot label =
  let label = normalize_label label in
  snapshot.providers
  |> List.find_opt (fun provider ->
    List.exists (fun candidate -> String.equal (normalize_label candidate) label) provider.labels)
;;

let telemetry_bucket_of_provider_label label =
  let label = String.trim label in
  if String.equal label ""
  then None
  else (
    let snapshot = load_snapshot () in
    Option.bind (provider_for_label snapshot label) (fun provider ->
      provider.telemetry_bucket))
;;

let split_provider_label label =
  match String.index_opt label ':' with
  | None -> None
  | Some idx when idx = 0 || idx >= String.length label - 1 -> None
  | Some idx ->
    Some
      ( String.sub label 0 idx |> String.trim
      , String.sub label (idx + 1) (String.length label - idx - 1) |> String.trim )
;;

let choose_longest_prefix_bucket candidates value =
  candidates
  |> List.fold_left
       (fun acc (prefix, bucket) ->
          if not (starts_with_ci ~prefix value)
          then acc
          else (
            let len = String.length (String.trim prefix) in
            match acc with
            | None -> Some (len, bucket)
            | Some (best_len, _) when len > best_len -> Some (len, bucket)
            | Some _ -> acc))
       None
  |> Option.map snd
;;

let telemetry_bucket_of_model_raw snapshot model_id =
  let provider_prefixes =
    snapshot.providers
    |> List.concat_map (fun (provider : provider_metadata) ->
      match provider.telemetry_bucket with
      | None -> []
      | Some bucket ->
        List.map (fun prefix -> prefix, bucket) provider.telemetry_model_prefixes)
  in
  let model_prefixes =
    snapshot.models
    |> List.concat_map (fun model ->
      match model.telemetry_bucket with
      | None -> []
      | Some bucket ->
        (model.api_name, bucket)
        :: List.map (fun prefix -> prefix, bucket) model.match_prefixes)
  in
  choose_longest_prefix_bucket (model_prefixes @ provider_prefixes) model_id
;;

let telemetry_bucket_of_model_id model_id =
  let model_id = String.trim model_id in
  if String.equal model_id ""
  then None
  else (
    let snapshot = load_snapshot () in
    match split_provider_label model_id with
    | Some (provider, _model) ->
      (match telemetry_bucket_of_provider_label provider with
       | Some _ as bucket -> bucket
       | None -> telemetry_bucket_of_model_raw snapshot model_id)
    | None -> telemetry_bucket_of_model_raw snapshot model_id)
;;

let tool_policy_metadata_of_provider_label label =
  let label = String.trim label in
  if String.equal label ""
  then None
  else (
    let snapshot = load_snapshot () in
    Option.map
      (fun provider -> provider.tool_policy)
      (provider_for_label snapshot label))
;;

let model_matches_model_id (model : model_ref) model_id =
  String.equal model.model_id model_id
  || String.equal model.api_name model_id
  || List.exists (fun prefix -> starts_with_ci ~prefix model_id) model.match_prefixes
;;

let provider_ids_for_model snapshot model_id =
  let model_ids =
    snapshot.models
    |> List.filter_map (fun model ->
      if model_matches_model_id model model_id then Some model.model_id else None)
  in
  snapshot.bindings
  |> List.filter_map (fun binding ->
    if List.exists (String.equal binding.model_id) model_ids
    then Some binding.provider_id
    else None)
;;

let candidate_provider_ids snapshot (cfg : Llm_provider.Provider_config.t) =
  []
  |> add_unique (Llm_provider.Provider_registry.provider_name_of_config cfg)
  |> add_unique (Llm_provider.Provider_config.string_of_provider_kind cfg.kind)
  |> add_unique_all (provider_ids_for_model snapshot cfg.model_id)
;;

let provider_requires_argv_prompt_preflight cfg =
  let snapshot = load_snapshot () in
  candidate_provider_ids snapshot cfg
  |> List.exists (fun provider_id ->
    match provider_for_label snapshot provider_id with
    | Some provider -> provider.tool_policy.argv_prompt_preflight
    | None -> false)
;;
