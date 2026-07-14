(** Keeper meta policy/runtime contract and pure helpers.

    Included by [Keeper_types] so existing [Keeper_types.*] callers keep
    their public API while the type-heavy contract is separated from JSON
    parsing and store I/O. *)

open Keeper_types_profile

let now_iso () = Masc_domain.now_iso ()

(* -- Policy types (remain in keeper_meta top-level) -- *)

type compaction_policy =
  { profile : string
  ; mode : Keeper_config.compaction_mode
    (* HOW the checkpoint is summarized: [Deterministic] extractive chain
       (fail-closed default) or opt-in [Llm] librarian-lane summarizer (W2).
       Orthogonal to [profile], which decides WHEN to compact. *)
  ; ratio_gate : float
  ; message_gate : int
  ; token_gate : int
  ; cooldown_sec : int
  }

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

type compaction_runtime_decision = Compaction_runtime_decision of string

let compaction_runtime_decision_to_string (Compaction_runtime_decision value) = value
let compaction_runtime_decision_of_string value = Compaction_runtime_decision value

type compaction_runtime =
  { count : int
  ; last_ts : float
  ; last_before_tokens : int
  ; last_after_tokens : int
  ; last_check_ts : float
  ; last_decision : compaction_runtime_decision
  }

type proactive_runtime =
  { count_total : int
  ; last_ts : float
  ; visible_count_total : int
  ; last_visible_ts : float
  ; last_outcome : proactive_cycle_outcome
  ; last_reason : string
  ; last_preview : string
  ; consecutive_noop_count : int
    (** Consecutive autonomous cycles where only observation tools
          (board_list, context_status, other passive reads) were used with no
          substantive action.  Resets to 0 on any productive cycle.
          Used by [effective_scheduled_autonomous_cooldown] for exponential
          backoff: cooldown *= 2^min(n, 2), capping at 4x. *)
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
        body, or the OAS request returned but the keeper switch tore
        down before completion bookkeeping ran).  Maps 1:1 to the
        supervisor's [Keeper_registry.Fiber_unresolved] observation key, so
        blocker_class stamping mirrors the same diagnosis on keeper_meta. *)
  | Stale_turn_timeout
    (** 2026-05-05 cycle 9: stale watchdog forced fiber termination
        because the running turn exceeded [idle_turn] threshold (~5m).
        Maps to [Keeper_registry.Stale_turn_timeout _] cohort.  Like
        [Fiber_unresolved], this path runs through
        [force_unresolved_watchdog_crash]. Without this variant, dashboards and
        per-keeper meta lacked a structured blocker class for the majority
        cohort during a fleet stall (observed: 6/14 keepers in
        cohort=stale_turn_timeout). *)
  | Stale_fleet_batch
    (** Retired blocker class for pre-existing fleet-batch state. Current
        fleet-batch detection is observation-only and should not stamp keeper
        meta; stale keepers use their per-keeper watchdog blocker instead. *)
  | Sdk_context_window_exceeded
  | Sdk_unrecognized_stop_reason
  | Sdk_hook_execution_failed
  | Sdk_guardrail_violation
  | Sdk_tripwire_violation
  | Sdk_input_required

let blocker_class_to_string = function
  | Runtime_exhausted _ -> "runtime_exhausted"
  | Capacity_backpressure -> "capacity_backpressure"
  | Fiber_unresolved -> "fiber_unresolved"
  | Stale_turn_timeout -> "stale_turn_timeout"
  | Stale_fleet_batch -> "stale_fleet_batch"
  | Sdk_context_window_exceeded -> "sdk_context_window_exceeded"
  | Sdk_unrecognized_stop_reason -> "sdk_unrecognized_stop_reason"
  | Sdk_hook_execution_failed -> "sdk_hook_execution_failed"
  | Sdk_guardrail_violation -> "sdk_guardrail_violation"
  | Sdk_tripwire_violation -> "sdk_tripwire_violation"
  | Sdk_input_required -> "sdk_input_required"
;;

