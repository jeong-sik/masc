(** Env_config_oas_bridge — per-caller OAS bridge timeout SSOT (#10094).

    Each remaining caller is named so:

      1. anti-rationalization keeps its compute-heavy default (180s);
      2. dashboard judge daemons use a bounded advisory default so stale
         dashboard work cannot pin the bridge indefinitely;
      3. the operator can override any single caller's budget via
         [MASC_OAS_BRIDGE_TIMEOUT_<CALLER>_SEC];
      4. the operator can set a fallback for unknown / future callers
         via [MASC_OAS_BRIDGE_TIMEOUT_DEFAULT_SEC].

    The lookup order is per-caller env > per-caller hardcoded default
    > [MASC_OAS_BRIDGE_TIMEOUT_DEFAULT_SEC] > 300.0. An unknown
    caller (future caller without a typed default) falls through to
    the global default rather than failing closed — the operator will
    see [metric_oas_bridge_timeout{caller=...}] in Otel_metric_store
    regardless. *)

type caller =
  | Anti_rationalization
  | Governance_judge
  | Operator_judge
  | Unknown of string

(** Hardcoded default seconds for each known caller. *)
let global_default_sec = 300.0

(** Default for advisory dashboard judge callers. This stays above the old
    30/60s warning-prone path, but remains finite so dashboard work cannot
    pin the bridge indefinitely. Per-caller env overrides still win. *)
let dashboard_judge_default_sec = 180.0

let caller_key = function
  | Anti_rationalization -> "anti_rationalization"
  | Governance_judge -> "governance_judge"
  | Operator_judge -> "operator_judge"
  | Unknown caller -> caller
;;

(** Exported for tests that pin the per-caller default table. *)
let known_callers () =
  [ Anti_rationalization
  ; Governance_judge
  ; Operator_judge
  ]
;;

let known_default_sec = function
  | Anti_rationalization -> Some 180.0
  | Governance_judge | Operator_judge -> Some dashboard_judge_default_sec
  | Unknown _ -> None
;;

let upper_case s =
  s
  |> String.map (fun c ->
    if c >= 'a' && c <= 'z'
    then Char.chr (Char.code c - 32)
    else if c = '-'
    then '_'
    else c)
;;

let per_caller_env_var ~caller =
  Printf.sprintf "MASC_OAS_BRIDGE_TIMEOUT_%s_SEC" (upper_case (caller_key caller))
;;

let global_env_var = "MASC_OAS_BRIDGE_TIMEOUT_DEFAULT_SEC"

(** Empty-string env vars (the [Unix.putenv NAME ""] pattern used
    by tests to clear an override) must NOT be treated as "set".
    [Sys.getenv_opt] returns [Some ""] in that case. *)
let trimmed_value_opt name =
  match Env_config_core.raw_value_opt name with
  | Some v ->
    let t = String.trim v in
    if t = "" then None else Some t
  | None -> None
;;

(** Accept only positive finite floats. [infinity] would bypass the bridge
    timeout wrapper, so it is treated like any other invalid env value. *)
let timeout_env_value_opt ~name raw =
  let reject () =
    let type_name = "positive finite float" in
    Log.Misc.warn
      "malformed env %s=%S (expected %s); falling back"
      name
      raw
      type_name;
    if Env_config_core.parse_warn_enabled ()
    then
      raise
        (Env_config_core.Config_error
           (Printf.sprintf "malformed env %s=%S (expected %s)" name raw type_name));
    None
  in
  match Safe_ops.float_of_string_safe raw with
  | None -> reject ()
  | Some value ->
    if Float.is_finite value && Float.compare value 0.0 > 0
    then Some value
    else reject ()
;;

(** [timeout_sec ~caller ()] resolves the OAS bridge timeout for
    [caller].  Lookup order:

      1. Per-caller env [MASC_OAS_BRIDGE_TIMEOUT_<CALLER>_SEC]
         — wins unconditionally.  Lets the operator tune one
         caller without touching others. Invalid values, including
         [Float.infinity], are treated as an invalid override and
         fall through to the next lookup step.
      2. Per-caller checked-in default ([known_default_sec]).
         Preserves intentional 180s budgets for compute-heavy callers;
         dashboard judge callers resolve to a finite
         [dashboard_judge_default_sec].
      3. Global env [MASC_OAS_BRIDGE_TIMEOUT_DEFAULT_SEC] — only
         consulted for UNKNOWN callers (typo, future caller
         without a default entry).  Treating it as an override
         would let one slow provider silently shift every
         caller's budget; that is a footgun.
      4. [global_default_sec] (300s) hardcoded final fallback. *)
let timeout_sec ~caller () =
  let per_caller_env = per_caller_env_var ~caller in
  let fallback () =
    match known_default_sec caller with
    | Some d -> d
    | None ->
      (* Unknown caller: fall to global env, then global default. *)
      (match trimmed_value_opt global_env_var with
       | Some v ->
         (match timeout_env_value_opt ~name:global_env_var v with
          | Some value -> value
          | None -> global_default_sec)
       | None -> global_default_sec)
  in
  match trimmed_value_opt per_caller_env with
  | Some v ->
    (match timeout_env_value_opt ~name:per_caller_env v with
     | Some value -> value
     | None -> fallback ())
  | None -> fallback ()
;;
