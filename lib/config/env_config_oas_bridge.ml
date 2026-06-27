(** Env_config_oas_bridge — per-caller OAS bridge timeout SSOT (#10094).

    Each remaining caller is named so:

      1. anti-rationalization keeps its compute-heavy default (180s);
      2. dashboard judge daemons stay advisory and unbounded by default —
         a per-judge wrapper timeout that fires before the provider's
         first response arrives propagates fleet-wide idle instead of
         giving the operator a usable degraded signal;
      3. the operator can override any single caller's budget via
         [MASC_OAS_BRIDGE_TIMEOUT_<CALLER>_SEC];
      4. the operator can set a fallback for unknown / future callers
         via [MASC_OAS_BRIDGE_TIMEOUT_DEFAULT_SEC].

    The lookup order is per-caller env > per-caller hardcoded default
    > [MASC_OAS_BRIDGE_TIMEOUT_DEFAULT_SEC] > 300.0.  An unknown
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

(** Legacy default for advisory dashboard judge callers. Retained as a
    named pin so tests that previously asserted on it (45.0) keep a
    stable reference, but it is no longer the active default for any
    caller — the {b governance_judge_no_timeout} value below replaces
    the [Governance_judge | Operator_judge] arms in [known_default_sec]
    (#20082-style: 2026-06-08 fleet-wide idle root cause was a 45s
    judge wrapper firing before the OAS provider's first response). *)
let dashboard_judge_default_sec = 45.0

(** Dashboard judge callers are advisory signal generators running on a
    background daemon cycle. A wrapper timeout that fires while the
    provider is still preparing the first response (boot race or lane
    saturation) propagates fleet-wide idle: the daemon fiber blocks,
    the next [refresh_once] skips behind it, and operators see a frozen
    dashboard with no incremental signal. Real protection is the OAS
    bridge's own per-call timeout (or no-timeout) inside the wrapped
    computation, plus the typed in-flight invariant in
    [Dashboard_governance_judge.mark_compute_start]. Therefore both
    judge callers resolve to [governance_judge_no_timeout], which is
    [Float.infinity]: the bridge applies no practical wrapper timeout
    while still satisfying [run_safe]'s positive-or-infinite contract.
    Per-caller env overrides
    [MASC_OAS_BRIDGE_TIMEOUT_GOVERNANCE_JUDGE_SEC] /
    [MASC_OAS_BRIDGE_TIMEOUT_OPERATOR_JUDGE_SEC] still win — operators
    can re-bind a finite budget if they explicitly want one. *)
let governance_judge_no_timeout = Float.infinity

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
  (* #9629 originally bounded both judges to 45s for dashboard responsiveness.
     #20082 reversed this: the 45s wrapper timeout was firing before the
     provider's first response (boot race, ollama_cloud lane saturation) and
     propagating fleet-wide idle.  Real protection lives at the OAS provider
     boundary, not in a per-judge cycle wrapper, so both callers now resolve
     to [Float.infinity]. *)
  | Governance_judge | Operator_judge -> Some governance_judge_no_timeout
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

(** Per-caller OAS bridge timeout override for anti-rationalization. Positive
    finite values set the wrapper budget; [infinity] means no-fire.
    @category Timeouts @ops_class operator *)
let anti_rationalization_env_var =
  "MASC_OAS_BRIDGE_TIMEOUT_ANTI_RATIONALIZATION_SEC"
;;

(** Per-caller OAS bridge timeout override for the dashboard governance judge.
    Positive finite values set the wrapper budget; [infinity] means no-fire.
    @category Timeouts @ops_class operator *)
let governance_judge_env_var =
  "MASC_OAS_BRIDGE_TIMEOUT_GOVERNANCE_JUDGE_SEC"
;;

(** Per-caller OAS bridge timeout override for the dashboard operator judge.
    Positive finite values set the wrapper budget; [infinity] means no-fire.
    @category Timeouts @ops_class operator *)
let operator_judge_env_var =
  "MASC_OAS_BRIDGE_TIMEOUT_OPERATOR_JUDGE_SEC"
;;

let per_caller_env_var ~caller =
  match caller with
  | Anti_rationalization -> anti_rationalization_env_var
  | Governance_judge -> governance_judge_env_var
  | Operator_judge -> operator_judge_env_var
  | Unknown caller ->
    Printf.sprintf "MASC_OAS_BRIDGE_TIMEOUT_%s_SEC" (upper_case caller)
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

(** Accept positive floats including [Float.infinity]. The [is_finite]
    guard below used to reject [infinity] silently, which would have
    collapsed the dashboard-judge no-timeout pin back to
    [global_default_sec] (300s) the moment any env override went
    through this function.  The OAS bridge treats [infinity] as
    no-fire, so we let it pass. *)
let positive_or_default ~default value =
  if Float.compare value 0.0 > 0 then value else default
;;

let timeout_env_value ~default raw =
  Safe_ops.float_of_string_with_default ~default raw
  |> positive_or_default ~default
;;

(** [timeout_sec ~caller ()] resolves the OAS bridge timeout for
    [caller].  Lookup order:

      1. Per-caller env [MASC_OAS_BRIDGE_TIMEOUT_<CALLER>_SEC]
         — wins unconditionally.  Lets the operator tune one
         caller without touching others.  Non-positive and [nan]
         values fall back to the default so the OAS bridge receives
         an enforceable budget; [infinity] is accepted as no-fire.
      2. Per-caller checked-in default ([known_default_sec]).
         Preserves intentional 180s budgets for compute-heavy
         callers; dashboard judge callers resolve to
         [governance_judge_no_timeout] ([Float.infinity]) so the
         bridge never wraps their cycle in a timer.
      3. Global env [MASC_OAS_BRIDGE_TIMEOUT_DEFAULT_SEC] — only
         consulted for UNKNOWN callers (typo, future caller
         without a default entry).  Treating it as an override
         would let one slow provider silently shift every
         caller's budget; that is a footgun.
      4. [global_default_sec] (300s) hardcoded final fallback. *)
let timeout_sec ~caller () =
  let per_caller_env = per_caller_env_var ~caller in
  match trimmed_value_opt per_caller_env with
  | Some v -> timeout_env_value ~default:global_default_sec v
  | None ->
    (match known_default_sec caller with
     | Some d -> d
     | None ->
       (* Unknown caller: fall to global env, then global default. *)
       (match trimmed_value_opt global_env_var with
        | Some v -> timeout_env_value ~default:global_default_sec v
        | None -> global_default_sec))
;;
