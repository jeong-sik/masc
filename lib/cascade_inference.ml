(** Per-cascade inference parameters — thin delegation to MASC Cascade_config.

    Previously (v2.128.0-v2.148.0) this module maintained its own JSON cache
    and field extraction. Since OAS v0.89.1 exposes
    [Cascade_config.load_catalog_source] (renamed from [load_json] in
    RFC-0058 §9 Phase 9.3) and [Cascade_config.resolve_inference_params],
    we now delegate entirely.

    Public API preserved for backward compatibility:
    - [resolve_temperature], [resolve_max_tokens] (16 call sites in MASC)
    - [for_cascade], [for_json] (used in tests)

    @since v2.128.0
    @since v2.149.0 — delegated to MASC Cascade_config *)

(** Inference parameters resolved from cascade config. *)
type t = {
  temperature : float option;
  max_tokens : int option;
  thinking_enabled : bool option;
  thinking_budget : int option;
}

let empty = { temperature = None; max_tokens = None;
              thinking_enabled = None; thinking_budget = None }

(** Convert OAS inference_params to MASC t. *)
let of_oas (p : Cascade_config.inference_params) : t =
  { temperature = p.temperature; max_tokens = p.max_tokens;
    thinking_enabled = p.thinking_enabled; thinking_budget = p.thinking_budget }

(** Extract inference parameters from a parsed JSON value for a named cascade.
    Exposed for testing without filesystem dependency. *)
let for_json ~(name : string) (json : Yojson.Safe.t) : t =
  let name = Keeper_cascade_profile.canonicalize name in
  let read_float key =
    match Yojson.Safe.Util.member key json with
    | `Float f -> Some f | `Int i -> Some (float_of_int i) | _ -> None
  in
  let read_int key =
    match Yojson.Safe.Util.member key json with
    | `Int i -> Some i | `Float f -> Some (int_of_float f) | _ -> None
  in
  let temperature =
    match read_float (Keeper_cascade_profile.temperature_key name) with
    | Some _ as v -> v
    | None -> read_float "default_temperature"
  in
  let max_tokens =
    match read_int (Keeper_cascade_profile.max_tokens_key name) with
    | Some _ as v -> v
    | None -> read_int "default_max_tokens"
  in
  { temperature; max_tokens; thinking_enabled = None; thinking_budget = None }

(** Load inference parameters for a named cascade profile.
    Delegates to MASC [Cascade_config.resolve_inference_params].
    Returns [empty] on any error (malformed config, read failure). *)
let for_cascade ~(name : string) : t =
  let name = Keeper_cascade_profile.normalize_declared_name name in
  match Cascade_catalog_runtime.resolve_inference_params ~name () with
  | Ok params ->
      { temperature = params.temperature; max_tokens = params.max_tokens;
        thinking_enabled = params.thinking_enabled;
        thinking_budget = params.thinking_budget }
  | Error detail ->
      (* Fail-OPEN to default: cascade.toml per-cascade inference
         params (temperature, max_tokens, thinking_enabled,
         thinking_budget) are silently replaced with the [empty]
         record, and downstream callers resolve to their own
         fallbacks.  Reuse iter 10 resolve_failure counter; root
         cause is the same [lookup_active_profile] Error path that
         iter 10 already labels [lookup_failed].  Without the tick,
         operators saw only the WARN log line and had no way to
         alert on cascade.toml inference settings being silently
         ignored. *)
      Cascade_metrics.on_resolve_failure
        ~cascade:name ~reason:"lookup_failed";
      Log.warn ~ctx:"cascade"
        "%s: runtime catalog inference lookup failed (%s), using empty defaults"
        name detail;
      empty

(** Resolve a temperature value: cascade config -> fallback. *)
let resolve_temperature
    ~(cascade_name : Keeper_cascade_profile.runtime_name)
    ~(fallback : unit -> float) : float =
  let cascade_name = Keeper_cascade_profile.runtime_name_to_string cascade_name in
  match (for_cascade ~name:cascade_name).temperature with
  | Some t -> t
  | None -> fallback ()

let auto_max_tokens_clamp_seen : (string, unit) Hashtbl.t = Hashtbl.create 16
let auto_max_tokens_clamp_seen_mutex = Mutex.create ()

let auto_max_tokens_clamp_key ~cascade_name ~source ~max_tokens ~ceiling =
  Printf.sprintf
    "%s\x1f%s\x1f%d\x1f%d"
    (Keeper_cascade_profile.runtime_name_to_string cascade_name)
    source
    max_tokens
    ceiling

let mark_auto_max_tokens_clamp_seen key =
  Mutex.protect auto_max_tokens_clamp_seen_mutex (fun () ->
    if Hashtbl.mem auto_max_tokens_clamp_seen key
    then false
    else (
      Hashtbl.replace auto_max_tokens_clamp_seen key ();
      true))

