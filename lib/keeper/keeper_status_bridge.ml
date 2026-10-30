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
    ; "board_interests", Json_util.json_string_list meta.board_interests
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

let live_override_details (meta : keeper_meta) (defaults : keeper_profile_defaults)
  : Keeper_status_bridge_override.t list
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
  (* A list default of [] declares no preference, so it is never overridden. *)
  let differs_from_list_default default live = default <> [] && default <> live in
  let instructions =
    let live = default_string defaults.instructions meta.instructions in
    match defaults.instructions with
    | Some default when default <> live ->
      [ Keeper_status_bridge_override.Instructions { default; live } ]
    | Some _ | None -> []
  in
  let mention_targets =
    let default = defaults.mention_targets in
    let live = default_nonempty_string_list default meta.mention_targets in
    if differs_from_list_default default live
    then [ Keeper_status_bridge_override.Mention_targets { default; live } ]
    else []
  in
  let board_interests =
    let default = defaults.board_interests in
    let live = default_nonempty_string_list default meta.board_interests in
    if differs_from_list_default default live
    then [ Keeper_status_bridge_override.Board_interests { default; live } ]
    else []
  in
  let runtime_id =
    let default = effective_declarative_runtime_id defaults meta in
    let live = runtime_id_of_meta meta in
    if default <> live
    then [ Keeper_status_bridge_override.Runtime_id { default; live } ]
    else []
  in
  let activation_mode =
    let live = meta.activation_mode in
    match defaults.activation_mode with
    | Some default when default <> live ->
      [ Keeper_status_bridge_override.Activation_mode { default; live } ]
    | Some _ | None -> []
  in
  List.concat
    [ instructions; mention_targets; board_interests; runtime_id; activation_mode ]
;;

let live_override_fields (meta : keeper_meta) (defaults : keeper_profile_defaults)
  : string list
  =
  live_override_details meta defaults |> List.map Keeper_status_bridge_override.field_name
;;

let runtime_registry_entry (config : Workspace_utils.config) name =
  Keeper_registry.get ~base_path:config.base_path name
;;

let runtime_phase (config : Workspace_utils.config) (meta : keeper_meta) =
  Keeper_registry.get_phase ~base_path:config.base_path meta.name
;;

let runtime_keepalive_running (config : Workspace_utils.config) (meta : keeper_meta) =
  Keeper_status_runtime.keepalive_running_of_phase (runtime_phase config meta)
;;

let runtime_keepalive_started_at (config : Workspace_utils.config) (meta : keeper_meta) =
  Keeper_registry.started_at ~base_path:config.base_path meta.name
;;

(* ── Structured blocker classification ──────────────────────── *)
(* The runtime blocker surface and its class are defined in
   [Keeper_status_bridge_blocker]. *)


include Keeper_status_bridge_blocker


