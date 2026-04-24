(** Keeper meta policy/runtime contract and pure helpers.

    Included by [Keeper_types] so existing [Keeper_types.*] callers keep
    their public API while the type-heavy contract is separated from JSON
    parsing and store I/O. *)

open Keeper_types_profile

(* -- Policy types (remain in keeper_meta top-level) -- *)

type compaction_policy =
  { profile : string
  ; ratio_gate : float
  ; message_gate : int
  ; token_gate : int
  ; cooldown_sec : int
  ; max_checkpoint_messages : int
  }

type proactive_policy =
  { enabled : bool
  ; idle_sec : int
  ; cooldown_sec : int
  }

type scheduled_autonomous_policy = proactive_policy

type proactive_cycle_outcome =
  | Proactive_never_started
  | Proactive_unknown
  | Proactive_silent
  | Proactive_text_response
  | Proactive_tool_use
  | Proactive_mixed_response
  | Proactive_error

type scheduled_autonomous_cycle_outcome = proactive_cycle_outcome

type tool_preset =
  | Minimal
  | Social
  | Messaging
  | Dispatch
  | Coding
  | Research
  | Delivery
  | Full

type tool_access =
  | Preset of
      { preset : tool_preset
      ; also_allow : string list
      }
  | Custom of string list

let tool_names_include_board name_list =
  List.exists
    (fun name ->
       String.starts_with ~prefix:"keeper_board_" name
       || String.starts_with ~prefix:"masc_board_" name)
    name_list

let tool_access_default_room_signal_prompt_enabled ~default = function
  | Preset { preset = Minimal; also_allow } ->
      default || tool_names_include_board also_allow
  | Preset _ -> true
  | Custom tool_names -> tool_names_include_board tool_names

(* -- Runtime types (moved into agent_runtime_state) -- *)

type compaction_runtime =
  { count : int
  ; last_ts : float
  ; last_before_tokens : int
  ; last_after_tokens : int
  ; last_check_ts : float
  ; last_decision : string
  }

type proactive_runtime =
  { count_total : int
  ; last_ts : float
  ; visible_count_total : int
  ; last_visible_ts : float
  ; last_outcome : proactive_cycle_outcome
  ; last_reason : string
  ; last_preview : string
  ; last_work_discovery_ts : float
  ; work_discovery_count : int
  ; consecutive_noop_count : int
      (** Consecutive autonomous cycles where only observation tools
          (board_list, stay_silent, context_status) were used with no
          substantive action.  Resets to 0 on any productive cycle.
          Used by [effective_scheduled_autonomous_cooldown] for exponential
          backoff: cooldown *= 2^min(n, 3), capping at 8x. *)
  }

type scheduled_autonomous_runtime = proactive_runtime

(* ── Structured blocker classification ──────────────────────── *)

type cascade_exhaustion_reason =
  | Connection_refused
  | No_providers_available
  | All_providers_failed
  | Candidates_filtered_after_cycles
  | Other_detail of string

type blocker_class =
  | Cascade_exhausted of cascade_exhaustion_reason
  | Ambiguous_post_commit_timeout
  | Ambiguous_post_commit_failure
  | Autonomous_slot_wait_timeout
  | Admission_queue_wait_timeout
  | Turn_timeout_after_queue_wait
  | Oas_timeout_budget
  | Turn_timeout
  | Completion_contract_violation
  | No_tool_capable_provider

let blocker_class_to_string = function
  | Cascade_exhausted _ -> "cascade_exhausted"
  | Ambiguous_post_commit_timeout -> "ambiguous_post_commit_timeout"
  | Ambiguous_post_commit_failure -> "ambiguous_post_commit_failure"
  | Autonomous_slot_wait_timeout -> "autonomous_slot_wait_timeout"
  | Admission_queue_wait_timeout -> "admission_queue_wait_timeout"
  | Turn_timeout_after_queue_wait -> "turn_timeout_after_queue_wait"
  | Oas_timeout_budget -> "oas_timeout_budget"
  | Turn_timeout -> "turn_timeout"
  | Completion_contract_violation -> "completion_contract_violation"
  | No_tool_capable_provider -> "no_tool_capable_provider"

