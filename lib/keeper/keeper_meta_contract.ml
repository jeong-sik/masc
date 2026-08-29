(** Keeper meta policy/runtime contract and pure helpers.

    Included by [Keeper_types] so existing [Keeper_types.*] callers keep
    their public API while the type-heavy contract is separated from JSON
    parsing and store I/O. *)

open Keeper_types_profile

let now_iso () = Masc_domain.now_iso ()

(* -- Policy types (remain in keeper_meta top-level) -- *)

type proactive_policy =
  { enabled : bool }

type proactive_cycle_outcome =
  | Proactive_never_started
  | Proactive_unknown
  | Proactive_silent
  | Proactive_text_response
  | Proactive_tool_use
  | Proactive_mixed_response
  | Proactive_error

(* -- Runtime types (moved into agent_runtime_state) -- *)

type proactive_runtime =
  { count_total : int
  ; last_ts : float
  ; visible_count_total : int
  ; last_visible_ts : float
  ; last_outcome : proactive_cycle_outcome
  ; last_reason : string
  ; last_preview : string
  }

(* ── Structured blocker classification ──────────────────────── *)

type runtime_exhaustion_reason = Keeper_internal_error.runtime_exhaustion_reason =
  | Connection_refused
  | Dns_failure
  | No_providers_available
  | All_providers_failed
  | Candidates_filtered_after_cycles
  | Session_conflict
  | Capacity_exhausted
  | Other_detail of string

(** Total typed retryability for a runtime-exhaustion reason.

    Replaces a former string-prefix reparse in
    [keeper_supervisor_pause_policy] that matched on the wire form of
    [runtime_exhaustion_reason_code] and biased every unlisted reason to
    non-retryable via a [_ -> false] catch-all.  That polarity was wrong
    for transient/connectivity faults (Connection_refused, Dns_failure,
    No_providers_available, All_providers_failed), which the supervisor should retry.

    Exhaustive match: adding a new [runtime_exhaustion_reason] variant
    fails compilation here, forcing an explicit retryability decision
    rather than silently defaulting. *)
let runtime_exhaustion_reason_retryable (reason : runtime_exhaustion_reason) : bool =
  Keeper_internal_error.runtime_exhaustion_reason_retryable reason
;;

