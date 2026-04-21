(** MASC-owned cascade runtime resolution helpers.

    Named cascade fallback defaults, cascade-name -> label resolution,
    label -> provider config conversion, and label context lookup all live
    here so MASC keeps ownership of cascade behavior and OAS remains a
    consumer of resolved runtime inputs. *)

let fallback_context_window = 128_000

let default_registry = Llm_provider.Provider_registry.default ()

let provider_name_of_label (label : string) : string option =
  match String.index_opt label ':' with
  | None -> None
  | Some idx ->
      if idx = 0 then None
      else Some (String.sub label 0 idx |> String.trim |> String.lowercase_ascii)

let is_local_only_cascade name =
  let lc = name |> Keeper_cascade_profile.canonicalize |> String.lowercase_ascii in
  let pattern = "local" in
  let plen = String.length pattern in
  let slen = String.length lc in
  let rec loop i =
    if i > slen - plen then false
    else if String.sub lc i plen = pattern then true
    else loop (i + 1)
  in
  loop 0

let is_local_label label =
  match provider_name_of_label label with
  | Some pname -> Provider_adapter.is_local_provider pname
  | None -> false

let default_model_strings ~cascade_name =
  let cascade_name = Keeper_cascade_profile.canonicalize cascade_name in
  let all_labels =
    match Provider_adapter.explicit_llama_model_label_result () with
    | Ok label -> [ label ]
    | Error _ -> (
        match Provider_adapter.preferred_execution_model_labels () with
        | [] -> [ Provider_adapter.default_local_fallback_label () ]
        | labels -> labels)
  in
  if is_local_only_cascade cascade_name then
    match List.filter is_local_label all_labels with
    | [] -> [ Provider_adapter.default_local_fallback_label () ]
    | local -> local
  else
    all_labels

let labels_require_local_discovery (labels : string list) : bool =
  List.exists
    (fun label ->
      match provider_name_of_label label with
      | Some pname -> Provider_adapter.requires_discovery pname
      | None -> false)
    labels

let refresh_local_discovery_if_possible ?sw ?net (labels : string list) : bool =
  if not (labels_require_local_discovery labels) then false
  else
    let sw =
      match sw with Some value -> Some value | None -> Eio_context.get_switch_opt ()
    in
    let net =
      match net with Some value -> Some value | None -> Eio_context.get_net_opt ()
    in
    match sw, net with
    | Some sw, Some net ->
        let before = Llm_provider.Provider_registry.discovered_max_context () in
        (try
           ignore
             (Llm_provider.Provider_registry.refresh_llama_endpoints ~sw ~net ());
           let after = Llm_provider.Provider_registry.discovered_max_context () in
           (match before, after with
            | Some prev, Some next when prev <> next ->
                Log.info ~ctx:"CascadeRuntime"
                  "refreshed local runtime context: %d -> %d" prev next
            | None, Some next ->
                Log.info ~ctx:"CascadeRuntime"
                  "refreshed local runtime context: unset -> %d" next
            | _ -> ());
           true
         with
         | Eio.Cancel.Cancelled _ as exn -> raise exn
         | exn ->
             Log.warn ~ctx:"CascadeRuntime"
               "local runtime discovery refresh failed: %s"
               (Printexc.to_string exn);
             false)
    | _ -> false

let context_floor = 4_096

let effective_discovered_ctx ~static_ctx ~(discovered : int option) : int =
  match discovered with
  | Some ctx when ctx >= context_floor -> ctx
  | _ -> static_ctx

let static_context_of_entry
    (entry : Llm_provider.Provider_registry.entry) : int =
  match entry.capabilities.Llm_provider.Capabilities.max_context_tokens with
  | Some caps_ctx when caps_ctx > entry.max_context -> caps_ctx
  | _ -> entry.max_context

let max_context_of_label (label : string) : int =
  let static_ctx =
    match provider_name_of_label label with
    | None -> fallback_context_window
    | Some pname -> (
        match Llm_provider.Provider_registry.find default_registry pname with
        | Some entry -> static_context_of_entry entry
        | None -> fallback_context_window)
  in
  match Cascade_config.resolve_label_context label with
  | Some ctx -> effective_discovered_ctx ~static_ctx ~discovered:(Some ctx)
  | None -> static_ctx