let blocker_class_of_serialized_string = function
  | "cascade_exhausted" -> Some (Cascade_exhausted (Other_detail "cascade_exhausted"))
  | "ambiguous_post_commit_timeout" -> Some Ambiguous_post_commit_timeout
  | "ambiguous_post_commit_failure" -> Some Ambiguous_post_commit_failure
  | "autonomous_slot_wait_timeout" -> Some Autonomous_slot_wait_timeout
  | "admission_queue_wait_timeout" -> Some Admission_queue_wait_timeout
  | "turn_timeout_after_queue_wait" -> Some Turn_timeout_after_queue_wait
  | "oas_timeout_budget" -> Some Oas_timeout_budget
  | "turn_timeout" -> Some Turn_timeout
  | "completion_contract_violation" -> Some Completion_contract_violation
  | "no_tool_capable_provider" -> Some No_tool_capable_provider
  | _ -> None

let cascade_exhaustion_summary = function
  | Connection_refused ->
      "Cascade exhausted after provider failures; local runtime connection refused."
  | No_providers_available ->
      "Cascade exhausted; no providers were available."
  | All_providers_failed ->
      "Cascade exhausted after all configured providers failed."
  | Candidates_filtered_after_cycles ->
      "Cascade exhausted after provider failures."
  | Other_detail _ ->
      "Cascade exhausted after provider failures."

let blocker_class_continue_gate = function
  | Ambiguous_post_commit_timeout | Ambiguous_post_commit_failure -> true
  | _ -> false

let cascade_exhaustion_reason_to_json = function
  | Connection_refused -> `String "connection_refused"
  | No_providers_available -> `String "no_providers_available"
  | All_providers_failed -> `String "all_providers_failed"
  | Candidates_filtered_after_cycles -> `String "candidates_filtered_after_cycles"
  | Other_detail msg ->
      `Assoc [("tag", `String "other_detail"); ("message", `String msg)]

let cascade_exhaustion_reason_of_json = function
  | `String "connection_refused" -> Some Connection_refused
  | `String "no_providers_available" -> Some No_providers_available
  | `String "all_providers_failed" -> Some All_providers_failed
  | `String "candidates_filtered_after_cycles" ->
      Some Candidates_filtered_after_cycles
  | `Assoc fields ->
      (match List.assoc_opt "tag" fields with
       | Some (`String "other_detail") ->
           (match List.assoc_opt "message" fields with
            | Some (`String msg) -> Some (Other_detail msg)
            | _ -> None)
       | _ -> None)
  | _ -> None

type usage_metrics =
  { total_turns : int
  ; total_input_tokens : int
  ; total_output_tokens : int
  ; total_tokens : int
  ; total_cost_usd : float
  ; last_turn_ts : float
  ; last_model_used : string
  ; last_input_tokens : int
  ; last_output_tokens : int
  ; last_total_tokens : int
  ; last_latency_ms : int
  }

