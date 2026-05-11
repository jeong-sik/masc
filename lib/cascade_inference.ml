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

(** Resolve a max_tokens value: cascade config -> fallback. *)
let resolve_max_tokens
    ~(cascade_name : Keeper_cascade_profile.runtime_name)
    ~(fallback : unit -> int) : int =
  let cascade_name = Keeper_cascade_profile.runtime_name_to_string cascade_name in
  match (for_cascade ~name:cascade_name).max_tokens with
  | Some t -> t
  | None -> fallback ()

(** Clamp max_tokens to provider ceiling.
    Clamping > rejection: a smaller response is better than no response.
    Mirrors TLA+ KeeperCoreTriad.CapabilityGate action. *)
let clamp_max_tokens_to_ceiling ~(provider_ceiling : int option) (max_tokens : int) : int =
  match provider_ceiling with
  | Some ceiling when max_tokens > ceiling -> max 1 ceiling
  | _ -> max_tokens
