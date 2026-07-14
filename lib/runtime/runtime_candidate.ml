(** Runtime_candidate — single-dispatch execution candidate (RFC-0206).

    Runtime dispatch
    wrapped a [Provider_config.t] with health / capacity / probe keys to feed
    the multi-candidate selection FSM. With single-binding dispatch there is
    exactly one Runtime, so the candidate collapses to its provider config and
    the health/capacity/strategy/selection machinery is dropped.

    [type t] is a record pairing the runtime's [Provider_config.t] with an
    optional operator-declared [max_concurrent] override. [None] is the normal
    no-static-cap path. The surviving members delegate to
    {!Runtime_agent} / {!Runtime_provider_binding}; error decoration is
    collapsed to identity. *)

type t =
  { config : Llm_provider.Provider_config.t
  ; max_concurrent : int option
  }

module Runtime_binding = Agent_sdk.Provider_runtime_binding

let of_provider_config ~(max_concurrent : int option) (cfg : Llm_provider.Provider_config.t) : t =
  { config = cfg; max_concurrent }

let of_provider_configs (cfgs : (Llm_provider.Provider_config.t * int option) list) : t list =
  List.map (fun (cfg, max_concurrent) -> { config = cfg; max_concurrent }) cfgs

let provider_cfg (t : t) : Llm_provider.Provider_config.t = t.config
let max_concurrent (t : t) : int option = t.max_concurrent

let provider_label (t : t) =
  Runtime_provider_binding.provider_label_of_config t.config

(* Provider-scoped health key retained for provider_attempt's single-provider
   health recording. No multi-candidate selection consumes these. *)
let health_key (t : t) = Runtime_provider_binding.provider_health_key_of_config t.config
let model_health_key (t : t) = Runtime_provider_binding.provider_health_key_of_config t.config
let health_keys (t : t) = [ Runtime_provider_binding.provider_health_key_of_config t.config ]

let default_config ~name ~system_prompt ~tools (t : t) =
  Runtime_agent.default_config ~name ~provider_cfg:t.config ~system_prompt ~tools

(* Runtime-label helpers for dashboard grouping. Delegates to the canonical
   local-runtime detector in Runtime_provider_binding (loopback + no-auth). *)
let local_runtime_provider_id () =
  Runtime_provider_binding.default_local_openai_runtime_provider_id ()

let local_runtime_label runtime_id =
  match local_runtime_provider_id () with
  | Some provider_id -> provider_id ^ ":" ^ runtime_id
  | None -> runtime_id

let default_local_runtime_label () =
  match local_runtime_provider_id () with
  | Some provider_id -> provider_id ^ ":auto"
  | None -> "auto"

(* Label -> provider-config / health-key resolution for surviving observability
   (provider cooldown, context budget). Verbatim from the deleted module;
   depends only on the registry + Provider_kind_resolver. *)
let registry_default_base_url provider_name =
  let registry = Llm_provider.Provider_registry.default () in
  match Llm_provider.Provider_registry.find registry provider_name with
  | Some entry -> entry.defaults.base_url
  | None -> ""

let provider_config_of_runtime_label label =
  let cfg_of_kind ~kind ~model_id ~base_url =
    Llm_provider.Provider_config.make ~kind ~model_id ~base_url ()
  in
  match Provider_kind_resolver.resolve label with
  | Provider_kind_resolver.Registered { provider_name; model_id; kind } ->
    let base_url = registry_default_base_url provider_name in
    Some (cfg_of_kind ~kind ~model_id ~base_url)
  | Provider_kind_resolver.Custom_url { model_id; base_url } ->
    Some
      (cfg_of_kind ~kind:Llm_provider.Provider_config.OpenAI_compat ~model_id
         ~base_url)
  | Provider_kind_resolver.Unknown _ -> None

let runtime_health_key_of_label label =
  provider_config_of_runtime_label label
  |> Option.map Runtime_provider_binding.provider_health_key_of_config

let runtime_health_keys_of_labels labels =
  labels
  |> List.filter_map runtime_health_key_of_label
  |> List.sort_uniq String.compare

type context_window_hint =
  { context_window : int
  ; is_local_model : bool
  }

type attempt_timeout_resolution =
  { timeout_s : float option
  ; source : string
  }

(* Collapsed: the deleted version was already a no-op stub (tier-based local
   classification removed); context window comes from the Runtime model spec. *)