type agent_runtime_state =
  { usage : usage_metrics
  ; compaction_rt : compaction_runtime
  ; proactive_rt : proactive_runtime
  ; generation : int
  ; trace_id : Keeper_id.Trace_id.t
  ; trace_history : string list
  ; last_handoff_ts : float
  ; last_continuity_update_ts : float
  ; last_autonomous_action_at : string
  ; autonomous_action_count : int
  ; autonomous_turn_count : int
  ; autonomous_text_turn_count : int
  ; autonomous_tool_turn_count : int
  ; board_reactive_turn_count : int
  ; mention_reactive_turn_count : int
  ; noop_turn_count : int
  ; consecutive_noop_count : int
  ; last_speech_act : string
  ; last_social_transition_reason : string
  ; last_active_desire : string
  ; last_current_intention : string
  ; last_blocker : string
  ; last_blocker_class : blocker_class option
  ; last_need : string
  }

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
  ; cascade_name : string
  ; models : string list
  ; will : string
  ; needs : string
  ; desires : string
  ; instructions : string
  ; (* -- Policy -- *)
    policy_voice_enabled : bool
  ; sandbox_profile : sandbox_profile
  ; network_mode : network_mode
  ; shared_memory_scope : shared_memory_scope
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
  ; (* -- Voice -- *)
    voice_enabled : bool
  ; voice_channel : string
  ; voice_agent_id : string
  ; (* -- Lifecycle -- *)
    created_at : string
  ; updated_at : string
  ; (* -- Performance & Limits -- *)
    max_context_override : int option
  ; (* -- Operational control (top-level, not runtime) -- *)
    continuity_summary : string
  ; active_goal_ids : string list
  ; paused : bool
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

let normalize_tool_names names =
  names
  |> List.map String.trim
  |> List.filter (fun name -> name <> "")
  |> dedupe_keep_order
;;

let legacy_keeper_internal_tool_names =
  Tool_catalog.tools_for_surface Tool_catalog.Keeper_internal
;;

let legacy_session_min_tool_names =
  (* Legacy keepers historically received canonical masc_* coordination tools,
     not the SDK alias-heavy Session_min surface. Keep this compatibility list
     explicit so missing tool_access migration remains stable after tier removal. *)
  List.map Tool_name.Masc.to_string
    Tool_name.Masc.[
      Status;
      Tasks;
      Claim_next;
      Plan_set_task;
      Transition;
      Add_task;
      Broadcast;
    ]

let migrate_legacy_restricted_tools names =
  Custom (normalize_tool_names (legacy_keeper_internal_tool_names @ names))
;;

let tool_preset_to_string = function
  | Minimal -> "minimal"
  | Social -> "social"
  | Messaging -> "messaging"
  | Dispatch -> "dispatch"
  | Coding -> "coding"
  | Research -> "research"
  | Delivery -> "delivery"
  | Full -> "full"
;;

(** Issue #8430: schema enums for [tool_preset] in [keeper_schema.ml]
    used to be hand-rolled and dropped [Social] and [Delivery] — a live
    correctness bug since callers reading the schema could not discover
    those values exist. Same Variant SSOT class as #8354 / #8392. All
    constructors are nullary so the simple [List.map] trick works.
    Adding an 8th constructor will fail compilation in
    [tool_preset_to_string] and in the witness test. *)
let all_tool_presets =
  [ Minimal; Social; Messaging; Dispatch; Coding; Research; Delivery; Full ]
let valid_tool_preset_strings = List.map tool_preset_to_string all_tool_presets

let tool_preset_of_string raw =
  match String.trim (String.lowercase_ascii raw) with
  | "minimal" -> Some Minimal
  | "social" -> Some Social
  | "messaging" -> Some Messaging
  | "dispatch" -> Some Dispatch
  | "coding" -> Some Coding
  | "research" -> Some Research
  | "delivery" -> Some Delivery
  | "full" -> Some Full
  | _ -> None
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
    if proactive_cycle_outcome_of_string s <> v then
      invalid_arg
        (Printf.sprintf
           "keeper_types: proactive round-trip broken for label %S" s)
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

let scheduled_autonomous_cycle_outcome_to_string =
  proactive_cycle_outcome_to_string
;;

let scheduled_autonomous_cycle_outcome_of_string =
  proactive_cycle_outcome_of_string
;;

let normalize_tool_access = function
  | Preset { preset; also_allow } ->
    Preset { preset; also_allow = normalize_tool_names also_allow }
  | Custom names -> Custom (normalize_tool_names names)
;;