let blocker_class_of_serialized_string = function
  | "runtime_exhausted" -> Some (Runtime_exhausted (Other_detail "runtime_exhausted"))
  | "capacity_backpressure" -> Some Capacity_backpressure
  | "fiber_unresolved" -> Some Fiber_unresolved
  | "stale_turn_timeout" -> Some Stale_turn_timeout
  | "stale_fleet_batch" -> Some Stale_fleet_batch
  | "sdk_context_window_exceeded" -> Some Sdk_context_window_exceeded
  | "sdk_unrecognized_stop_reason" -> Some Sdk_unrecognized_stop_reason
  | "sdk_hook_execution_failed" -> Some Sdk_hook_execution_failed
  | "sdk_guardrail_violation" -> Some Sdk_guardrail_violation
  | "sdk_tripwire_violation" -> Some Sdk_tripwire_violation
  | "sdk_input_required" -> Some Sdk_input_required
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

let blocker_info_to_json (info : blocker_info) : Yojson.Safe.t =
  let klass_payload = match info.klass with
    | Runtime_exhausted reason ->
      `Assoc [ "name", `String "runtime_exhausted"
             ; "reason", runtime_exhaustion_reason_to_json reason
             ]
    | _ -> `String (blocker_class_to_string info.klass)
  in
  let fields =
    [ "klass", klass_payload
    ; "detail", `String info.detail
    ]
  in
  `Assoc fields
;;

let blocker_info_of_json (json : Yojson.Safe.t) : blocker_info option =
  match json with
  | `Null -> None
  | `Assoc fields ->
    let klass =
      match List.assoc_opt "klass" fields with
      | Some (`String s) -> blocker_class_of_serialized_string s
      | Some (`Assoc kfields) ->
        (match List.assoc_opt "name" kfields with
         | Some (`String "runtime_exhausted") ->
           let reason =
             match List.assoc_opt "reason" kfields with
             | Some r ->
               (match runtime_exhaustion_reason_of_json r with
                | Some r -> r
                | None -> Other_detail "runtime_exhausted")
             | None -> Other_detail "runtime_exhausted"
           in
           Some (Runtime_exhausted reason)
         | Some (`String s) -> blocker_class_of_serialized_string s
         | _ -> None)
      | _ -> None
    in
    (match klass with
     | None -> None
     | Some klass ->
       let detail = match List.assoc_opt "detail" fields with
         | Some (`String s) -> s
         | _ -> ""
       in
       Some { klass; detail })
  | _ -> None
;;

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

