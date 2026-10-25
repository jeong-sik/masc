(** Model ID resolution for runtime provider labels.

    Pure functions that map user-facing [auto] selectors through the AGENT_CORE
    provider runtime binding projection. Provider-specific alias/catalog truth
    belongs upstream in AGENT_CORE, not in MASC runtime code.
    Custom URL selection is explicit; only auto-model resolution consults
    the runtime binding's declared defaults/discovery.

    @since 0.92.0 extracted from Runtime_config *)

type model_selector =
  | Concrete of string
  | Auto

let model_selector_of_string s =
  if String.equal (String.lowercase_ascii (String.trim s)) "auto"
  then Auto
  else Concrete s
;;

type model_resolution_provenance =
  | Explicit_input
  | Env_default of string
  | Binding_default
  | Discovery
  | Unresolved_auto

type model_resolution =
  { requested_model_id : string
  ; resolved_model_id : string
  ; provenance : model_resolution_provenance
  }

let explicit_resolution requested_model_id resolved_model_id =
  { requested_model_id; resolved_model_id; provenance = Explicit_input }
;;

let unresolved_auto requested_model_id =
  { requested_model_id
  ; resolved_model_id = requested_model_id
  ; provenance = Unresolved_auto
  }
;;

let binding_default requested_model_id resolved_model_id =
  { requested_model_id; resolved_model_id; provenance = Binding_default }
;;

let default_resolution ?getenv provider_name ~requested_model_id =
  match
    Provider_runtime_projection.default_model_candidate_for_runtime_prefix
      ?getenv
      provider_name
  with
  | Some
      { source = Provider_runtime_projection.Env_var env_var
      ; model_id = resolved_model_id
      } ->
    { requested_model_id; resolved_model_id; provenance = Env_default env_var }
  | Some
      { source = Provider_runtime_projection.Binding_default
      ; model_id = resolved_model_id
      } ->
    binding_default requested_model_id resolved_model_id
  | None -> unresolved_auto requested_model_id
;;

(** Resolve "auto" and aliases to concrete model IDs.
    Cloud APIs generally require concrete model names, and local
    providers (llama, ollama) also cannot accept the literal "auto" model ID.

    For local providers, "auto" is resolved via {!Llm_provider.Discovery.first_discovered_model_id}
    which returns models from the last endpoint probe. Callers should
    resolve the model_id before invoking [Llm_provider.Discovery.endpoint_for_model]
    to avoid routing mismatches. *)
let resolve_auto_model
      ?getenv
      ?(discover = Llm_provider.Discovery.first_discovered_model_id)
      provider_name
      selector
  =
  let model_id =
    match selector with
    | Concrete s -> s
    | Auto -> "auto"
  in
  match Provider_runtime_projection.provider_profile_for_runtime_prefix provider_name with
  | Some { runtime_kind = Provider_runtime_projection.Local; _ } ->
    (match selector with
     | Auto ->
       (match discover () with
        | Some resolved_model_id ->
          { requested_model_id = model_id; resolved_model_id; provenance = Discovery }
        | None -> default_resolution ?getenv provider_name ~requested_model_id:model_id)
     | Concrete _ -> explicit_resolution model_id (String.trim model_id))
  | Some { runtime_kind = Provider_runtime_projection.Direct_api; _ } ->
    (match selector with
     | Auto -> default_resolution ?getenv provider_name ~requested_model_id:model_id
     | Concrete _ -> explicit_resolution model_id (String.trim model_id))
  | None ->
    (match selector with
     | Auto -> unresolved_auto model_id
     | Concrete _ -> explicit_resolution model_id (String.trim model_id))
;;

type custom_model_error =
  | Missing_endpoint
  | Empty_model
  | Invalid_endpoint

let custom_model_error_to_string = function
  | Missing_endpoint -> "custom model requires an explicit model@url selection"
  | Empty_model -> "custom model selection has an empty model id"
  | Invalid_endpoint -> "custom model requires an absolute HTTP(S) endpoint"
;;

let parse_custom_model selection =
  match String.index_opt selection '@' with
  | None -> Error Missing_endpoint
  | Some at_idx ->
    let model = String.sub selection 0 at_idx |> String.trim in
    let url = String.sub selection (at_idx + 1) (String.length selection - at_idx - 1)
      |> String.trim in
    if model = "" then Error Empty_model
    else
      match Uri.of_string url with
      | uri ->
        (match Uri.scheme uri, Uri.host uri with
         | Some ("http" | "https"), Some host when host <> "" -> Ok (model, url)
         | _ -> Error Invalid_endpoint)
      | exception Invalid_argument _ -> Error Invalid_endpoint
;;
