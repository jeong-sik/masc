(* See cascade_attempt_liveness_config.mli for documentation.

   RFC-0022 PR-2/4 §2 — tri-state env flag + per-label budget map.
   RFC-0058 Phase 5.2b — provider→budget routing reads
   [Cascade_declarative_types.cascade_provider.liveness_class] declared
   in [config/cascade.toml]. The hardcoded
   [match provider_id with "codex_cli" | "claude_code" | …] block is
   deleted (RFC-0058 §4 Phase 5.2b acceptance). *)

type mode =
  | Off
  | Observe
  | Enforce

let mode_label = function
  | Off -> "off"
  | Observe -> "observe"
  | Enforce -> "enforce"
;;

let env_var_name = "MASC_CASCADE_ATTEMPT_LIVENESS"

let parse_mode raw =
  match String.lowercase_ascii (String.trim raw) with
  | "off" | "0" | "false" | "disabled" -> Off
  | "enforce" | "kill" | "on_kill" -> Enforce
  | "" | "observe" | "default" | "1" | "true" | "shadow" -> Observe
  | _ -> Observe (* unknown values default to Observe — never silently Off *)
;;

(* Cached after first read. Mirrors Keeper_admission_glue.use_new_admission. *)
let mode_cache : mode option ref = ref None

let current_mode () =
  match !mode_cache with
  | Some m -> m
  | None ->
    let m =
      match Sys.getenv_opt env_var_name with
      (* Truly-unset env var → [Observe], matching the .mli contract and
         [parse_mode ""]. The module's stance is "default to Observe,
         never silently Off, only Enforce when explicitly requested". *)
      | None -> Observe
      | Some raw -> parse_mode raw
    in
    mode_cache := Some m;
    m
;;

(* RFC-0058 Phase 5.2b — lazy declarative-config cache.

   A *successful* parse of [Config_dir_resolver.cascade_path_candidate]
   is cached and reused for every subsequent provider→budget lookup. A
   *failed* parse (missing file during a boot race, transient permission
   error, half-written TOML mid-deploy, pre-5-layer schema) is NOT
   cached — the next call re-attempts so a recovered config takes effect
   without a restart. Until a parse succeeds, [budget_for_provider_id]
   falls back to [cloud_fast] (the conservative default the deleted
   hardcoded match used for unknown ids). Cost of the no-cache-on-error
   policy: one TOML parse per [budget_for_provider_id] call during an
   outage window — acceptable, as these calls are per-attempt (not
   per-token) and most callers thread an explicit [?cfg] anyway. *)
let cfg_cache : Cascade_declarative_types.cascade_config option ref = ref None

let load_active_cfg () : Cascade_declarative_types.cascade_config option =
  match !cfg_cache with
  | Some _ as cached -> cached
  | None ->
    let path = Config_dir_resolver.cascade_path_candidate () in
    (match Cascade_declarative_parser.parse_file path with
     | Ok cfg ->
       cfg_cache := Some cfg;
       Some cfg
     | Error _ -> None)
;;

let reset_cache_for_test () =
  mode_cache := None;
  cfg_cache := None
;;

let budget_of_class
  : Cascade_declarative_types.cascade_liveness_class -> Cascade_attempt_liveness.budget
  = function
  | Cloud_fast -> Cascade_attempt_liveness.cloud_fast
  | Cloud_thinking -> Cascade_attempt_liveness.cloud_thinking
  | Local_27b -> Cascade_attempt_liveness.local_27b
  | Local_70b_plus -> Cascade_attempt_liveness.local_70b_plus
;;

let liveness_class_for_provider_id
      ~(cfg : Cascade_declarative_types.cascade_config option)
      ~(provider_id : string)
  : Cascade_declarative_types.cascade_liveness_class option
  =
  let canon = String.lowercase_ascii (String.trim provider_id) in
  let active_cfg =
    match cfg with
    | Some _ as explicit -> explicit
    | None -> load_active_cfg ()
  in
  match active_cfg with
  | None -> None
  | Some c ->
    (* Try exact match first; fall back to case-folded scan so a
         caller passing an upper-cased provider_id still resolves
         against the lower-cased TOML keys. *)
    (match Cascade_declarative_types.provider_of_id c provider_id with
     | Some p -> p.liveness_class
     | None ->
       let normalized =
         List.find_opt
           (fun (p : Cascade_declarative_types.cascade_provider) ->
              String.lowercase_ascii p.id = canon)
           c.providers
       in
       Option.bind normalized (fun p -> p.liveness_class))
;;

let budget_for_provider_id
      ?(cfg : Cascade_declarative_types.cascade_config option)
      ~(provider_id : string)
      ()
  : Cascade_attempt_liveness.budget
  =
  match liveness_class_for_provider_id ~cfg ~provider_id with
  | Some c -> budget_of_class c
  | None ->
    (* RFC-0058 Phase 5.2b: cascade.toml is the SSOT. An unknown
         provider_id (not declared, or the cascade config failed to
         parse) falls back to [cloud_fast] — the conservative default
         the deleted hardcoded match used. The validator R-rule for
         [liveness.class] (Phase 5.2b) ensures every shipped provider
         in [config/cascade.toml] declares its class, so this fallback
         only fires for ad-hoc / custom integrations, not for the
         in-tree provider set. *)
    Cascade_attempt_liveness.cloud_fast
;;

(* RFC-0022 §1 — see .mli for contract. *)
let outer_wall_for_attempt ~mode ~observer_attached ~per_provider_timeout_s ~provider_id =
  match mode, observer_attached with
  | Enforce, true -> None
  | _, true ->
    let budget_wall =
      (budget_for_provider_id ~provider_id ()).Cascade_attempt_liveness.attempt_wall_max
    in
    Option.map (fun t -> Float.max t budget_wall) per_provider_timeout_s
  | _, false -> per_provider_timeout_s
;;