let runtime_attempt_outcome_of_json = function
  | `Assoc fields ->
    (match List.assoc_opt "kind" fields with
     | Some (`String "success") -> Some `Success
     | Some (`String "failure") ->
       (match List.assoc_opt "message" fields with
        | Some (`String message) -> Some (`Failure message)
        (* DET-OK: retired attempt rows encoded failure without a message;
           keep the lossy historical record instead of dropping it. *)
        | _ -> Some (`Failure ""))
     | _ -> None)
  | `String "success" -> Some `Success
  | `String "failure" -> Some (`Failure "")
  | _ -> None
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

let runtime_attempt_record_of_json (json : Yojson.Safe.t)
  : runtime_attempt_record option
  =
  match json with
  | `Null -> None
  | `Assoc fields ->
    let provider_id =
      match List.assoc_opt "provider_id" fields with
      | Some (`String value) -> Some value
      | _ -> None
    in
    let http_status =
      match List.assoc_opt "http_status" fields with
      | Some (`Int status) -> Some status
      | Some `Null | None -> None
      | _ -> None
    in
    let outcome =
      match List.assoc_opt "outcome" fields with
      | Some value -> runtime_attempt_outcome_of_json value
      | None -> None
    in
    let timestamp =
      match List.assoc_opt "timestamp" fields with
      | Some (`Float value) -> Some value
      | Some (`Int value) -> Some (float_of_int value)
      | _ -> None
    in
    (match provider_id, outcome, timestamp with
     | Some provider_id, Some outcome, Some timestamp ->
       Some { provider_id; http_status; outcome; timestamp }
     | _ -> None)
  | _ -> None
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
  ; last_latency_ms : int
  }

type tool_call_summary =
  { tool_name : string
  ; outcome : string
  }

type agent_runtime_state =
  { usage : usage_metrics
  ; compaction_rt : compaction_runtime
  ; proactive_rt : proactive_runtime
  ; generation : int
  ; trace_id : Keeper_id.Trace_id.t
  ; trace_history : string list
  ; last_handoff_ts : float
  ; last_autonomous_action_at : string
  ; autonomous_action_count : int
  ; autonomous_turn_count : int
  ; autonomous_text_turn_count : int
  ; autonomous_tool_turn_count : int
  ; board_reactive_turn_count : int
  ; mention_reactive_turn_count : int
  ; noop_turn_count : int
  ; last_blocker : blocker_info option
  ; last_runtime_attempt : runtime_attempt_record option
  ; last_turn_tool_calls : tool_call_summary list
  ; message_scope_ack_id : string option
    (** Stable chat-row id of the newest message-scope row actually injected
        into a completed Keeper turn. Rows after this id remain pending. *)
  }

type keeper_meta =
  { (* -- Identity & profile -- *)
    id : Ids.Keeper_id.t option [@default None]
  ; name : string
  ; agent_name : string
  ; persona : string option
  ; goal : string
  ; instructions : string
  ; (* -- Policy -- *)
    sandbox_profile : Keeper_types_profile.sandbox_profile
  ; sandbox_image : string option
  ; network_mode : Keeper_types_profile.network_mode
  ; allowed_paths : string list
  ; mention_targets : string list
  ; proactive : proactive_policy
  ; compaction : compaction_policy
  ; multimodal_policy : Keeper_types_profile.multimodal_policy
  ; auto_handoff : bool
  ; handoff_threshold : float
  ; handoff_cooldown_sec : int
  ; (* -- Lifecycle -- *)
    created_at : string
  ; updated_at : string
  ; (* -- Performance & Limits -- *)
    max_context_override : int option
  ; (* -- Operational control (top-level, not runtime) -- *)
    active_goal_ids : string list
  ; paused : bool
  ; latched_reason : Keeper_latched_reason.t option
    (** Typed companion to [paused]. Only explicit operator pause and terminal
        dead-tombstone paths may write it. [None] while paused is a fail-closed
        unclassified legacy state that requires an operator resume. *)
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
  ; oas_env : (string * string) list
  ; meta_version : int
  }

(* Sanctioned unpause transform: the coupled way to set [paused = false].
   Clears the typed latch (including the terminal [Dead_tombstone]) and the
   last blocker together with the pause bit, so [paused = false &&
   latched_reason <> None] cannot be constructed through the resume path.
   Terminal dead-tombstone revival additionally runs the crash-recoverable
   [Keeper_dead_revival_transaction] at its call site; [mark_resumed] only
   normalizes the meta fields. Callers set [updated_at] themselves. *)
let mark_resumed (m : keeper_meta) : keeper_meta =
  { m with
    paused = false
  ; latched_reason = None
  ; runtime = { m.runtime with last_blocker = None }
  }
;;

(* Write-boundary invariant: a terminal [Dead_tombstone] latch must co-occur
   with [paused = true]. The canonical setter ([dead_tombstone_meta]) pairs
   them, and every sanctioned clear runs through [mark_resumed] / dead
   revival which nulls the latch. [paused = false] while [Dead_tombstone] is
   latched is un-recoverable: lifecycle admission denies by the latch alone
   (paused-independent), yet the split can only be produced by a writer that
   cleared [paused] without clearing the latch. Returns [Some detail] when the
   split is present so the store can reject the write fail-closed rather than
   persist an unrepresentable state. Non-terminal latches with [paused = false]
   are left alone (admission treats them as [Active], so they are recoverable). *)
let dead_tombstone_pause_violation (m : keeper_meta) : string option =
  (* Exhaustive on [latched_reason] for the [paused = false] rows (no [_]
     catch-all): a future terminal latch variant must force a decision here
     rather than silently escaping the write-boundary guard. A non-terminal
     latch with [paused = false] is admission-[Active] (recoverable), so it is
     not a violation. [paused = true] is always consistent with any latch. *)
  match m.paused, m.latched_reason with
  | false, Some Keeper_latched_reason.Dead_tombstone ->
    Some
      (Printf.sprintf
         "keeper %s: paused=false with Dead_tombstone latch (resume must clear \
          the latch via mark_resumed / dead revival)"
         m.name)
  | false, (Some (Keeper_latched_reason.Operator_paused _) | None) -> None
  | true, _ -> None
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
    | None, _ -> Error (missing_required_sandbox_profile_error ~keeper_name:meta.name defaults)
  in
  match target_sandbox_profile with
  | Error _ as err -> err
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
          persona = apply_profile_default_opt defaults.persona_name meta.persona;
          proactive =
            { enabled =
                apply_profile_default defaults.proactive_enabled
                  Keeper_config.default_proactive_enabled
            };
          goal = apply_profile_default defaults.goal meta.goal;
          instructions =
            apply_profile_default defaults.instructions meta.instructions;
          autoboot_enabled =
            apply_profile_default defaults.autoboot_enabled
              meta.autoboot_enabled;
          mention_targets =
            (match defaults.mention_targets with
             | [] -> meta.mention_targets
             | targets -> targets);
          active_goal_ids =
            apply_profile_default defaults.active_goal_ids meta.active_goal_ids;
          sandbox_profile;
          sandbox_image =
            apply_profile_default_opt defaults.sandbox_image meta.sandbox_image;
          network_mode;
          (* RFC vision-delegation §2.4: TOML profile overrides the carried
             value; absent -> keep [meta]'s (defaults to Inherit). *)
          multimodal_policy =
            apply_profile_default defaults.multimodal_policy meta.multimodal_policy;
          allowed_paths =
            apply_profile_default defaults.allowed_paths
              (if has_profile_source then [] else meta.allowed_paths);
          telemetry_feedback_enabled =
            apply_profile_default_opt defaults.telemetry_feedback_enabled
              meta.telemetry_feedback_enabled;
          telemetry_feedback_window_hours =
            apply_profile_default_opt defaults.telemetry_feedback_window_hours
              meta.telemetry_feedback_window_hours;
          always_allow =
            apply_profile_default_opt defaults.always_allow
              meta.always_allow;
          oas_env =
            (match defaults.oas_env with
             | [] -> meta.oas_env
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

(* persona⊥{model,runtime}: a keeper's runtime is assigned in runtime.toml
   ([[runtime.assignments]], the sole SSOT), keyed by keeper name — NOT read
   from the persona profile [model] field. An unassigned keeper falls to the
   default runtime (the designed fallback; RFC-0206 §2.1 fail-fast still applies
   to the default itself). The id is opaque here; only the OAS adapter parses
   it. *)
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

let now_iso () = Masc_domain.now_iso ()

let map_runtime (f : agent_runtime_state -> agent_runtime_state) (m : keeper_meta)
  : keeper_meta
  =
  { m with runtime = f m.runtime }
;;

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
  ; last_latency_ms = 0
  }
;;

let reset_runtime_state (m : keeper_meta) : keeper_meta =
  map_usage (fun _ -> zero_usage) m
;;

let map_compaction_rt (f : compaction_runtime -> compaction_runtime) (m : keeper_meta)
  : keeper_meta
  =
  { m with runtime = { m.runtime with compaction_rt = f m.runtime.compaction_rt } }
;;

let map_proactive_rt (f : proactive_runtime -> proactive_runtime) (m : keeper_meta)
  : keeper_meta
  =
  { m with runtime = { m.runtime with proactive_rt = f m.runtime.proactive_rt } }
;;

let removed_keeper_model_arg_names = [ "models"; "allowed_models"; "active_model" ]

let reject_removed_model_args ~tool_name (args : Yojson.Safe.t) =
  let present =
    removed_keeper_model_arg_names
    |> List.filter (fun key ->
      (* A legacy arg counts as "present" only when supplied with a real value.
         [assoc_member_opt] returns [None] for an absent key; the prior
         [| _ -> true] arm classified that [None] as present, so a request
         that simply omitted all three keys (e.g. the [{name}] used by base
         autoboot materialization) was rejected as if it had passed them.
         Absent ([None]) and explicit-null are both "not supplied". *)
      match Json_util.assoc_member_opt key args with
      | None | Some `Null -> false
      | Some _ -> true)
  in
  match present with
  | [] -> Ok ()
  | fields ->
    Error
      (Printf.sprintf
         "removed keeper model args for %s: %s. Use runtime_id; concrete \
          provider/model identity is resolved from the default runtime."
         tool_name
         (String.concat ", " fields))
;;