let context_if_available (label : string) : int option =
  match provider_name_of_label label with
  | None -> None
  | Some pname -> (
      match Llm_provider.Provider_registry.find default_registry pname with
      | None -> None
      | Some entry ->
          if entry.is_available () then
            let static_ctx = static_context_of_entry entry in
            let ctx =
              match Cascade_config.resolve_label_context label with
              | Some discovered ->
                  effective_discovered_ctx ~static_ctx ~discovered:(Some discovered)
              | None -> static_ctx
            in
            Some ctx
          else
            None)

let resolve_primary_max_context (labels : string list) : int =
  match List.find_map context_if_available labels with
  | Some ctx -> ctx
  | None -> fallback_context_window

let resolve_max_cascade_context (labels : string list) : int =
  match List.filter_map context_if_available labels with
  | [] -> fallback_context_window
  | ctxs -> List.fold_left max 0 ctxs

let labels_are_pure_local (labels : string list) : bool =
  labels <> []
  &&
  List.for_all
    (fun label ->
      match provider_name_of_label label with
      | Some pname -> Provider_adapter.is_local_provider pname
      | None -> false)
    labels

let clamp_context_for_pure_local_labels ~(labels : string list) ~(max_context : int)
    : int =
  if labels_are_pure_local labels
  then min max_context Env_config.ContextCompact.small_local_floor
  else max_context

let model_id_of_label label =
  match String.index_opt label ':' with
  | None -> ""
  | Some idx ->
      if idx >= String.length label - 1 then ""
      else String.sub label (idx + 1) (String.length label - idx - 1) |> String.trim

let resolve_primary_model_id (labels : string list) : string =
  let rec find = function
    | [] -> ""
    | label :: rest -> (
        match provider_name_of_label label with
        | None -> find rest
        | Some pname -> (
            match Llm_provider.Provider_registry.find default_registry pname with
            | None -> find rest
            | Some entry ->
                if entry.is_available () then model_id_of_label label else find rest))
  in
  find labels

let default_local_model_label_and_id () : string * string =
  let fallback = ("auto", "auto") in
  let try_label label =
    match provider_name_of_label label with
    | None -> None
    | Some pname -> (
        match Llm_provider.Provider_registry.find default_registry pname with
        | None -> None
        | Some entry ->
            if entry.is_available () then Some (label, model_id_of_label label)
            else None)
  in
  match Provider_adapter.configured_default_model_label_result () with
  | Ok label -> (
      match try_label label with
      | Some pair -> pair
      | None -> (
          match List.find_map try_label (Provider_adapter.preferred_execution_model_labels ()) with
          | Some pair -> pair
          | None -> fallback))
  | Error _ -> (
      match List.find_map try_label (Provider_adapter.preferred_execution_model_labels ()) with
      | Some pair -> pair
      | None -> fallback)

let ensure_api_keys_for_labels (labels : string list) : (unit, string) result =
  if labels = [] then Ok ()
  else
    let any_available =
      List.exists
        (fun label ->
          match provider_name_of_label label with
          | None -> true
          | Some pname ->
              if Provider_adapter.is_local_provider pname then true
              else
                match Llm_provider.Provider_registry.find default_registry pname with
                | None -> false
                | Some entry -> entry.is_available ())
        labels
    in
    if any_available then Ok ()
    else
      let missing =
        List.filter_map
          (fun label ->
            match provider_name_of_label label with
            | None -> None
            | Some pname ->
                if Provider_adapter.is_local_provider pname then None
                else
                  match Llm_provider.Provider_registry.find default_registry pname with
                  | None -> Some (Printf.sprintf "%s (unknown provider)" pname)
                  | Some entry ->
                      if entry.defaults.api_key_env = "" then None
                      else if entry.is_available () then None
                      else Some entry.defaults.api_key_env)
          labels
      in
      Error
        (Printf.sprintf "No valid/available model specs for labels: %s (missing: %s)"
           (String.concat ", " labels)
           (String.concat ", " missing))