let context_window_hint_of_labels labels =
  let _ = labels in
  { context_window = 0; is_local_model = false }

let runtime_id_of_label label =
  match Provider_kind_resolver.resolve label with
  | Provider_kind_resolver.Registered { model_id; _ }
  | Provider_kind_resolver.Custom_url { model_id; _ } ->
    let runtime_id = String.trim model_id in
    if String.equal runtime_id "" then None else Some runtime_id
  | Provider_kind_resolver.Unknown _ -> None

let runtime_id_of_label_or_raw label =
  match runtime_id_of_label label with
  | Some runtime_id -> runtime_id
  | None -> String.trim label

let strip_latest_suffix runtime_id =
  let suffix = ":latest" in
  let suffix_len = String.length suffix in
  let len = String.length runtime_id in
  if len > suffix_len
     && String.equal (String.sub runtime_id (len - suffix_len) suffix_len) suffix
  then String.sub runtime_id 0 (len - suffix_len)
  else runtime_id

let normalize_runtime_name_for_bucket label =
  runtime_id_of_label_or_raw label |> strip_latest_suffix

let nonempty_string_opt s =
  let s = String.trim s in
  if String.equal s "" then None else Some s

let runtime_url_of_label label =
  match Provider_kind_resolver.resolve label with
  | Provider_kind_resolver.Registered { provider_name; _ } ->
    nonempty_string_opt (registry_default_base_url provider_name)
  | Provider_kind_resolver.Custom_url { base_url; _ } ->
    nonempty_string_opt base_url
  | Provider_kind_resolver.Unknown _ -> None

let label_matches_runtime_id ~label ~runtime_id =
  let label_id = normalize_runtime_name_for_bucket label in
  let runtime_id = String.trim runtime_id |> strip_latest_suffix in
  (not (String.equal runtime_id "")) && String.equal label_id runtime_id

let has_resolvable_runtime_label labels =
  List.exists (fun label -> Option.is_some (runtime_id_of_label label)) labels

let labels_require_runtime_mcp_header_sync labels =
  let _ = labels in
  false

let unknown_runtime_label = "unknown"

let provider_label_of_runtime_label ?provider_kind label =
  let _ = provider_kind in
  match nonempty_string_opt label with
  | Some label -> label
  | None -> unknown_runtime_label

let is_structurally_unmetered_runtime_provider label =
  let _ = label in
  false

let runtime_label_for_active_id ~configured_labels ~active =
  let active = String.trim active in
  match
    List.find_opt
      (fun label -> label_matches_runtime_id ~label ~runtime_id:active)
      configured_labels
  with
  | Some label -> label
  | None ->
    if String.equal active "" then unknown_runtime_label else active

let resolve_reported_runtime_id ~labels ~reported_runtime_id =
  runtime_label_for_active_id ~configured_labels:labels ~active:reported_runtime_id
  |> normalize_runtime_name_for_bucket

let threshold_multipliers_of_runtime_id runtime_id =
  let _ = runtime_id in
  (1.0, 1.0)

let first_health_cooldown (_ : t) = None
let has_recovery_evidence (_ : t) = false

let effective_attempt_timeout_resolution ~is_last ~configured_timeout_s (_ : t) =
  let _ = is_last in
  match configured_timeout_s with
  | Some timeout_s -> { timeout_s = Some timeout_s; source = "configured" }
  | None -> { timeout_s = None; source = "runtime_default" }

let effective_attempt_timeout_s ~is_last ~configured_timeout_s t =
  (effective_attempt_timeout_resolution ~is_last ~configured_timeout_s t).timeout_s

let capacity_key (t : t) = health_key t

let capacity_keys candidates =
  candidates |> List.map capacity_key |> List.sort_uniq String.compare

let declared_client_capacity (_ : t) = None
let register_declared_client_capacity (_ : t) = ()

let runtime_urls candidates =
  candidates
  |> List.filter_map (fun (t : t) -> nonempty_string_opt t.config.base_url)
  |> List.sort_uniq String.compare

let local_runtime_urls candidates = runtime_urls candidates

let filter_unhealthy_local_runtime_urls ~endpoint_health candidates =
  let _ = endpoint_health in
  (candidates, [])

let http_probe_urls candidates = runtime_urls candidates

let register_http_probe_capable ~max_concurrent (_ : t) =
  let _ = max_concurrent in
  ()