let tool_access_preset = function
  | Preset { preset; _ } -> Some preset
  | Custom _ -> None
;;

let tool_access_custom_allowlist = function
  | Preset _ -> None
  | Custom names -> Some names
;;

let tool_access_also_allowlist = function
  | Preset { also_allow; _ } -> also_allow
  | Custom _ -> []
;;

let tool_access_to_json access =
  match normalize_tool_access access with
  | Preset { preset; also_allow } ->
    `Assoc
      [ "kind", `String "preset"
      ; "preset", `String (tool_preset_to_string preset)
      ; "also_allow", `List (List.map (fun s -> `String s) also_allow)
      ]
  | Custom names ->
    `Assoc
      [ "kind", `String "custom"; "tools", `List (List.map (fun s -> `String s) names) ]
;;

let json_member_present key (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields -> List.mem_assoc key fields
  | _ -> false
;;

let string_list_field_result ?label ~field_name (json : Yojson.Safe.t) =
  let label = Option.value ~default:field_name label in
  match Yojson.Safe.Util.member field_name json with
  | `List items ->
    let rec collect acc index = function
      | [] -> Ok (List.rev acc)
      | `String value :: rest -> collect (value :: acc) (index + 1) rest
      | _ :: _ -> Error (Printf.sprintf "keeper %s[%d] must be a string" label index)
    in
    collect [] 0 items
  | `Null -> Error (Printf.sprintf "keeper %s must be an array of strings" label)
  | _ -> Error (Printf.sprintf "keeper %s must be an array of strings" label)
;;

let string_list_field_opt_result ?label ~field_name (json : Yojson.Safe.t) =
  match Yojson.Safe.Util.member field_name json with
  | `Null -> Ok []
  | _ -> string_list_field_result ?label ~field_name json
;;

let parse_tool_preset_projection (json : Yojson.Safe.t) =
  let preset_member = Yojson.Safe.Util.member "tool_preset" json in
  match preset_member with
  | `String raw ->
    (match tool_preset_of_string raw with
     | Some preset -> Ok preset
     | None -> Error (Printf.sprintf "invalid keeper tool_preset: %s" raw))
  | `Null -> Error "keeper tool_preset required"
  | _ -> Error "keeper tool_preset must be a string"
;;

let default_tool_access_of_meta_json () =
  migrate_legacy_restricted_tools legacy_session_min_tool_names
;;

let legacy_tool_access_projection_of_meta_json (json : Yojson.Safe.t) =
  let custom_present = json_member_present "tool_custom_allowlist" json in
  let preset_present = json_member_present "tool_preset" json in
  let also_allow_present = json_member_present "tool_also_allow" json in
  let legacy_allowlist_present = json_member_present "tool_allowlist" json in
  if custom_present
  then (
    match string_list_field_result ~field_name:"tool_custom_allowlist" json with
    | Ok tools -> Ok (normalize_tool_access (Custom tools))
    | Error msg -> Error msg)
  else if preset_present || also_allow_present
  then (
    match parse_tool_preset_projection json with
    | Error msg -> Error msg
    | Ok preset ->
      (match string_list_field_opt_result ~field_name:"tool_also_allow" json with
       | Ok also_allow -> Ok (normalize_tool_access (Preset { preset; also_allow }))
       | Error msg -> Error msg))
  else if legacy_allowlist_present
  then (
    match string_list_field_result ~field_name:"tool_allowlist" json with
    | Ok names -> Ok (migrate_legacy_restricted_tools names)
    | Error msg -> Error msg)
  else Ok (default_tool_access_of_meta_json ())
;;

let legacy_tool_access_of_meta_json (json : Yojson.Safe.t) =
  match Yojson.Safe.Util.member "tool_access" json with
  | `Null -> legacy_tool_access_projection_of_meta_json json
  | `Assoc _ as access_json ->
    let kind =
      Yojson.Safe.Util.member "kind" access_json |> Yojson.Safe.Util.to_string_option
    in
    (match kind with
     | Some "unrestricted" ->
       Ok (Preset { preset = Full; also_allow = [] } |> normalize_tool_access)
     | Some "restricted" ->
       (match
          string_list_field_opt_result
            ~field_name:"tools"
            ~label:"tool_access.tools"
            access_json
        with
        | Ok tools -> Ok (migrate_legacy_restricted_tools tools)
        | Error msg -> Error msg)
     | Some "preset" ->
       let preset_raw =
         Yojson.Safe.Util.member "preset" access_json |> Yojson.Safe.Util.to_string_option
       in
       (match preset_raw with
        | None -> Error "keeper tool_access.preset required"
        | Some raw ->
          (match tool_preset_of_string raw with
           | None -> Error (Printf.sprintf "invalid keeper tool_access.preset: %s" raw)
           | Some preset ->
             (match
                string_list_field_opt_result
                  ~field_name:"also_allow"
                  ~label:"tool_access.also_allow"
                  access_json
              with
              | Ok also_allow ->
                Ok (normalize_tool_access (Preset { preset; also_allow }))
              | Error msg -> Error msg)))
     | Some "custom" ->
       (match
          string_list_field_result
            ~field_name:"tools"
            ~label:"tool_access.tools"
            access_json
        with
        | Ok tools -> Ok (normalize_tool_access (Custom tools))
        | Error msg -> Error msg)
     | Some other -> Error (Printf.sprintf "invalid keeper tool_access.kind: %s" other)
     | None -> Error "keeper tool_access.kind required")
  | _ -> Error "keeper tool_access must be an object"
;;

let tool_access_of_meta_json (json : Yojson.Safe.t) =
  match Yojson.Safe.Util.member "tool_access" json with
  | `Null -> Ok (default_tool_access_of_meta_json ())
  | `Assoc _ as access_json ->
    let kind =
      Yojson.Safe.Util.member "kind" access_json |> Yojson.Safe.Util.to_string_option
    in
    (match kind with
     | Some "preset" ->
       let preset_raw =
         Yojson.Safe.Util.member "preset" access_json |> Yojson.Safe.Util.to_string_option
       in
       (match preset_raw with
        | None -> Error "keeper tool_access.preset required"
        | Some raw ->
          (match tool_preset_of_string raw with
           | None -> Error (Printf.sprintf "invalid keeper tool_access.preset: %s" raw)
           | Some preset ->
             (match
                string_list_field_opt_result
                  ~field_name:"also_allow"
                  ~label:"tool_access.also_allow"
                  access_json
              with
              | Ok also_allow ->
                Ok (normalize_tool_access (Preset { preset; also_allow }))
              | Error msg -> Error msg)))
     | Some "custom" ->
       (match
          string_list_field_result
            ~field_name:"tools"
            ~label:"tool_access.tools"
            access_json
        with
        | Ok tools -> Ok (normalize_tool_access (Custom tools))
        | Error msg -> Error msg)
     | Some other -> Error (Printf.sprintf "invalid keeper tool_access.kind: %s" other)
     | None -> Error "keeper tool_access.kind required")
  | _ -> Error "keeper tool_access must be an object"
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
  { total_turns = 0; total_input_tokens = 0; total_output_tokens = 0
  ; total_tokens = 0; total_cost_usd = 0.0; last_turn_ts = 0.0
  ; last_model_used = ""; last_input_tokens = 0; last_output_tokens = 0
  ; last_total_tokens = 0; last_latency_ms = 0 }

let reset_runtime_state (m : keeper_meta) : keeper_meta =
  map_usage (fun _ -> zero_usage) m

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

let map_scheduled_autonomous_rt =
  map_proactive_rt
;;

let now_iso () = Types.now_iso ()
let keeper_legacy_model_arg_names = [ "models"; "allowed_models"; "active_model" ]