let provider_capabilities_of_config (cfg : Llm_provider.Provider_config.t) =
  let registry = Llm_provider.Provider_registry.default () in
  let provider_name = Provider_adapter.string_of_provider_kind cfg.kind in
  let caps =
    match Llm_provider.Provider_registry.find registry provider_name with
    | Some entry -> entry.capabilities
    | None -> Llm_provider.Capabilities.default_capabilities
  in
  match cfg.supports_tool_choice_override with
  | Some supports_tool_choice -> { caps with supports_tool_choice }
  | None -> caps

let apply_required_tool_choice_filter ~require_tool_choice_support ~label
    (providers : Llm_provider.Provider_config.t list) =
  if not require_tool_choice_support then
    providers
  else
    let supports_required_tool_use cfg =
      let caps = provider_capabilities_of_config cfg in
      caps.supports_tools && caps.supports_tool_choice
    in
    let filtered = List.filter supports_required_tool_use providers in
    if filtered = [] && providers <> [] then
      Log.Misc.warn
        "cascade %s: required tool-use gate removed all providers (providers=[%s])"
        label
        (String.concat ", "
           (List.map
              (fun (cfg : Llm_provider.Provider_config.t) ->
                Printf.sprintf "%s:%s"
                  (Llm_provider.Provider_config.string_of_provider_kind cfg.kind)
                  cfg.model_id)
              providers));
    filtered

let cascade_config_path () : string option =
  Config_dir_resolver.log_warnings ~context:"CascadeRuntime" ();
  Config_dir_resolver.cascade_path_opt ()

let models_of_cascade_name (cascade_name : string) : string list =
  let cascade_name = Keeper_cascade_profile.canonicalize cascade_name in
  let defaults = default_model_strings ~cascade_name in
  let config_path = cascade_config_path () in
  try
    Cascade_config.resolve_model_strings ?config_path ~name:cascade_name ~defaults ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      Log.warn ~ctx:"CascadeRuntime"
        "cascade config resolve failed for %s, using defaults: %s"
        cascade_name (Printexc.to_string exn);
      defaults

let resolve_providers_from_model_strings ?provider_filter
    ?(require_tool_choice_support = false)
    (model_strings : string list)
    : Llm_provider.Provider_config.t list =
  let specs = Cascade_config.parse_model_strings model_strings in
  let filtered =
    Cascade_config.apply_provider_filter
      ~provider_filter
      ~label:"direct_model_strings"
      specs
    |> apply_required_tool_choice_filter ~require_tool_choice_support
         ~label:"direct_model_strings"
  in
  if filtered <> [] then filtered
  else (
    Log.Misc.warn "direct model strings: no callable models from %d entries"
      (List.length model_strings);
    [])

let resolve_named_providers ?provider_filter
    ?(require_tool_choice_support = false) ~cascade_name ()
    : Llm_provider.Provider_config.t list =
  let cascade_name = Keeper_cascade_profile.canonicalize cascade_name in
  let defaults = default_model_strings ~cascade_name in
  let config_path = cascade_config_path () in
  let weighted =
    match config_path with
    | Some path ->
      Cascade_config_loader.load_profile_weighted ~config_path:path
        ~name:cascade_name
    | None -> []
  in
  let specs =
    (if weighted <> [] then
       Cascade_config.parse_weighted_entries ~cascade_name weighted
     else
       Cascade_config.parse_model_strings
         (models_of_cascade_name cascade_name))
    |> Cascade_config.apply_provider_filter ~provider_filter ~label:cascade_name
    |> apply_required_tool_choice_filter ~require_tool_choice_support
         ~label:cascade_name
  in
  if specs <> [] then specs
  else if models_of_cascade_name cascade_name = defaults then (
    Log.Misc.warn "cascade %s: no callable models from built-in defaults"
      cascade_name;
    [])
  else (
    Log.Misc.warn
      "cascade %s: configured models unavailable — retrying built-in defaults"
      cascade_name;
    resolve_providers_from_model_strings ?provider_filter
      ~require_tool_choice_support defaults)
