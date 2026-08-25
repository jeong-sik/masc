(** Keeper status bridge helpers. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile


let auto_execution_session_surface_json () =
  `Assoc [ "status", `String "removed"; "enabled", `Bool false ]
;;

let workspace_surface_json (meta : keeper_meta) =
  `Assoc
    [ "mention_targets", Json_util.json_string_list meta.mention_targets
    ]
;;

let effective_declarative_runtime_id
      (_defaults : keeper_profile_defaults)
      (meta : keeper_meta)
  =
  (* The keeper's runtime is assigned in runtime.toml,
     not in [_defaults].  Delegate to
     {!Keeper_meta_contract.runtime_id_of_meta} (the dispatcher), matching the
     keeper_runtime.ml copy, so the status override view and the wire share ONE
     source by construction (no re-sync storm, cf. #10061). *)
  runtime_id_of_meta meta
;;

type override_field_detail =
  Keeper_status_bridge_override.override_field_detail =
  { field : string
  ; default_value : Yojson.Safe.t
  ; live_value : Yojson.Safe.t
  }

let override_field = Keeper_status_bridge_override.override_field
let maybe_string_override = Keeper_status_bridge_override.maybe_string_override
let maybe_bool_override = Keeper_status_bridge_override.maybe_bool_override
let nonempty_string_list_override =
  Keeper_status_bridge_override.nonempty_string_list_override
let live_override_details (meta : keeper_meta) (defaults : keeper_profile_defaults)
  : override_field_detail list
  =
  let default_string default live =
    match default with
    | Some value when String.trim live = "" -> value
    | _ -> live
  in
  let default_nonempty_string_list default live =
    match default, live with
    | values, [] when values <> [] -> values
    | _, values -> values
  in
  let effective_runtime_id = effective_declarative_runtime_id defaults meta in
  []
  |> maybe_string_override
       "prompt.instructions"
       defaults.instructions
       (default_string defaults.instructions meta.instructions)
  |> nonempty_string_list_override
       "workspace.mention_targets"
       defaults.mention_targets
       (default_nonempty_string_list defaults.mention_targets meta.mention_targets)
  |> (fun acc ->
  let runtime_id = runtime_id_of_meta meta in
  if effective_runtime_id <> runtime_id
  then
    override_field
      "model.runtime_id"
      ~default_value:(`String effective_runtime_id)
      ~live_value:(`String runtime_id)
    :: acc
  else acc)
  |> maybe_bool_override
       "proactive.enabled"
       defaults.proactive_enabled
       meta.proactive.enabled
  |> List.rev
;;

let live_override_fields (meta : keeper_meta) (defaults : keeper_profile_defaults)
  : string list
  =
  live_override_details meta defaults |> List.map (fun detail -> detail.field)
;;

let runtime_registry_entry (config : Workspace_utils.config) name =
  Keeper_registry.get ~base_path:config.base_path name
;;

let runtime_keepalive_running (config : Workspace_utils.config) (meta : keeper_meta) =
  Keeper_registry.is_running ~base_path:config.base_path meta.name
;;

let runtime_keepalive_started_at (config : Workspace_utils.config) (meta : keeper_meta) =
  Keeper_registry.started_at ~base_path:config.base_path meta.name
;;

(* ── Structured blocker classification ──────────────────────── *)
(* Types blocker_class, runtime_exhaustion_reason, blocker_class_to_string,
   and runtime_exhaustion_summary
   are defined in Keeper_types (keeper_types.ml). *)


include Keeper_status_bridge_blocker


let runtime_blocker_surface_opt (config : Workspace_utils.config) (meta : keeper_meta) =
  (* The registry is the only writer of a runtime blocker; the meta field that
     used to shadow it was written on one failure path and cleared on the next
     success, so it reported a past instant as a present state. *)
  (match runtime_registry_entry config meta.name with
     | Some entry ->
       (match entry.last_failure_reason with
        | Some reason -> runtime_blocker_surface_of_failure_reason reason
        | None -> None)
     | None -> None)
;;

let runtime_attempt_outcome_json = function
  | `Success -> `Assoc [ "kind", `String "success"; "detail", `Null ]
  | `Failure detail ->
    `Assoc [ "kind", `String "failure"; "detail", `String detail ]
;;

let runtime_attempt_record_json (attempt : runtime_attempt_record) =
  `Assoc
    [ "provider_id", `String attempt.provider_id
    ; "http_status", Json_util.int_opt_to_json attempt.http_status
    ; "outcome", runtime_attempt_outcome_json attempt.outcome
    ; "timestamp_unix", `Float attempt.timestamp
    ]
;;

let last_runtime_attempt_json (meta : keeper_meta) =
  match meta.runtime.last_runtime_attempt with
  | None -> `Null
  | Some attempt -> runtime_attempt_record_json attempt
;;

let runtime_blocker_facts_json (meta : keeper_meta) =
  `Assoc
    [ "source", `String "keeper_runtime.last_runtime_attempt"
    ; "runtime_id", `String (runtime_id_of_meta meta)
    ; "last_runtime_attempt", last_runtime_attempt_json meta
    ]
;;

let runtime_blocker_fields_json (config : Workspace_utils.config) (meta : keeper_meta) =
  match runtime_blocker_surface_opt config meta with
  | Some blocker ->
    [ "runtime_blocker_class", `String blocker.blocker_class
    ; "runtime_blocker_summary", `String blocker.summary
    ; "runtime_blocker_facts", runtime_blocker_facts_json meta
    ]
  | None ->
    [ "runtime_blocker_class", `Null
    ; "runtime_blocker_summary", `Null
    ; "runtime_blocker_facts", `Null
    ]
;;

let runtime_state_fields_json (config : Workspace_utils.config) (meta : keeper_meta) =
  let runtime_blocker = runtime_blocker_surface_opt config meta in
  let pause_state = if meta.paused then "paused" else "active" in
  let blocker_state =
    match runtime_blocker with
    | Some _ -> "blocked"
    | None -> "clear"
  in
  [ "pause_state", `String pause_state; "runtime_blocker_state", `String blocker_state ]
;;

type approval_queue_attention =
  | Approval_queue_ready of int
  | Approval_queue_unavailable of Keeper_approval_queue.storage_error

let attention_fields_json_with_approval_queue
      (config : Workspace_utils.config)
      (meta : keeper_meta)
      approval_queue
  =
  let runtime_blocker = runtime_blocker_surface_opt config meta in
  let needs_attention, attention_reason, next_human_action =
    match approval_queue with
    | Approval_queue_unavailable _ ->
      true, Some "approval_queue_unavailable", Some "reset_runtime_state"
    | Approval_queue_ready pending_approval_count when pending_approval_count > 0 ->
      true, Some "approval_pending", Some "resolve_approval"
    | Approval_queue_ready _ ->
      match runtime_blocker with
      | Some _ when meta.paused ->
        true, Some "paused", Some "inspect_blocker_before_resume"
      | Some blocker when is_runtime_exhausted_blocker_class blocker.blocker_class ->
        true, Some "runtime_attempts_exhausted", Some "inspect_runtime_attempts"
      | Some blocker when is_provider_runtime_blocker_class blocker.blocker_class ->
        true, Some "provider_runtime_error", Some "inspect_provider_runtime_cause"
      | Some blocker when is_fiber_unresolved_blocker_class blocker.blocker_class ->
        true, Some "fiber_unresolved", Some "inspect_turn_finalization"
      | Some _ -> true, Some "runtime_blocked", Some "inspect_runtime_blocker"
      | None when meta.paused -> true, Some "paused", Some "resume_or_review"
      | None -> false, None, None
  in
  let approval_queue_state, pending_approval_count =
    match approval_queue with
    | Approval_queue_ready count ->
      Keeper_approval_queue.approval_queue_ready_state_json, `Int count
    | Approval_queue_unavailable error ->
      ( Keeper_approval_queue.approval_queue_unavailable_state_json error
      , `Null )
  in
  [ "needs_attention", `Bool needs_attention
  ; "attention_reason", Json_util.string_opt_to_json attention_reason
  ; "next_human_action", Json_util.string_opt_to_json next_human_action
  ; "approval_queue_state", approval_queue_state
  ; "pending_approval_count", pending_approval_count
  ; (* Typed pause reason surfaced as its stable wire form. [attention_reason]
       above collapses every pause to the single label "paused"; this field
       preserves {i why} the keeper is latched (operator pause, dead
       tombstone, runtime latch, …) for the dashboard. [`Null] when no reason
       was recorded. *)
    ( "latched_reason"
    , match meta.latched_reason with
      | Some reason -> `String (Keeper_latched_reason.to_wire reason)
      | None -> `Null )
  ]
