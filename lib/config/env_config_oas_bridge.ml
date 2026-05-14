(** Env_config_oas_bridge — per-caller OAS bridge timeout SSOT (#10094).

    Replaces seven hardcoded [Masc_oas_bridge.run_safe ~timeout_s:N.N]
    literals scattered across the lib tree.  Each caller is named so:

      1. its default is preserved when the original literal was a
         deliberately-tuned value (autoresearch_codegen=120s,
         tool_deep_review=180s, anti_rationalization=180s);
      2. the two old "fantasy" 60s budgets ([auto_responder],
         [dashboard_provider_runs]) get raised to [default_timeout_sec]
         (300s) — the original 60s did not match observed p50 latency
         (50–700s) and produced 27 timeouts/session;
      3. dashboard judge daemons stay advisory and bounded by default
         instead of holding an OAS CLI subprocess for multiple dashboard
         refresh intervals;
      4. the operator can override any single caller's budget via
         [MASC_OAS_BRIDGE_TIMEOUT_<CALLER>_SEC];
      5. the operator can set a fallback for unknown / future callers
         via [MASC_OAS_BRIDGE_TIMEOUT_DEFAULT_SEC].

    The lookup order is per-caller env > per-caller hardcoded default
    > [MASC_OAS_BRIDGE_TIMEOUT_DEFAULT_SEC] > 300.0.  An unknown
    caller (future caller without a typed default) falls through to
    the global default rather than failing closed — the operator will
    see [metric_oas_bridge_timeout{caller=...}] in Prometheus
    regardless. *)

type caller =
  | Auto_responder
  | Dashboard_provider_runs
  | Autoresearch_codegen
  | Keeper_persona_authoring
  | Server_openai_compat
  | Tool_deep_review
  | Anti_rationalization
  | Governance_judge
  | Operator_judge
  | Unknown of string

(** Hardcoded default seconds for each known caller.  When the
    original literal was 60s on a path with observed p50 above 60s,
    we raise to [global_default_sec] (300s) — silent fix for the
    fantasy budgets called out in #10094.  When the original literal
    was 120/180s on a path that intentionally needed more compute,
    we preserve the value so the fix does not regress
    autoresearch / deep_review / anti_rationalization. *)
let global_default_sec = 300.0

(** Dashboard judges are background/advisory signal generators.  They run on the
    operator screen cadence, so a default at or above the generic 300s worker
    budget can pin a CLI-backed OAS child for several refreshes and starve the
    live dashboard.  Keep this below the default 60s judge interval; operators
    can still raise it per caller when they explicitly prefer completeness over
    responsiveness. *)
let dashboard_judge_default_sec = 45.0

let caller_key = function
  | Auto_responder -> "auto_responder"
  | Dashboard_provider_runs -> "dashboard_provider_runs"
  | Autoresearch_codegen -> "autoresearch_codegen"
  | Keeper_persona_authoring -> "keeper_persona_authoring"
  | Server_openai_compat -> "server_openai_compat"
  | Tool_deep_review -> "tool_deep_review"
  | Anti_rationalization -> "anti_rationalization"
  | Governance_judge -> "governance_judge"
  | Operator_judge -> "operator_judge"
  | Unknown caller -> caller
;;

(** Exported for tests that pin the per-caller default table. *)
let known_callers () =
  [ Auto_responder
  ; Dashboard_provider_runs
  ; Autoresearch_codegen
  ; Keeper_persona_authoring
  ; Server_openai_compat
  ; Tool_deep_review
  ; Anti_rationalization
  ; Governance_judge
  ; Operator_judge
  ]
;;

let known_default_sec = function
  (* #10094: was hardcoded 60s, raised to global_default.  p50 of
     the underlying LLM call is in the 50–700s range; 60s timed out
     27 times per session. *)
  | Auto_responder | Dashboard_provider_runs -> Some global_default_sec
  (* Preserved at original literal — these were tuned for the
     specific compute pattern of the caller. *)
  | Autoresearch_codegen | Keeper_persona_authoring | Server_openai_compat -> Some 120.0
  | Tool_deep_review | Anti_rationalization -> Some 180.0
  (* #9629 moved both judges into this SSOT after Operator_judge inherited a
     too-short generic inference timeout.  Live dashboard evidence showed the
     opposite failure mode: a 300s advisory judge budget can leave a
     CLI-backed child running for minutes while operator/health surfaces stall.
     Keep the caller-specific env overrides, but make the checked-in default
     bounded for dashboard responsiveness. *)
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

(** #9629: Each caller may also honour a legacy env var name from
    before the SSOT migration.  When present, the legacy name acts
    as a tier-2 override (between the new per-caller env var and the
    checked-in default) so operators with deployment configs pinning
    the legacy name continue to take effect during the migration
    window.  Returning [None] means the caller has no legacy alias. *)
let legacy_per_caller_env_var = function
  | Operator_judge -> Some "MASC_OPERATOR_JUDGE_TIMEOUT_SEC"
  | Governance_judge -> Some "MASC_DASHBOARD_GOVERNANCE_JUDGE_TIMEOUT_SEC"
  | Auto_responder
  | Dashboard_provider_runs
  | Autoresearch_codegen
  | Keeper_persona_authoring
  | Server_openai_compat
  | Tool_deep_review
  | Anti_rationalization -> None
  | Unknown _ -> None
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

let positive_finite_or_default ~default value =
  if Float.is_finite value && Float.compare value 0.0 > 0 then value else default
;;

let timeout_env_value ~default raw =
  Safe_ops.float_of_string_with_default ~default raw
  |> positive_finite_or_default ~default
;;

(** [timeout_sec ~caller ()] resolves the OAS bridge timeout for
    [caller].  Lookup order:

      1. Per-caller env [MASC_OAS_BRIDGE_TIMEOUT_<CALLER>_SEC]
         — wins unconditionally.  Lets the operator tune one
         caller without touching others.
      2. Legacy per-caller env (#9629).  Operator_judge accepts
         [MASC_OPERATOR_JUDGE_TIMEOUT_SEC]; Governance_judge accepts
         [MASC_DASHBOARD_GOVERNANCE_JUDGE_TIMEOUT_SEC].  Honoured for
         the migration window so operator deployment configs that
         still pin the pre-SSOT names keep working.  Removed when
         no legacy alias is registered for the caller.
      3. Per-caller checked-in default ([known_default_sec]).
         Preserves intentional 120/180s budgets for compute-heavy
         callers; raises the old fantasy 60s worker budgets to
         [global_default_sec] (300s); bounds dashboard judge daemons to
         [dashboard_judge_default_sec].
      4. Global env [MASC_OAS_BRIDGE_TIMEOUT_DEFAULT_SEC] — only
         consulted for UNKNOWN callers (typo, future caller
         without a default entry).  Treating it as an override
         would let one slow provider silently shift every
         caller's budget; that is a footgun.
      5. [global_default_sec] (300s) hardcoded final fallback. *)
let timeout_sec ~caller () =
  let per_caller_env = per_caller_env_var ~caller in
  match trimmed_value_opt per_caller_env with
  | Some v -> timeout_env_value ~default:global_default_sec v
  | None ->
    let legacy_env_value =
      match legacy_per_caller_env_var caller with
      | Some name -> trimmed_value_opt name
      | None -> None
    in
    (match legacy_env_value with
     | Some v -> timeout_env_value ~default:global_default_sec v
     | None ->
       (match known_default_sec caller with
        | Some d -> d
        | None ->
          (* Unknown caller: fall to global env, then global default. *)
          (match trimmed_value_opt global_env_var with
           | Some v -> timeout_env_value ~default:global_default_sec v
           | None -> global_default_sec)))
;;