let should_log_auto_max_tokens_clamp ~cascade_name ~source ~max_tokens ~ceiling =
  auto_max_tokens_clamp_key ~cascade_name ~source ~max_tokens ~ceiling
  |> mark_auto_max_tokens_clamp_seen

(** Cap a max_tokens value to the resolved cascade's narrowest output
    ceiling. Cascade-config, fallback, and internal keeper override budgets
    all flow through this helper. A deduplicated WARN per
    (cascade, source, requested, ceiling) tuple preserves operator
    visibility into the silent reduction.

    The narrowest ceiling is a property of cascade-internal fallback
    structure (multilane tier-groups can union members of differing output
    budgets), so callers cannot infer it.

    Runtime overrides supplied by internal keeper callers should also flow
    through this helper before the final pre-dispatch validator. The validator
    remains as a hard guard for non-positive budgets and invalid ceilings. *)
let cap_max_tokens_to_ceiling ~cascade_name ~source ~ceiling max_tokens =
  if ceiling > 0 && max_tokens > ceiling
  then (
    Cascade_metrics.on_max_tokens_clamped ();
    if should_log_auto_max_tokens_clamp ~cascade_name ~source ~max_tokens ~ceiling
    then
      Log.warn ~ctx:"cascade"
        "%s: resolved max_tokens=%d from %s exceeds output ceiling=%d; \
         using ceiling; suppressing repeats for this tuple"
        (Keeper_cascade_profile.runtime_name_to_string cascade_name)
        max_tokens source ceiling;
    ceiling)
  else max_tokens

let cap_max_tokens_to_cascade_ceiling ~cascade_name ~source max_tokens =
  match Cascade_runtime.max_output_tokens_ceiling_of_cascade_name cascade_name with
  | Some ceiling ->
    cap_max_tokens_to_ceiling ~cascade_name ~source ~ceiling max_tokens
  | _ -> max_tokens

(** Resolve a max_tokens value: cascade config (capped) -> capped fallback. *)
let resolve_max_tokens
    ~(cascade_name : Keeper_cascade_profile.runtime_name)
    ~(fallback : unit -> int) : int =
  let cascade_name_string =
    Keeper_cascade_profile.runtime_name_to_string cascade_name
  in
  match (for_cascade ~name:cascade_name_string).max_tokens with
  | Some t ->
    cap_max_tokens_to_cascade_ceiling ~cascade_name ~source:"cascade_config" t
  | None ->
    cap_max_tokens_to_cascade_ceiling ~cascade_name ~source:"fallback" (fallback ())

(** Validate and clamp max_tokens against provider ceilings before dispatch. *)
let validate_max_tokens_within_ceiling
    ~(cascade_name : Keeper_cascade_profile.runtime_name)
    ~(provider_ceiling : int option)
    (max_tokens : int)
  : (int, Cascade_error_classify.masc_internal_error) result =
  let violation ~reason ~provider_ceiling =
    Error
      (Cascade_error_classify.Max_tokens_ceiling_violation
         {
           cascade_name;
           requested_max_tokens = max_tokens;
           provider_ceiling;
           reason;
         })
  in
  match provider_ceiling with
  | None ->
    if max_tokens <= 0
    then violation ~reason:"max_tokens_not_positive" ~provider_ceiling:0
    else Ok max_tokens
  | Some ceiling ->
    if max_tokens <= 0
    then violation ~reason:"max_tokens_not_positive" ~provider_ceiling:ceiling
    else if ceiling <= 0
    then violation ~reason:"provider_ceiling_not_positive" ~provider_ceiling:ceiling
    else if max_tokens > ceiling
    then
      Ok
        (cap_max_tokens_to_ceiling
           ~cascade_name
           ~source:"pre_dispatch"
           ~ceiling
           max_tokens)
    else Ok max_tokens

module For_testing = struct
  let reset_auto_max_tokens_clamp_warnings () =
    Mutex.protect auto_max_tokens_clamp_seen_mutex (fun () ->
      Hashtbl.clear auto_max_tokens_clamp_seen)

  let should_log_auto_max_tokens_clamp =
    should_log_auto_max_tokens_clamp

  let clamp_with_ceiling ~cascade_name ~source ~ceiling max_tokens =
    match ceiling with
    | Some c when c > 0 && max_tokens > c ->
      Cascade_metrics.on_max_tokens_clamped ();
      if should_log_auto_max_tokens_clamp
           ~cascade_name ~source ~max_tokens ~ceiling:c
      then
        Log.warn ~ctx:"cascade"
          "%s: resolved max_tokens=%d from %s exceeds output ceiling=%d; \
           using ceiling; suppressing repeats for this tuple"
          (Keeper_cascade_profile.runtime_name_to_string cascade_name)
          max_tokens source c;
      c
    | _ -> max_tokens
end