;;

let attention_fields_json (config : Workspace_utils.config) (meta : keeper_meta) =
  let approval_queue =
    match
      Keeper_approval_queue.pending_count_for_keeper_in_workspace
        ~base_path:config.base_path
        ~keeper_name:meta.name
    with
    | Ok count -> Approval_queue_ready count
    | Error error -> Approval_queue_unavailable error
  in
  attention_fields_json_with_approval_queue config meta approval_queue
;;

let json_string_opt_member = Json_util.get_string_nonempty
;;

let assoc_upsert fields key value =
  let rec loop acc = function
    | [] -> List.rev ((key, value) :: acc)
    | (existing_key, _) :: rest when String.equal existing_key key ->
      List.rev_append acc ((key, value) :: rest)
    | field :: rest -> loop (field :: acc) rest
  in
  loop [] fields
;;

let attention_fields_with_runtime_trust attention_fields runtime_trust =
  let existing_needs_attention =
    match List.assoc_opt "needs_attention" attention_fields with
    | Some (`Bool value) -> value
    | _ -> false
  in
  let trust_needs_attention =
    Safe_ops.json_bool_opt "needs_attention" runtime_trust |> Option.value ~default:false
  in
  if existing_needs_attention || not trust_needs_attention
  then attention_fields
  else (
    let attention_reason =
      match List.assoc_opt "attention_reason" attention_fields with
      | Some (`String value) when String.trim value <> "" -> Some value
      | _ ->
        (match json_string_opt_member runtime_trust "attention_reason" with
         | Some _ as value -> value
         | None -> json_string_opt_member runtime_trust "disposition_reason")
    in
    let next_human_action =
      match List.assoc_opt "next_human_action" attention_fields with
      | Some (`String value) when String.trim value <> "" -> Some value
      | _ ->
        (match json_string_opt_member runtime_trust "next_human_action" with
         | Some _ as value -> value
         | None ->
           (match json_string_opt_member runtime_trust "latest_next_action" with
            | Some _ as value -> value
            | None -> Some "inspect_keeper_runtime_trust"))
    in
    let attention_fields = assoc_upsert attention_fields "needs_attention" (`Bool true) in
    let attention_fields =
      assoc_upsert
        attention_fields
        "attention_reason"
        (Json_util.string_opt_to_json attention_reason)
    in
    assoc_upsert
      attention_fields
      "next_human_action"
      (Json_util.string_opt_to_json next_human_action))
