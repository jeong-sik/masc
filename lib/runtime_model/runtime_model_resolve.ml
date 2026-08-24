(** Model ID resolution for runtime provider labels.

    Pure functions that map user-facing [auto] selectors through the AGENT_CORE
    provider runtime binding projection. Provider-specific alias/catalog truth
    belongs upstream in AGENT_CORE, not in MASC runtime code.
    No side effects beyond reading environment variables.

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

let env_value_opt ?(getenv = Sys.getenv_opt) var =
  match getenv var with
  | Some v ->
    let trimmed = String.trim v in
    if String.equal trimmed "" then None else Some trimmed
  | None -> None
;;

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
  | Some _ ->
    (match selector with
     | Auto -> default_resolution ?getenv provider_name ~requested_model_id:model_id
     | Concrete _ -> explicit_resolution model_id (String.trim model_id))
  | None ->
    (match selector with
     | Auto -> unresolved_auto model_id
     | Concrete _ -> explicit_resolution model_id (String.trim model_id))
;;

let parse_custom_model model_id =
  match String.index_opt model_id '@' with
  | Some at_idx ->
    let model = String.sub model_id 0 at_idx in
    let url = String.sub model_id (at_idx + 1) (String.length model_id - at_idx - 1) in
    model, url
  | None ->
    let url =
      match env_value_opt "CUSTOM_LLM_BASE_URL" with
      | Some u -> u
      | None -> Llm_provider.Discovery.default_endpoint
    in
    model_id, url
;;