type blocker_class =
  | Runtime_exhausted of runtime_exhaustion_reason
  | Capacity_backpressure
  | Fiber_unresolved
    (** 2026-05-05: turn fiber finished without invoking [resolve_done]
        (cancelled mid-turn, raised an exception not handled by the
        body, or the AGENT_CORE request returned but the keeper switch tore
        down before completion bookkeeping ran).  Maps 1:1 to the
        supervisor's [Keeper_registry.Fiber_unresolved] observation key, so
        blocker_class stamping mirrors the same diagnosis on keeper_meta. *)
  | Agent_core_context_window_exceeded
  | Agent_core_unrecognized_stop_reason
  | Agent_core_guardrail_violation
  | Agent_core_tripwire_violation
  | Agent_core_input_required
  | Internal_unhandled_exception
    (** RFC-0159 follow-up (task-194): unhandled internal exception escaped the
        turn driver.  Previously [blocker_class_of_core_error] returned [None]
        for this variant, so dashboards/operators could not distinguish an
        unhandled internal failure from a clean turn. *)
  | Internal_bridge_exception
    (** Internal bridge (AGENT_CORE/stream) exception escaped the turn driver. *)
  | Internal_contract_rejected
    (** Internal contract was rejected by the turn driver. *)
  | Incomplete_tool_transcript
    (** Tool transcript was quarantined as incomplete. *)
  | Terminal_effect_failed
    (** A terminal tool effect failed after the turn's terminal outcome. *)
  | Provider_attempt_effect_fenced
    (** A provider failure cannot be retried without risking a duplicate effect. *)
  | Tool_correction_lost
    (** The fenced turn also carried typed pre_tool_use rejections: the
        model's correction round-trip was the casualty (masc#28885). *)
  | Receipt_persistence_failed
    (** Execution receipt persistence failed. *)
  | Gate_replay_repair_required
    (** Gate replay repair was required for an approval/effect. *)

let blocker_class_to_string = function
  | Runtime_exhausted _ -> "runtime_exhausted"
  | Capacity_backpressure -> "capacity_backpressure"
  | Fiber_unresolved -> "fiber_unresolved"
  | Agent_core_context_window_exceeded -> "agent_core_context_window_exceeded"
  | Agent_core_unrecognized_stop_reason -> "agent_core_unrecognized_stop_reason"
  | Agent_core_guardrail_violation -> "agent_core_guardrail_violation"
  | Agent_core_tripwire_violation -> "agent_core_tripwire_violation"
  | Agent_core_input_required -> "agent_core_input_required"
  | Internal_unhandled_exception -> "internal_unhandled_exception"
  | Internal_bridge_exception -> "internal_bridge_exception"
  | Internal_contract_rejected -> "internal_contract_rejected"
  | Incomplete_tool_transcript -> "incomplete_tool_transcript"
  | Terminal_effect_failed -> "terminal_effect_failed"
  | Provider_attempt_effect_fenced -> "provider_attempt_effect_fenced"
  | Tool_correction_lost -> "tool_correction_lost"
  | Receipt_persistence_failed -> "receipt_persistence_failed"
  | Gate_replay_repair_required -> "gate_replay_repair_required"
;;

let blocker_class_of_serialized_string = function
  | "runtime_exhausted" -> Some (Runtime_exhausted (Other_detail "runtime_exhausted"))
  | "capacity_backpressure" -> Some Capacity_backpressure
  | "fiber_unresolved" -> Some Fiber_unresolved
  | "agent_core_context_window_exceeded" -> Some Agent_core_context_window_exceeded
  | "agent_core_unrecognized_stop_reason" -> Some Agent_core_unrecognized_stop_reason
  | "agent_core_guardrail_violation" -> Some Agent_core_guardrail_violation
  | "agent_core_tripwire_violation" -> Some Agent_core_tripwire_violation
  | "agent_core_input_required" -> Some Agent_core_input_required
  | "internal_unhandled_exception" -> Some Internal_unhandled_exception
  | "internal_bridge_exception" -> Some Internal_bridge_exception
  | "internal_contract_rejected" -> Some Internal_contract_rejected
  | "incomplete_tool_transcript" -> Some Incomplete_tool_transcript
  | "terminal_effect_failed" -> Some Terminal_effect_failed
  | "provider_attempt_effect_fenced" -> Some Provider_attempt_effect_fenced
  | "tool_correction_lost" -> Some Tool_correction_lost
  | "receipt_persistence_failed" -> Some Receipt_persistence_failed
  | "gate_replay_repair_required" -> Some Gate_replay_repair_required
  | _ -> None
;;

let runtime_exhaustion_summary = function
  | Connection_refused ->
    "Runtime exhausted after provider failures; local runtime connection refused."
  | Dns_failure ->
    "Runtime exhausted; hostname resolution failed (DNS)."
  | No_providers_available -> "Runtime exhausted; no providers were available."
  | All_providers_failed ->
    "Runtime exhausted after all configured providers failed; inspect per-attempt root causes."
  | Candidates_filtered_after_cycles ->
    "Runtime exhausted after provider candidates were filtered; inspect candidate filter reasons."
  | Session_conflict ->
    "Runtime exhausted because another process owns the provider session lease."
  | Capacity_exhausted ->
    "Runtime exhausted; all providers reported capacity backpressure."
  | Other_detail _ ->
    "Runtime exhausted; inspect runtime attempts for the dominant root cause."
;;

let runtime_exhaustion_reason_to_json reason =
  Keeper_internal_error.runtime_exhaustion_reason_to_json reason

let runtime_exhaustion_reason_of_json json =
  Keeper_internal_error.runtime_exhaustion_reason_of_json json

(* ── Unified blocker_info: typed klass + free-form detail ───────
   Replaces the historic split blocker fields. The string-only field was used
   by substring classifiers to recover a typed class — exactly the workaround
   pattern called out in CLAUDE.md
   "워크어라운드 거부 기준 #2 String/Substring 분류기 보강". Making
   [blocker_class] the only authoritative class eliminates that recovery path;
   [detail] carries free-form context for UI / Otel_metric_store labels (no
   classification semantics). *)
type blocker_info = {
  klass : blocker_class;
  detail : string;
}

let blocker_info_of_class ?(detail = "") klass = { klass; detail }

type runtime_attempt_record =
  { provider_id : string
  ; http_status : int option
  ; outcome : [ `Success | `Failure of string ]
  ; timestamp : float
  }

let runtime_attempt_outcome_to_json = function
  | `Success -> `Assoc [ "kind", `String "success" ]
  | `Failure message ->
    `Assoc [ "kind", `String "failure"; "message", `String message ]
;;

let runtime_attempt_record_to_json (record : runtime_attempt_record) : Yojson.Safe.t =
  `Assoc
    [ "provider_id", `String record.provider_id
    ; ( "http_status"
      , match record.http_status with
        | Some status -> `Int status
        | None -> `Null )
    ; "outcome", runtime_attempt_outcome_to_json record.outcome
    ; "timestamp", `Float record.timestamp
    ]
;;

type usage_metrics =
  { total_turns : int
  ; total_input_tokens : int
  ; total_output_tokens : int
  ; total_tokens : int
  ; total_cost_usd : float
  ; last_turn_ts : float
  ; last_input_tokens : int
  ; last_output_tokens : int
  ; last_total_tokens : int
  ; last_usage_reported_at : float option
  ; last_latency_ms : int
  }

let with_last_reported_usage
      (metrics : usage_metrics)
      ~(usage_reported : bool)
      ~(input_tokens : int)
      ~(output_tokens : int)
      ~(total_tokens : int)
      ~(observed_at : float)
  =
  if usage_reported then
    {
      metrics with
      last_input_tokens = input_tokens;
      last_output_tokens = output_tokens;
      last_total_tokens = total_tokens;
      last_usage_reported_at = Some observed_at;
    }
  else metrics
;;

type agent_runtime_state =
  { usage : usage_metrics
  ; proactive_rt : proactive_runtime
  ; trace_id : Keeper_id.Trace_id.t
  ; trace_history : string list
  ; last_handoff_ts : float
  ; last_runtime_attempt : runtime_attempt_record option
  ; message_scope_ack_id : string option
    (** Stable chat-row id of the newest message-scope row actually injected
        into a completed Keeper turn. Rows after this id remain pending. *)
  }

type keeper_meta =
  { (* -- Identity & profile -- *)
    id : Ids.Keeper_id.t option [@default None]
  ; name : string
  ; instructions : string
  ; (* -- Policy -- *)
    sandbox_profile : Keeper_types_profile.sandbox_profile
  ; sandbox_image : string option
  ; network_mode : Keeper_types_profile.network_mode
  ; mention_targets : string list
  ; proactive : proactive_policy
  ; (* -- Lifecycle -- *)
    created_at : string
  ; updated_at : string
  ; (* -- Performance & Limits -- *)
    max_context_override : int option
  ; (* -- Operational control (top-level, not runtime) -- *)
    paused : bool
  ; latched_reason : Keeper_latched_reason.t option
    (** Typed companion to [paused]. Explicit operator pause and
        transcript-corruption reset-required paths may write it. [None] while
        paused is a fail-closed unclassified state that requires operator
        action. *)
  ; autoboot_enabled : bool
  ; current_task_id : Keeper_id.Task_id.t option
    (** Currently claimed task ID for cost attribution.
      Set when keeper claims a task; cleared on masc_transition action=done.
      Propagated to trajectory accumulator for per-task cost tracking. *)
  ; telemetry_feedback_enabled : bool option
  ; telemetry_feedback_window_hours : int option
  ; always_allow : bool option
  ; (* -- Agent runtime state (usage, tracing, autonomy metrics) -- *)
    runtime : agent_runtime_state
  ; (* -- Identity & concurrency -- *)
    keeper_id : Keeper_id.Uid.t option
  ; agent_core_env : (string * string) list
  }

(* Sanctioned generic unpause transform. Every latch this type can carry is an
   explicit operator pause, so resume clears it. *)
let mark_resumed (m : keeper_meta) : keeper_meta =
  { m with
    paused = false
  ; latched_reason = None
  }
;;

let apply_profile_default opt current =
  match opt with
  | Some value -> value
  | None -> current
;;

let apply_profile_default_opt opt current =
  match opt with
  | Some _ -> opt
  | None -> current
;;

let missing_required_sandbox_profile_error ~keeper_name
    (defaults : Keeper_types_profile.keeper_profile_defaults) =
  let manifest_hint =
    match defaults.manifest_path with
    | Some path -> Printf.sprintf " (loaded from %s)" path
    | None -> ""
  in
  Printf.sprintf
    "keeper %s rejected: sandbox_profile is required (allowed: %s)%s. \
     Add e.g. `sandbox_profile = \"docker\"` to the keeper TOML."
    keeper_name
    (String.concat ", " Keeper_types_profile.valid_sandbox_profile_strings)
    manifest_hint
;;

let effective_meta_of_profile_defaults
    (defaults : Keeper_types_profile.keeper_profile_defaults)
    (meta : keeper_meta) : (keeper_meta, string) result =
  let open Keeper_types_profile in
  let has_profile_source = Option.is_some defaults.manifest_path in
  let target_sandbox_profile =
    match defaults.sandbox_profile, defaults.manifest_path with
    | Some profile, _ -> Ok profile
    | None, None -> Ok meta.sandbox_profile
    | None, Some _ ->
      Error
        (missing_required_sandbox_profile_error
           ~keeper_name:meta.name
           defaults)
  in
  match target_sandbox_profile with
  | Error _ as err -> err
  | Ok Local when not (Env_config_sandbox.Gate.allow_local_playground ()) ->
      Error
        (Printf.sprintf "keeper %s rejected: %s"
           meta.name Env_config_sandbox.Gate.disabled_message)
  (* Phase 1 SSH lane: [Remote_ssh] is the intended new lane, so the local
     gate must NOT reject it — but it is undispatchable without the
     [remote_endpoint] naming its [exec.ssh.endpoints.<name>] registry
     entry, so config-load validation fails closed here instead of
     letting the keeper boot into a dispatch that can only error. A blank
     or whitespace-only value counts as missing (same trim idiom as
     [runtime_id] below). The masc_keeper_up tool-arg side of this check
     is Phase 1 task 9. *)
  | Ok Remote_ssh
    when (match defaults.remote_endpoint with
          | None -> true
          | Some endpoint -> String.trim endpoint = "") ->
      Error
        (Printf.sprintf
           "keeper %s rejected: remote_ssh_endpoint_missing: sandbox_profile \
            \"remote_ssh\" requires remote_endpoint = \"<name>\" in the keeper \
            TOML (registry: [exec.ssh.endpoints.<name>] in runtime config)"
           meta.name)
  | Ok sandbox_profile ->
      let default_network_mode =
        if has_profile_source then default_network_mode_for_profile sandbox_profile
        else meta.network_mode
      in
      let network_mode =
        apply_profile_default defaults.network_mode default_network_mode
      in
      Ok
        { meta with
          proactive =
            { enabled =
                apply_profile_default defaults.proactive_enabled
                  Keeper_config.default_proactive_enabled
            };
          instructions =
            apply_profile_default defaults.instructions meta.instructions;
          autoboot_enabled =
            apply_profile_default defaults.autoboot_enabled
              meta.autoboot_enabled;
          mention_targets =
            (match defaults.mention_targets with
             | [] -> meta.mention_targets
             | targets -> targets);
          max_context_override =
            apply_profile_default_opt defaults.max_context_override
              meta.max_context_override;
          sandbox_profile;
          sandbox_image =
            apply_profile_default_opt defaults.sandbox_image meta.sandbox_image;
          network_mode;
          (* RFC vision-delegation §2.4: TOML profile overrides the carried
             value; absent -> keep [meta]'s (defaults to Inherit). *)
          telemetry_feedback_enabled =
            apply_profile_default_opt defaults.telemetry_feedback_enabled
              meta.telemetry_feedback_enabled;
          telemetry_feedback_window_hours =
            apply_profile_default_opt defaults.telemetry_feedback_window_hours
              meta.telemetry_feedback_window_hours;
          always_allow =
            apply_profile_default_opt defaults.always_allow
              meta.always_allow;
          agent_core_env =
            (match defaults.agent_core_env with
             | [] -> meta.agent_core_env
             | env -> env);
        }
;;

let effective_meta_result ~base_path (meta : keeper_meta) : (keeper_meta, string) result =
  match
    Keeper_types_profile.load_keeper_profile_defaults_result_for_base_path
      ~base_path
      meta.name
  with
  | Error error ->
      Error
        (Printf.sprintf
           "invalid keeper profile for keeper %s: %s"
           meta.name
           (Keeper_types_profile.keeper_toml_load_error_to_string error))
  | Ok defaults -> effective_meta_of_profile_defaults defaults meta
;;

(* A keeper's runtime is assigned in runtime.toml ([[runtime.assignments]],
   the sole SSOT), keyed by keeper name. An unassigned keeper uses the default
   runtime. The id is opaque here; only the AGENT_CORE adapter parses it. *)
let runtime_id_of_meta (meta : keeper_meta) =
  match Runtime.runtime_id_for_keeper meta.name with
  | Some runtime_id when String.trim runtime_id <> "" -> String.trim runtime_id
  | Some _ | None -> Runtime.get_default_runtime_id ()
;;

let proactive_cycle_outcome_to_string = function
  | Proactive_never_started -> "never_started"
  | Proactive_unknown -> "unknown"
  | Proactive_silent -> "silent"
  | Proactive_text_response -> "text_response"
  | Proactive_tool_use -> "tool_use"
  | Proactive_mixed_response -> "mixed_response"
  | Proactive_error -> "error"
;;

let proactive_cycle_outcome_of_string raw =
  match String.trim (String.lowercase_ascii raw) with
  | "never_started" -> Proactive_never_started
  | "unknown" -> Proactive_unknown
  | "silent" -> Proactive_silent
  | "text_response" -> Proactive_text_response
  | "tool_use" -> Proactive_tool_use
  | "mixed_response" -> Proactive_mixed_response
  | "error" -> Proactive_error
  | _ -> Proactive_unknown
;;

(* Round-trip guard: [proactive_cycle_outcome_to_string] already fails to
   compile when a new variant is added (its match has no wildcard).  This
   assertion enforces the other direction — if a new variant's label is
   not wired through [proactive_cycle_outcome_of_string], the round-trip
   silently collapses the new case to [Proactive_unknown] and leaks it at
   runtime.  The exhaustive pattern inside [assert_roundtrip] makes
   adding a variant a compile error until the parser is extended too. *)
let () =
  let assert_roundtrip v =
    (match v with
     | Proactive_never_started
     | Proactive_unknown
     | Proactive_silent
     | Proactive_text_response
     | Proactive_tool_use
     | Proactive_mixed_response
     | Proactive_error -> ());
    let s = proactive_cycle_outcome_to_string v in
    if proactive_cycle_outcome_of_string s <> v
    then
      invalid_arg
        (Printf.sprintf "keeper_types: proactive round-trip broken for label %S" s)
  in
  List.iter
    assert_roundtrip
    [ Proactive_never_started
    ; Proactive_unknown
    ; Proactive_silent
    ; Proactive_text_response
    ; Proactive_tool_use
    ; Proactive_mixed_response
    ; Proactive_error
    ]
;;

(* -- Updater helpers -- *)

let map_usage (f : usage_metrics -> usage_metrics) (m : keeper_meta) : keeper_meta =
  { m with runtime = { m.runtime with usage = f m.runtime.usage } }
;;

let zero_usage : usage_metrics =
  { total_turns = 0
  ; total_input_tokens = 0
  ; total_output_tokens = 0
  ; total_tokens = 0
  ; total_cost_usd = 0.0
  ; last_turn_ts = 0.0
  ; last_input_tokens = 0
  ; last_output_tokens = 0
  ; last_total_tokens = 0
  ; last_usage_reported_at = None
  ; last_latency_ms = 0
  }
;;

let reset_runtime_state (m : keeper_meta) : keeper_meta =
  map_usage (fun _ -> zero_usage) m
;;
