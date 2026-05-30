(** Runtime_model_labels — execution model-label resolution for the default Runtime.

    RFC-0206 cascade→Runtime: replaces the deleted [Cascade_runtime]. The
    cascade-name -> multi-candidate catalog selection layer is annihilated.
    All execution resolution derives from the single default Runtime
    ([Runtime.get_default_runtime]) and the static provider registry:

    - no cascade_name parameter (default-always, runtime.mli §RFC-0206 2.1)
    - no discovered-context override (the local-discovery layer is removed)
    - no Cascade_metrics telemetry (counters were observability for the
      annihilated multi-candidate machinery)

    Label format stays ["provider:model"] so registry lookups keep working. *)

let default_registry = Llm_provider.Provider_registry.default ()

module Runtime_binding = Agent_sdk.Provider_runtime_binding

let provider_name_of_label (label : string) : string option =
  match String.index_opt label ':' with
  | None -> None
  | Some idx ->
    if idx = 0 then None
    else Some (String.sub label 0 idx |> String.trim |> String.lowercase_ascii)

let binding_is_local_runtime (binding : Runtime_binding.t) =
  match binding.Runtime_binding.transport with
  | Runtime_binding.Cli -> false
  | Runtime_binding.Http | Runtime_binding.Managed
  | Runtime_binding.Custom_provider_d_compat ->
    Runtime_provider_binding.binding_auth_is_no_auth binding
    && Runtime_provider_binding.binding_base_url_is_loopback binding

let local_runtime_provider_id () =
  Runtime_binding.all ()
  |> List.find_opt binding_is_local_runtime
  |> Option.map (fun binding -> binding.Runtime_binding.id)

let local_model_label model_id =
  match local_runtime_provider_id () with
  | Some provider_id -> provider_id ^ ":" ^ model_id
  | None -> "auto"

let is_typed_declarative_label_provider = function
  | "openai_compat" -> true
  | _ -> false

let has_execution_model_config () =
  match Provider_runtime_projection.preferred_execution_model_labels () with
  | _ :: _ -> true
  | [] -> false

(* default-always (RFC-0206 §2.1): no cascade_name selection. The configured
   execution labels are the single source; an empty projection surfaces the
   local fallback label so dashboards can alert on missing execution config. *)
let default_model_strings () =
  match Provider_runtime_projection.preferred_execution_model_labels () with
  | [] -> [ Provider_runtime_projection.default_local_fallback_label () ]
  | labels -> labels

(* models for the default runtime == the configured execution labels.
   (Collapse of the deleted [models_of_cascade_name]: no per-name catalog.) *)
let models () = default_model_strings ()

let models_result () : (string list, string) result = Ok (models ())

(* max output-token ceiling from the default Runtime's model spec (collapse of
   the deleted [max_output_tokens_ceiling_of_cascade_name], which read the
   annihilated cascade.toml declarative model capabilities). *)
let max_output_tokens_ceiling () : int option =
  let open Runtime_schema in
  match Runtime.get_default_runtime () with
  | None -> None
  | Some rt -> (
    match rt.Runtime.model.capabilities with
    | Some caps -> caps.max_output_tokens
    | None -> None)

let static_context_of_entry (entry : Llm_provider.Provider_registry.entry) : int =
  match entry.capabilities.Llm_provider.Capabilities.max_context_tokens with
  | Some caps_ctx when caps_ctx > entry.max_context -> caps_ctx
  | _ -> entry.max_context

let max_context_of_label (label : string) : int =
  match provider_name_of_label label with
  | None -> Runtime_constants.fallback_context_window
  | Some pname -> (
    match Llm_provider.Provider_registry.find default_registry pname with
    | Some entry -> static_context_of_entry entry
    | None -> Runtime_constants.fallback_context_window)

let context_of_registry_label ?(require_available = false)
    (registry : Llm_provider.Provider_registry.t) (label : string) : int option =
  match provider_name_of_label label with
  | None -> None
  | Some pname -> (
    match Llm_provider.Provider_registry.find registry pname with
    | None -> None
    | Some entry when require_available && not (entry.is_available ()) -> None
    | Some entry -> Some (static_context_of_entry entry))

let context_if_available (label : string) : int option =
  context_of_registry_label ~require_available:true default_registry label

let resolve_primary_max_context (labels : string list) : int =
  match
    List.find_map (context_of_registry_label ~require_available:true default_registry) labels
  with
  | Some ctx -> ctx
  | None -> Runtime_constants.fallback_context_window

let resolve_max_context (labels : string list) : int =
  match List.filter_map context_if_available labels with
  | [] -> Runtime_constants.fallback_context_window
  | ctxs -> List.fold_left max 0 ctxs

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
        if entry.is_available () then Some (label, model_id_of_label label) else None)
  in
  match Provider_runtime_projection.configured_default_model_label_result () with
  | Ok label -> (
    match try_label label with
    | Some pair -> pair
    | None -> (
      match
        List.find_map try_label
          (Provider_runtime_projection.preferred_execution_model_labels ())
      with
      | Some pair -> pair
      | None -> fallback))
  | Error _ -> (
    match
      List.find_map try_label
        (Provider_runtime_projection.preferred_execution_model_labels ())
    with
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
            if is_typed_declarative_label_provider pname then true
            else (
              match Llm_provider.Provider_registry.find default_registry pname with
              | None -> false
              | Some entry -> entry.is_available ()))
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
              if is_typed_declarative_label_provider pname then None
              else (
                match Llm_provider.Provider_registry.find default_registry pname with
                | None -> Some (Printf.sprintf "%s (unknown provider)" pname)
                | Some entry ->
                  if entry.defaults.api_key_env = "" then None
                  else if entry.is_available () then None
                  else Some entry.defaults.api_key_env))
          labels
      in
      Error
        (Printf.sprintf "No valid/available model specs for labels: %s (missing: %s)"
           (String.concat ", " labels)
           (String.concat ", " missing))

(* Collapse of [resolve_named_providers_result_strict]: a single default
   Runtime is THE provider (RFC-0206). The deleted catalog resolution
   (cascade_name -> provider list) is annihilated; the tool-use gate still
   runs, fail-closed (an empty result downstream becomes a dispatch error). *)
let resolve_execution_providers_strict ?provider_filter:_
    ?(require_tool_choice_support = false) ?(require_tool_support = false)
    ?runtime_mcp_policy () : (Llm_provider.Provider_config.t list, string) result =
  match Runtime.get_default_runtime () with
  | None -> Error "no default runtime configured"
  | Some rt ->
    let providers = [ rt.Runtime.provider_config ] in
    Ok
      (Provider_tool_support.apply_required_tool_use_filter ?runtime_mcp_policy
         ~require_tool_choice_support ~require_tool_support ~label:rt.Runtime.id
         providers)