;;

let runtime_surface_json config (meta : keeper_meta) =
  let keepalive_running = runtime_keepalive_running config meta in
  let fiber_health =
    match Keeper_registry.fiber_health_of ~base_path:config.base_path meta.name with
    | Fiber_unknown when keepalive_running -> Fiber_alive
    | health -> health
  in
  let phase =
    match runtime_registry_entry config meta.name with
    | Some entry -> Some (Keeper_state_machine.phase_to_string entry.phase)
    | None -> None
  in
  (* [phase] above is the Keeper lifecycle; this is the shutdown operation's
     own phase, a different axis. A Keeper can read Stopped while its
     operation still sits in Finalizing_tasks or Cleanup_ready, and those are
     outside the supersedable set, so a restart is refused there (#29181).
     Latest revision wins: earlier records are superseded history. *)
  let shutdown_operation_phase =
    match
      Keeper_shutdown_store.list_for_keeper ~config ~keeper_name:meta.name
    with
    | Error _ | Ok [] -> None
    | Ok (first :: rest) ->
      let latest =
        List.fold_left
          (fun (acc : Keeper_shutdown_types.t) (candidate : Keeper_shutdown_types.t) ->
             if candidate.revision > acc.revision then candidate else acc)
          first
          rest
      in
      Some (Keeper_shutdown_types.phase_to_string latest.phase)
  in
  (* The phase name alone does not answer whether a restart is admitted:
     [Finalized] splits on its completion field — Completion_pending still
     fences, Completion_not_requested and Completion_delivered do not
     (keeper_shutdown_types.ml:200). This is the predicate the admission
     preflight actually consults, so a consumer waiting to restart reads
     this, not the name (#29181). *)
  let shutdown_admission_fence =
    match
      Keeper_shutdown_store.list_for_keeper ~config ~keeper_name:meta.name
    with
    | Error _ | Ok [] -> None
    | Ok operations ->
      Some
        (List.exists Keeper_shutdown_types.requires_admission_fence operations)
  in
  `Assoc
    ([ "paused", `Bool meta.paused
     ; "keepalive_running", `Bool keepalive_running
     ; ( "phase", Json_util.string_opt_to_json phase )
     ; ( "shutdown_operation_phase"
       , Json_util.string_opt_to_json shutdown_operation_phase )
     ; ( "shutdown_admission_fence"
       , match shutdown_admission_fence with
         | None -> `Null
         | Some fenced -> `Bool fenced )
     ; "fiber_health", `String (Keeper_status_runtime.string_of_fiber_health fiber_health)
     ; "last_runtime_attempt", last_runtime_attempt_json meta
     ]
     @ runtime_state_fields_json config meta
     @ runtime_blocker_fields_json config meta
     @ attention_fields_json config meta)
;;

let existing_path_json ?source path =
  let fields = [ "path", `String path; "exists", `Bool (Fs_compat.file_exists path) ] in
  let fields =
    match source with
    | Some value -> ("source", `String value) :: fields
    | None -> fields
  in
  `Assoc (List.rev fields)
;;

let optional_existing_path_json ?source = function
  | Some path -> existing_path_json ?source path
  | None -> `Null
;;

(* RFC-0058 §9 Phase 9.3: on-disk runtime JSON is no longer generated or
   consumed. [runtime_runtime_json_path] / [runtime_runtime_json_editable]
   dropped from the status payload because there is no runtime JSON
   sibling to point at. Source identity is now fully described by the
   TOML path + the single-arm [source_kind]. *)
let override_field_source_json ~default_source_kind ~default_manifest_path detail =
  let default_missing =
    match detail.default_value with
    | `Null -> true
    | _ -> false
  in
  let default_manifest_exists =
    match default_manifest_path with
    | Some path -> Fs_compat.file_exists path
    | None -> false
  in
  `Assoc
    [ "field", `String detail.field
    ; "source", `String "live_meta"
    ; "live_source", `String "runtime_overlay"
    ; "default_source", Json_util.string_opt_to_json default_source_kind
    ; "default_source_kind", Json_util.string_opt_to_json default_source_kind
    ; "default_manifest_path", Json_util.string_opt_to_json default_manifest_path
    ; "default_manifest_exists", `Bool default_manifest_exists
    ; "default_missing", `Bool default_missing
    ; "default_value", detail.default_value
    ; "live_value", detail.live_value
    ]
;;

let source_provenance_json config (meta : keeper_meta) =
  let snapshot =
    keeper_default_source_snapshot ~base_path:config.Workspace.base_path meta.name
  in
  let override_details = live_override_details meta snapshot.defaults in
  let override_fields = List.map (fun detail -> detail.field) override_details in
  let resolution =
    Config_dir_resolver.resolve_for_base_path ~base_path:config.Workspace.base_path
  in
  let live_meta_path = keeper_meta_path config meta.name in
  let default_manifest_path = snapshot.defaults.manifest_path in
  let default_source_kind = snapshot.source_kind in
  let default_config_error =
    Option.map
      (Keeper_types_profile.keeper_toml_config_error_of_load_error
         ~keeper_name:meta.name)
      snapshot.config_error
  in
  `Assoc
    ([ "live_meta_path", `String live_meta_path
     ; "live_meta", existing_path_json ~source:"runtime_overlay" live_meta_path
     ; "default_manifest_path", Json_util.string_opt_to_json default_manifest_path
     ; ( "default_manifest"
       , optional_existing_path_json ?source:default_source_kind default_manifest_path )
     ; "default_source_kind", Json_util.string_opt_to_json default_source_kind
     ; ( "default_config_error"
       , Json_util.option_to_yojson
           Keeper_types_profile.keeper_toml_config_error_to_json
           default_config_error )
     ; "active_config_root", `String resolution.config_root.path
     ; ( "active_config_root_source"
       , `String (Config_dir_resolver.source_to_string resolution.config_root.source) )
     ; "config_resolution", Config_dir_resolver.to_json resolution
     ; "precedence", `List [ `String "live_meta"; `String "keeper_config" ]
     ]
     @ [ "has_live_override", `Bool (override_fields <> [])
       ; "override_fields", Json_util.json_string_list override_fields
       ; ( "override_field_sources"
         , `List
             (List.map
                (override_field_source_json ~default_source_kind ~default_manifest_path)
                override_details) )
       ])
;;
