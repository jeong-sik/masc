(** Keeper meta policy/runtime contract and pure helpers.

    Included by [Keeper_types] so existing [Keeper_types.*] callers keep
    their public API while the type-heavy contract is separated from JSON
    parsing and store I/O. *)

open Keeper_types_profile
include Keeper_meta_tool_access
include Keeper_meta_contract_types

type keeper_meta =
  { (* -- Identity & profile -- *)
    id : Ids.Keeper_id.t option [@default None]
  ; name : string
  ; agent_name : string
  ; goal : string
  ; short_goal : string
  ; mid_goal : string
  ; long_goal : string
  ; social_model : string
  ; models : string list
  ; cascade_ref : Cascade_ref.cascade_ref option
  ; will : string
  ; needs : string
  ; desires : string
  ; instructions : string
  ; (* -- Policy -- *)
    sandbox_profile : sandbox_profile
  ; sandbox_image : string option
  ; network_mode : network_mode
  ; allowed_paths : string list
  ; tool_access : tool_access
  ; tool_preset_source : string option
  ; tool_denylist : string list
  ; mention_targets : string list
  ; room_signal_prompt_enabled : bool
  ; joined_room_ids : string list
  ; last_seen_seq_by_room : (string * int) list
  ; proactive : proactive_policy
  ; compaction : compaction_policy
  ; auto_handoff : bool
  ; handoff_threshold : float
  ; handoff_cooldown_sec : int
  ; (* -- Lifecycle -- *)
    created_at : string
  ; updated_at : string
  ; (* -- Performance & Limits -- *)
    max_context_override : int option
  ; (* -- Operational control (top-level, not runtime) -- *)
    continuity_summary : string
  ; active_goal_ids : string list
  ; paused : bool
  ; auto_resume_after_sec : float option
    (** Self-healing circuit breaker: when [Some sec] the supervisor will
        auto-resume this keeper after [sec] seconds following the last
        [updated_at] timestamp recorded at auto-pause time.  Doubles on
        each successive auto-pause (exponential back-off), capped at
        [Env_config.KeeperSupervisor.auto_resume_max_sec].  Reset to
        [None] after a successful turn so a healthy run re-arms the
        initial delay.  [None] = operator-owned pause, no auto-resume. *)
  ; autoboot_enabled : bool
  ; current_task_id : Keeper_id.Task_id.t option
    (** Currently claimed task ID for cost attribution.
      Set when keeper claims a task; cleared on masc_transition action=done.
      Propagated to trajectory accumulator for per-task cost tracking. *)
  ; work_discovery_enabled : bool option
  ; work_discovery_sources : string list option
  ; work_discovery_interval_sec : int option
  ; work_discovery_guidance : string option
  ; telemetry_feedback_enabled : bool option
  ; telemetry_feedback_window_hours : int option
  ; per_provider_timeout_s : float option
  ; always_approve : bool option
  ; (* -- Agent runtime state (usage, tracing, autonomy metrics) -- *)
    runtime : agent_runtime_state
  ; (* -- Identity & concurrency -- *)
    keeper_id : Keeper_id.Uid.t option
  ; oas_env : (string * string) list
  ; meta_version : int
  }

let cascade_name_of_meta (m : keeper_meta) : string =
  match m.cascade_ref with
  | Some ref_ -> Cascade_name.to_string ref_.Cascade_ref.group
  | _ -> (Keeper_config.default_cascade_name ())
;;

let set_cascade_name (name : string) (m : keeper_meta) : keeper_meta =
  match Cascade_name.of_string name with
  | Ok group ->
    { m with cascade_ref = Some Cascade_ref.{ group; item = None } }
  | Error (`Invalid_prefix | `Empty) ->
    (* Non-canonical cascade name — keep existing cascade_ref unchanged *)
    m
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

(* -- Updater helpers for nested record updates -- *)

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
  ; last_model_used = ""
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

let map_scheduled_autonomous_rt = map_proactive_rt
let now_iso () = Masc_domain.now_iso ()
let keeper_legacy_model_arg_names = [ "models"; "allowed_models"; "active_model" ]

let reject_legacy_model_args ~tool_name (args : Yojson.Safe.t) =
  let present =
    keeper_legacy_model_arg_names
    |> List.filter (fun key ->
      match Yojson.Safe.Util.member key args with
      | `Null -> false
      | _ -> true)
  in
  match present with
  | [] -> Ok ()
  | fields ->
    Error
      (Printf.sprintf
         "legacy keeper model args removed for %s: %s. Use cascade_name; concrete \
          provider/model identity is OAS-owned."
         tool_name
         (String.concat ", " fields))
;;