let runtime_blocker_surface_opt (config : Workspace_utils.config) (meta : keeper_meta) =
  (* The registry is the only writer of a runtime blocker; the meta field that
     used to shadow it was written on one failure path and cleared on the next
     success, so it reported a past instant as a present state. *)
  (match runtime_registry_entry config meta.name with
     | Some entry ->
       (match entry.last_failure_reason with
        | Some reason ->
          runtime_blocker_surface_of_failure_reason
            ~latest_receipt:(fun () ->
              Keeper_execution_receipt.read_latest_receipt config meta.name)
            reason
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

let runtime_blocker_fields_json_of_surface (meta : keeper_meta) = function
  | Some blocker ->
    [ "runtime_blocker_class", `String (runtime_blocker_class_to_string blocker.blocker_class)
    ; "runtime_blocker_summary", `String (Lazy.force blocker.summary)
    ; "runtime_blocker_signature",
      (match blocker.signature with Some s -> `String s | None -> `Null)
    ; "runtime_blocker_facts", runtime_blocker_facts_json meta
    ]
  | None ->
    [ "runtime_blocker_class", `Null
    ; "runtime_blocker_summary", `Null
    ; "runtime_blocker_signature", `Null
    ; "runtime_blocker_facts", `Null
    ]
;;

let runtime_blocker_fields_json (config : Workspace_utils.config) (meta : keeper_meta) =
  runtime_blocker_fields_json_of_surface meta (runtime_blocker_surface_opt config meta)
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
  | Approval_queue_unavailable of Keeper_approval_queue_result.storage_error

let attention_of_surface
      (config : Workspace_utils.config)
      (meta : keeper_meta)
      (runtime_blocker : runtime_blocker_surface option)
      approval_queue
  : Keeper_attention_reason.t option
  =
  let module R = Keeper_attention_reason in
  match approval_queue with
  | Approval_queue_unavailable _ -> Some R.Approval_queue_unavailable
  | Approval_queue_ready pending_approval_count when pending_approval_count > 0 ->
    Some R.Approval_pending
  | Approval_queue_ready _ ->
    match runtime_blocker with
    | Some _ when meta.paused -> Some R.Paused_on_blocker
    | Some { blocker_class = Blocked_by_runtime_exhaustion; _ } ->
      Some R.Runtime_attempts_exhausted
    | Some { blocker_class = Blocked_by_provider_runtime_error; _ } ->
      Some R.Provider_runtime_error
    | Some { blocker_class = Blocked_by_unresolved_fiber; _ } ->
      Some R.Fiber_unresolved
    | Some
        { blocker_class =
            ( Blocked_by_heartbeat_failures
            | Blocked_by_turn_failures
            | Blocked_by_official_client_recovery
            | Blocked_by_turn_configuration_error
            | Blocked_by_exception
            | Blocked_by_operator_interrupt )
        ; _
        } -> Some R.Runtime_blocked
    | None when meta.paused -> Some R.Paused
    (* Every branch above reads a record someone wrote: an approval row, a
       blocker class, an operator pause. A Keeper whose keepalive fiber is
       gone writes none of them, so the arms above all miss it and the
       answer used to fall through to [false]. That is how sangsu reported
       "no attention" for two and a half hours after its turn ended on
       "Payment required: Insufficient Balance": the provider failure left
       no blocker class behind, nobody had paused it, and its Discord queue
       grew from 14 entries to 53 while the surface said it was fine.

       Liveness is the one fact none of the written records carry, and it
       needs no threshold to read -- [is_running] enumerates every phase. A
       paused Keeper is answered above, so reaching here not running means
       nobody chose the silence. *)
    | None when not (runtime_keepalive_running config meta) ->
      Some R.Keepalive_stopped
    | None -> None
;;

let attention_fields_json_of
      (meta : keeper_meta)
      approval_queue
      (attention : Keeper_attention_reason.t option)
  =
  let approval_queue_state, pending_approval_count =
    match approval_queue with
    | Approval_queue_ready count ->
      Keeper_approval_queue_result.approval_queue_ready_state_json, `Int count
    | Approval_queue_unavailable error ->
      ( Keeper_approval_queue_result.approval_queue_unavailable_state_json error
      , `Null )
  in
  [ "needs_attention", `Bool (Option.is_some attention)
  ; ( "attention_reason"
    , Json_util.string_opt_to_json
        (Option.map Keeper_attention_reason.to_wire attention) )
  ; ( "next_human_action"
    , Json_util.string_opt_to_json
        (Option.map Keeper_attention_reason.next_human_action attention) )
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

let read_approval_queue_attention (config : Workspace_utils.config) (meta : keeper_meta) =
  match
    Keeper_approval_queue.pending_count_for_keeper_in_workspace
      ~base_path:config.base_path
      ~keeper_name:meta.name
  with
  | Ok count -> Approval_queue_ready count
  | Error error -> Approval_queue_unavailable error
;;

let attention_fields_json (config : Workspace_utils.config) (meta : keeper_meta) =
  let approval_queue = read_approval_queue_attention config meta in
  attention_of_surface config meta (runtime_blocker_surface_opt config meta) approval_queue
  |> attention_fields_json_of meta approval_queue
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
    | (Fiber_alive | Fiber_zombie | Fiber_unknown) as health -> health
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
let override_field_source_json ~default_source_kind ~default_manifest_path override =
  let default_value = Keeper_status_bridge_override.default_value_json override in
  let default_missing =
    match default_value with
    | `Null -> true
    | _ -> false
  in
  let default_manifest_exists =
    match default_manifest_path with
    | Some path -> Fs_compat.file_exists path
    | None -> false
  in
  `Assoc
    [ "field", `String (Keeper_status_bridge_override.field_name override)
    ; "source", `String "live_meta"
    ; "live_source", `String "runtime_overlay"
    ; "default_source", Json_util.string_opt_to_json default_source_kind
    ; "default_source_kind", Json_util.string_opt_to_json default_source_kind
    ; "default_manifest_path", Json_util.string_opt_to_json default_manifest_path
    ; "default_manifest_exists", `Bool default_manifest_exists
    ; "default_missing", `Bool default_missing
    ; "default_value", default_value
    ; "live_value", Keeper_status_bridge_override.live_value_json override
    ]
;;

type source_provenance =
  { overrides : Keeper_status_bridge_override.t list
  ; live_meta_path : string
  ; default_manifest_path : string option
  ; default_source_kind : string option
  ; default_config_error : Keeper_types_profile.keeper_toml_config_error option
  ; resolution : Config_dir_resolver.resolution
  }

let source_provenance config (meta : keeper_meta) =
  let snapshot =
    keeper_default_source_snapshot ~base_path:config.Workspace.base_path meta.name
  in
  { overrides = live_override_details meta snapshot.defaults
  ; live_meta_path = keeper_meta_path config meta.name
  ; default_manifest_path = snapshot.defaults.manifest_path
  ; default_source_kind = snapshot.source_kind
  ; default_config_error =
      Option.map
        (Keeper_types_profile.keeper_toml_config_error_of_load_error
           ~keeper_name:meta.name)
        snapshot.config_error
  ; resolution =
      Config_dir_resolver.resolve_for_base_path ~base_path:config.Workspace.base_path
  }
;;

let active_config_root provenance = provenance.resolution.config_root.path

let active_config_root_source provenance =
  Config_dir_resolver.source_to_string provenance.resolution.config_root.source
;;

let source_provenance_json config (meta : keeper_meta) =
  let provenance = source_provenance config meta in
  let { overrides
      ; live_meta_path
      ; default_manifest_path
      ; default_source_kind
      ; default_config_error
      ; resolution
      }
    =
    provenance
  in
  let override_fields = List.map Keeper_status_bridge_override.field_name overrides in
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
     ; "active_config_root", `String (active_config_root provenance)
     ; "active_config_root_source", `String (active_config_root_source provenance)
     ; "config_resolution", Config_dir_resolver.to_json resolution
     ; "precedence", `List [ `String "live_meta"; `String "keeper_config" ]
     ]
     @ [ "has_live_override", `Bool (override_fields <> [])
       ; "override_fields", Json_util.json_string_list override_fields
       ; ( "override_field_sources"
         , `List
             (List.map
                (override_field_source_json ~default_source_kind ~default_manifest_path)
                overrides) )
       ])
;;
