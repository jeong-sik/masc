include Operator_pending_confirm
include Operator_digest

(* Keeper runtime identity fields extracted to
   [Operator_control_snapshot_identity_fields] (godfile decomp). *)
let keeper_runtime_identity_fields = Operator_control_snapshot_identity_fields.keeper_runtime_identity_fields
let keeper_current_task_field = Operator_control_snapshot_identity_fields.keeper_current_task_field
(* action_result_status + confirmation_state + action_log_entry types,
   stringifiers, and persistence helpers extracted to
   [Operator_control_snapshot_action_log] (godfile decomp). The
   include flows through to [Operator_control] via
   [Operator_control_action] in the existing include chain. *)
include Operator_control_snapshot_action_log

let get_payload args =
  Json_util.get_object args "payload" |> Option.value ~default:(`Assoc [])
;;

(* remote_confirm_ttl_seconds + context helpers
   extracted to [Operator_control_snapshot_runtime_status] (godfile decomp). *)
let remote_confirm_ttl_seconds = Operator_control_snapshot_runtime_status.remote_confirm_ttl_seconds
let remote_client_type_of_context = Operator_control_snapshot_runtime_status.remote_client_type_of_context
let operator_server_profile_json = Operator_control_snapshot_runtime_status.operator_server_profile_json


let recent_messages_json config =
  Workspace.get_messages_raw config ~since_seq:0 ~limit:20
  |> List.map Masc_domain.message_to_yojson
  |> fun rows -> `List rows
;;

let _keeper_snapshot_max_concurrency =
  match Sys.getenv_opt "MASC_KEEPER_SNAPSHOT_CONCURRENCY" with
  | Some s ->
    (match int_of_string_opt (String.trim s) with
     | Some n when n >= 1 && n <= 64 -> n
     | _ -> 16)
  | None -> 16
;;

let _keeper_sem = Eio.Semaphore.make _keeper_snapshot_max_concurrency

(* PR-C2: encapsulate [Eio.Semaphore.acquire]/[release] inside a single
   helper scope so the slot is released even when the body raises
   non-Cancelled exceptions (which the previous on_release callback could
   not guarantee -- a [Log.Dashboard.info] failure inside the callback
   would skip the release and leak the slot).

   - [wait_ms] measures contention on the acquire call.
   - [work_ms] measures the body's wall time.
   - The 500ms threshold log fires only on the *normal-exit* path:
     Cancelled propagation skips the log to avoid double-reporting;
     the exception itself carries the unwind trace.

   No typed state machine is introduced -- the slot itself is
   encapsulated by the helper, so there is no counter/state to
   desynchronise.  Mirrors PR-B/PR-C1 in spirit (no separate counter
   for the per-fiber slot) but expressed as a scope rather than a
   state transition. *)
let with_keeper_slot ~sem ~name f =
  let t_wait_start = Time_compat.now () in
  Eio.Semaphore.acquire sem;
  let t_work_start = Time_compat.now () in
  let wait_ms = (t_work_start -. t_wait_start) *. 1000.0 in
  (* fun-protect-finally-ok: Eio.Semaphore.release is non-suspending
     (Atomic.incr + run-queue wake, no fiber switch). *)
  Fun.protect

    ~finally:(fun () -> Eio.Semaphore.release sem)
    (fun () ->
       try
         let v = f () in
         let work_ms = (Time_compat.now () -. t_work_start) *. 1000.0 in
         if work_ms > 500.0 || wait_ms > 500.0
         then
           Log.Dashboard.info
             "[keepers_json:%s] wait=%.0fms work=%.0fms"
             name
             wait_ms
             work_ms;
         v
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         let work_ms = (Time_compat.now () -. t_work_start) *. 1000.0 in
         if work_ms > 500.0 || wait_ms > 500.0
         then
           Log.Dashboard.info
             "[keepers_json:%s] wait=%.0fms work=%.0fms (exn: %s)"
             name
             wait_ms
             work_ms
             (Printexc.to_string exn);
         raise exn)
;;

let compact_keeper_runtime_trust_json = Operator_control_snapshot_trust.compact_keeper_runtime_trust_json

let earlier_deadline left right = match left, right with
  | None, deadline | deadline, None -> deadline
  | Some left, Some right -> Some (Float.min left right)

let keeper_attention_observation config meta =
  let approval_queue = Keeper_status_bridge.read_approval_queue_attention config meta in
  let attention = Keeper_status_bridge.attention_of_surface config meta
      (Keeper_status_bridge.runtime_blocker_surface_opt config meta) approval_queue in
  let completeness = match approval_queue with
    | Keeper_status_bridge.Approval_queue_ready _ -> Dashboard_projection_read.Complete
    | Approval_queue_unavailable error -> Partial (Keeper_approval_queue_result.storage_error_to_string error) in
  Keeper_status_bridge.attention_fields_json_of meta approval_queue attention, completeness

let keeper_runtime_trust_observation ~read_policy ~config ~meta =
  try match read_policy with
    | Dashboard_projection_read.Current ->
        Operator_control_snapshot_trust.compact_keeper_runtime_trust_observation ~config ~meta
    | Reuse -> {Dashboard_projection_read.json = compact_keeper_runtime_trust_json ~read_policy ~config ~meta;
        next_deadline_unix = None; completeness = Complete}
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
      let detail = Printexc.to_string exn in
      Log.Dashboard.warn "operator snapshot trust compact failed for keeper %s: %s" meta.Keeper_meta_contract.name detail;
      {Dashboard_projection_read.json = `Null; next_deadline_unix = None;
       completeness = Partial detail}

(* What one Keeper name became in [keepers_json]. *)
type keeper_row_outcome =
  | Keeper_row of Dashboard_projection_read.observation
  | Keeper_gone (** metadata absent: removed after the name was listed *)
  | Keeper_unread of Keeper_snapshot_unread.t

let keepers_json
      ~read_policy
      ~keeper_names
      ?(include_recent_activity = false)
      ?(lightweight = false)
      config
  =
  (* A name list that did not read has no name to build a row for, and no
     name to put in [unread] either. The section says so in its own field
     rather than reading as a fleet of none (#38120). *)
  let names, listing =
    match keeper_names with
    | Ok names -> names, Keeper_snapshot_unread.Listed
    | Error detail -> [], Keeper_snapshot_unread.Unreadable detail
  in
  let keeper_keepalive_interval_s =
    Runtime_params.get Runtime_settings.keeper_keepalive_interval_sec
    |> float_of_int
  in
  let keeper_snapshot_interval_s =
    Runtime_params.get Runtime_settings.keeper_snapshot_sec |> float_of_int
  in
  (* Parallel keeper I/O with concurrency cap: at most
     _keeper_snapshot_max_concurrency fibers run simultaneously.
     Without this cap, 9+ keepers doing concurrent file I/O + JSON
     construction can cause memory spikes during dashboard refresh. *)
  let n = List.length names in
  let results = Array.make n Keeper_gone in
  Eio.Fiber.all
    (List.mapi
       (fun idx name () ->
          Eio.Switch.run
          @@ fun _keeper_sw ->
          (* PR-C2: pair acquire/release inside a single [with_keeper_slot]
            scope instead of the previous
            [Eio.Switch.on_release (fun () -> Eio.Semaphore.release ...)]
            pattern.  The on_release callback is *cancel-safe* (it fires on
            both normal exit and Cancel.Cancelled unwind) but its [release]
            was *not exception-safe* -- a [Log.Dashboard.info] failure inside
            the callback would skip the release and leak the slot.  Fun.protect
            is exception-safe, never double-releases, and matches PR-B's
            typed-state pattern (no separate counter, lifecycle absorbed by
            the helper).

            Two-phase timing: [wait_ms] measures semaphore contention
            (acquire delay), [work_ms] measures per-keeper I/O cost.
            We log only when either half exceeds 500ms so healthy
            snapshots stay quiet.  The log is part of the *success path*
            inside [with_keeper_slot]; Cancelled propagation skips it. *)
          with_keeper_slot ~sem:_keeper_sem ~name (fun () ->
            let t_work_start = Time_compat.now () in
            (* Per-sub-op timing for #8822: attribute ~3100ms snapshot cost.
              Threshold 300ms — lower than outer 500ms for more data. *)
            let dt_meta = ref 0.0 in
            let dt_audit = ref 0.0 in
            let dt_profile = ref 0.0 in
            let dt_phase = ref 0.0 in
            let dt_trust = ref 0.0 in
            let dt_activity = ref 0.0 in
          let emit_timing_log total_work =
            if total_work > 0.3
            then
              Log.Dashboard.info
                "[keepers_json:%s] sub-op: meta=%.0fms \
                 audit=%.0fms profile=%.0fms phase=%.0fms trust=%.0fms activity=%.0fms \
                 total=%.0fms"
                name
                (!dt_meta *. 1000.0)
                (!dt_audit *. 1000.0)
                (!dt_profile *. 1000.0)
                (!dt_phase *. 1000.0)
                (!dt_trust *. 1000.0)
                (!dt_activity *. 1000.0)
                (total_work *. 1000.0)
          in
          results.(idx)
          <- (try
                let t0 = Time_compat.now () in
                match Keeper_meta_store.read_meta config name with
                | Error detail ->
                  Keeper_unread
                    { Keeper_snapshot_unread.name
                    ; reason = Keeper_snapshot_unread.Meta_read_failed detail
                    }
                | Ok None -> Keeper_gone
                | Ok (Some meta) ->
                  dt_meta := Time_compat.now () -. t0;
                  if lightweight && meta.paused
                  then (
                    let t_ph = Time_compat.now () in
                    let registry_phase =
                      Keeper_registry.get_phase ~base_path:config.base_path meta.name
                    in
                    let phase_str =
                      match registry_phase with
                      | Some p -> `String (Keeper_state_machine.phase_to_string p)
                      | None -> `String "paused"
                    in
                    dt_phase := Time_compat.now () -. t_ph;
                    (* Same reading as the unpaused branch below, from the
                       same registry read as [phase]. Pausing is an operator
                       decision published in [paused]; it does not remove
                       the health observation. *)
                    let diagnostic_observation =
                      Keeper_status_runtime.keeper_diagnostic_observation
                        ~meta
                        ~phase:registry_phase
                        ~history_items:[]
                        ~now_ts:(Time_compat.now ())
                    in
                    let diagnostic = diagnostic_observation.json in
                    let runtime_trust_observation =
                      let t_trust = Time_compat.now () in
                      let result = keeper_runtime_trust_observation ~read_policy ~config ~meta in
                      dt_trust := Time_compat.now () -. t_trust;
                      result
                    in
                    let runtime_trust = runtime_trust_observation.json in
                    let attention_fields, attention_completeness = keeper_attention_observation config meta in
                    emit_timing_log (Time_compat.now () -. t_work_start);
                    Keeper_row
                      {json = (`Assoc
                          ([ "runtime_class", `String "keeper"
                           ; "pipeline_stage", `String "paused"
                           ; "phase", phase_str
                           ; "name", `String meta.name
                           ; ( "status"
                             , `String
                                 (Keeper_status_runtime.control_plane_status_to_string
                                    Keeper_status_runtime.Cp_paused) )
                           ; "paused", `Bool true
                           ; "diagnostic", diagnostic
                           ; "turn_count", `Int meta.runtime.usage.total_turns
                           ; ( "keeper_keepalive_interval_s"
                             , `Float keeper_keepalive_interval_s )
                           ; ( "keeper_snapshot_interval_s"
                             , `Float keeper_snapshot_interval_s )
                           ; "updated_at", `String meta.updated_at
                           ; "created_at", `String meta.created_at
                           ]
                           @ keeper_runtime_identity_fields meta
                           @ [ keeper_current_task_field meta ]
                           @ Keeper_status_bridge.runtime_blocker_fields_json config meta
                           @ attention_fields
                           @ [ "runtime_trust", runtime_trust ]));
                       next_deadline_unix = earlier_deadline diagnostic_observation.next_deadline_unix runtime_trust_observation.next_deadline_unix;
                       completeness = Dashboard_projection_read.combine_completeness
                         runtime_trust_observation.completeness attention_completeness})
                  else (
                    (* One registry read for the row: [phase], [pipeline_stage],
                       [keepalive_running] and the diagnostic's health all come
                       from it, so they cannot describe two different moments. *)
                    let t_phase = Time_compat.now () in
                    let registry_phase =
                      Keeper_registry.get_phase ~base_path:config.base_path meta.name
                    in
                    dt_phase := Time_compat.now () -. t_phase;
                    let keepalive_running =
                      Keeper_status_runtime.keepalive_running_of_phase registry_phase
                    in
                    let now_ts = Time_compat.now () in
                    let created_ts =
                      Workspace_resilience.Time.parse_iso8601_opt meta.created_at
                      |> Option.value ~default:0.0
                    in
                    let last_turn_ago_s =
                      Keeper_status_metrics.age_seconds_opt
                        ~now_ts meta.runtime.usage.last_turn_ts
                    in
                    let last_proactive_ago_s =
                      Keeper_status_metrics.age_seconds_opt
                        ~now_ts meta.runtime.proactive_rt.last_ts
                    in
                    let last_activity_ts =
                      List.fold_left
                        max
                        0.0
                        [ meta.runtime.usage.last_turn_ts
                        ; meta.runtime.proactive_rt.last_ts
                        ; created_ts
                        ]
                    in
                    let last_activity_ago_s =
                      Keeper_status_metrics.age_seconds_opt ~now_ts last_activity_ts
                    in
                    let diagnostic_observation =
                      Keeper_status_runtime.keeper_diagnostic_observation
                        ~meta
                        ~phase:registry_phase
                        ~history_items:[]
                        ~now_ts
                    in
                    let diagnostic = diagnostic_observation.json in
                    let t_audit = Time_compat.now () in
                    let audit_json =
                      Operator_control_snapshot_tool_audit.tool_audit_json ~read_policy
                        config
                        meta
                    in
                    let recent_tool_names =
                      Json_util.get_string_list audit_json "recent_tool_names"
                    in
                    let latest_tool_names =
                      Json_util.get_string_list audit_json "latest_tool_names"
                    in
                    let latest_tool_call_count =
                      Json_util.get_int audit_json "latest_tool_call_count"
                    in
                    let latest_action_source =
                      Json_util.get_string audit_json "latest_action_source"
                    in
                    let tool_audit_source =
                      Json_util.get_string audit_json "tool_audit_source"
                    in
                    let tool_audit_at =
                      Json_util.get_string audit_json "tool_audit_at"
                    in
                    dt_audit := Time_compat.now () -. t_audit;
                    let status =
                      if meta.paused
                      then
                        Keeper_status_runtime.control_plane_status_to_string
                          Keeper_status_runtime.Cp_paused
                      else
                        Keeper_status_runtime.keeper_surface_status ~diagnostic
                    in
                    let pipeline_stage =
                      if meta.paused
                      then "paused"
                      else
                        match registry_phase with
                        | Some phase -> Keeper_status_runtime.pipeline_stage_of_phase phase
                        | None -> "offline"
                    in
                    let phase_str =
                      if meta.paused
                      then (
                        match registry_phase with
                        | Some p -> `String (Keeper_state_machine.phase_to_string p)
                        | None -> `String "paused")
                      else
                        match registry_phase with
                        | Some p -> `String (Keeper_state_machine.phase_to_string p)
                        | None -> `Null
                    in
                    let context_snapshot_fields =
                      Keeper_context_observation_projection.context_fields
                        ~config
                        ~keeper_name:meta.name
                        ~current_trace_id:
                          (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
                    in
                    let runtime_trust_observation =
                      let t_trust = Time_compat.now () in
                      let result = keeper_runtime_trust_observation ~read_policy ~config ~meta in
                      dt_trust := Time_compat.now () -. t_trust;
                      result
                    in
                    let runtime_trust = runtime_trust_observation.json in
                    let attention_fields, attention_completeness = keeper_attention_observation config meta in
                    let row =
                      `Assoc
                        ([ "runtime_class", `String "keeper"
                         ; "pipeline_stage", `String pipeline_stage
                         ; "phase", phase_str
                         ; "name", `String meta.name
                         ; ( "trace_id"
                           , `String (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
                           )
                         ; "status", `String status
                           (* [status] is folded from this diagnostic, and the
                              readers that rank or classify health
                              (dashboard briefing, execution continuity) read
                              [diagnostic.health_state]. Without it on the row
                              the briefing published health null for every
                              keeper, and the execution render rebuilt it from
                              a second registry read. That render now reuses
                              this one, so its health follows the cached
                              snapshot (up to ten seconds old) and agrees with
                              [status] on the same row. *)
                         ; "diagnostic", diagnostic
                         ; "paused", `Bool meta.paused
                         ; "pause_state", `String (if meta.paused then "paused" else "active")
                         ; "turn_count", `Int meta.runtime.usage.total_turns
                         ; ( "keeper_keepalive_interval_s"
                           , `Float keeper_keepalive_interval_s )
                         ; ( "keeper_snapshot_interval_s"
                           , `Float keeper_snapshot_interval_s )
                         ; "last_turn_ago_s", Json_util.float_opt_to_json last_turn_ago_s
                         ; "last_proactive_ago_s", Json_util.float_opt_to_json last_proactive_ago_s
                         ; "last_activity_ago_s", Json_util.float_opt_to_json last_activity_ago_s
                         ; "last_model_used", `String (Keeper_status_runtime.active_model_of_meta meta)
                         ]
                         @ keeper_runtime_identity_fields meta
                         @ [ keeper_current_task_field meta ]
                         @ [ "keepalive_running", `Bool keepalive_running
                           ; "next_model_hint", `Null
                           ; ( "latest_tool_names"
                             , `List
                                 (List.map (fun value -> `String value) latest_tool_names)
                             )
                           ; ( "recent_tool_names"
                             , `List
                                 (List.map (fun value -> `String value) recent_tool_names)
                             )
                           ; ( "latest_tool_call_count"
                             , Json_util.option_to_yojson
                                 (fun value -> `Int value)
                                 latest_tool_call_count )
                           ; ( "latest_action_source"
                             , Json_util.string_opt_to_json latest_action_source )
                           ; "tool_audit_source", Json_util.string_opt_to_json tool_audit_source
                           ; "tool_audit_at", Json_util.string_opt_to_json tool_audit_at
                           ; "activation_mode", Keeper_activation_mode.to_yojson meta.activation_mode
                           ; ( "last_proactive_reason"
                             , Json_util.string_opt_to_json
                                 (let value =
                                    String.trim meta.runtime.proactive_rt.last_reason
                                  in
                                  if value = "" then None else Some value) )
                           ; ( "last_proactive_preview"
                             , Json_util.string_opt_to_json
                                 (let value =
                                    String.trim meta.runtime.proactive_rt.last_preview
                                  in
                                  if value = "" then None else Some value) )
                           ; "updated_at", `String meta.updated_at
                           ; "created_at", `String meta.created_at
                           ; ( "recent_activity"
                             , let t_act = Time_compat.now () in
                               let result =
                                 if include_recent_activity
                                 then (
                                   let store =
                                     Keeper_types_support.keeper_metrics_store config name
                                   in
                                   let lines = Dated_jsonl.read_recent_lines store 5 in
                                   let parsed, _ =
                                     Fs_compat.parse_jsonl_lines
                                       ~source:"operator_recent_keeper_metrics"
                                       lines
                                   in
                                   `List
                                     (List.filter
                                        (fun json ->
                                           Option.is_some
                                             (Keeper_metrics_record
                                              .kind_of_json
                                                json))
                                        parsed))
                                 else `List []
                               in
                               dt_activity := Time_compat.now () -. t_act;
                               result )
                           ]
                         @ context_snapshot_fields
                         @ [ ( "last_turn_usage"
                             , Keeper_context_observation_projection
                               .last_turn_usage_json
                                 ~base_path:config.base_path
                                 meta )
                           ]
                         @ Keeper_status_bridge.runtime_blocker_fields_json config meta
                         @ attention_fields
                         @ [ "runtime_trust", runtime_trust ])
                    in
                    emit_timing_log (Time_compat.now () -. t_work_start);
                    Keeper_row {json = row;
                      next_deadline_unix = earlier_deadline diagnostic_observation.next_deadline_unix runtime_trust_observation.next_deadline_unix;
                      completeness = Dashboard_projection_read.combine_completeness
                        runtime_trust_observation.completeness attention_completeness})
              with
              | Eio.Cancel.Cancelled _ as e -> raise e
              | exn ->
                let detail = Printexc.to_string exn in
                Log.Dashboard.error "keepers_json fiber error (%s): %s" name detail;
                Keeper_unread
                  { Keeper_snapshot_unread.name
                  ; reason = Keeper_snapshot_unread.Row_raised detail
                  })))
       names);
  let outcomes = Array.to_list results in
  let rows =
    List.filter_map
      (function
        | Keeper_row observation -> Some observation.json
        | Keeper_gone | Keeper_unread _ -> None)
      outcomes
  in
  (* A Keeper whose row could not be built is still a Keeper: its name was
     listed. Leaving it out of [items] alone made it vanish from the briefing
     and the TUI with nothing saying so (#38090), so it is reported beside the
     rows. A name whose metadata is gone ([Keeper_gone]) was removed, not
     unread. *)
  let unread =
    List.filter_map
      (function
        | Keeper_unread unread -> Some unread
        | Keeper_row _ | Keeper_gone -> None)
      outcomes
  in
  let declarations, declaration_completeness =
    match Keeper_meta_store.persisted_keeper_names_result config with
    | Error detail -> [], Dashboard_projection_read.Partial detail
    | Ok persisted_names ->
      (* A metadata row may have been removed after this projection read it.
         Keep its initial name reserved until the next snapshot, so the same
         response cannot contain both its runtime and declaration rows. *)
      Keeper_declared_roster.missing ~base_path:config.base_path
        ~persisted_names:(List.sort_uniq String.compare (names @ persisted_names))
      |> List.map Keeper_declared_roster.to_json
      |> fun rows -> rows, Dashboard_projection_read.Complete
  in
  let rows = rows @ declarations in
  let completeness = Dashboard_projection_read.combine_completeness declaration_completeness
      (Dashboard_projection_read.keeper_completeness ~listing ~unread) in
  let completeness, next_deadline_unix = List.fold_left (fun (completeness, deadline) -> function
    | Keeper_row observation ->
        Dashboard_projection_read.combine_completeness completeness observation.completeness,
        earlier_deadline deadline observation.next_deadline_unix
    | Keeper_gone | Keeper_unread _ -> completeness, deadline)
      (completeness, None) outcomes in
  let json = `Assoc
    [ "count", `Int (List.length rows)
    ; "items", `List rows
    ; ( Keeper_snapshot_unread.section_field
      , `List (List.map Keeper_snapshot_unread.to_json unread) )
    ; Keeper_snapshot_unread.listing_field, Keeper_snapshot_unread.listing_to_json listing
    ] in
  {Dashboard_projection_read.json; next_deadline_unix; completeness}
;;

let persistent_agents_json = Operator_control_snapshot_persistent_agents.persistent_agents_json

let _snapshot_recent_completed_limit () =
  Dashboard_http_helpers.operator_snapshot_recent_completed_limit ()
;;

let workspace_observation = Operator_control_snapshot_workspace.workspace_observation

(* snapshot_view variant + parser extracted to
   [Operator_control_snapshot_view] (godfile decomp). *)
type snapshot_view = Operator_control_snapshot_view.snapshot_view =
  | Summary
  | Keepers
  | Messages
  | Full

let valid_snapshot_view_strings = Operator_control_snapshot_view.valid_snapshot_view_strings
let snapshot_view_of_string_opt = Operator_control_snapshot_view.snapshot_view_of_string_opt

(* Snapshot TTL cache with same-key deduplication (singleflight)
   extracted to [Operator_control_snapshot_cache] (godfile decomp).
   The include flows through to [Operator_control] via the existing
   include chain ([Operator_control_action] -> ...). *)
include Operator_control_snapshot_cache
let namespace_scope_cache_segment (_config : Workspace_utils.config) = "default"

let snapshot_read
      ?(read_policy = Dashboard_projection_read.Reuse)
      ?actor
      ?view
      ?(include_messages = true)
      ?(include_keepers = true)
      ?(include_summary_fields = true)
      ?(lightweight_summary = false)
      (ctx : 'a context)
  : Dashboard_projection_cache.snapshot_read
  =
  let cache_key =
    Printf.sprintf
      "%s|%s|%s|%s|%b|%b|%b|%b"
      ctx.config.base_path
      (namespace_scope_cache_segment ctx.config)
      (Option.value ~default:"" actor)
      (Option.value ~default:"" view)
      include_messages
      include_keepers
      include_summary_fields
      lightweight_summary
  in
  let compute_snapshot () =
    let t0 = Time_compat.now () in
    let timing_records = ref [] in
    let next_deadline = ref None in
    let completeness = ref Dashboard_projection_read.Complete in
    let timed label f =
      let t_start = Time_compat.now () in
      let result = f () in
      let elapsed = Time_compat.now () -. t_start in
      timing_records := (label, elapsed) :: !timing_records;
      if elapsed > 0.5
      then Log.Dashboard.info "[snapshot_json] %s: %.0fms" label (elapsed *. 1000.0);
      result
    in
    let config = ctx.config in
    let initialized = Workspace.is_initialized config in
    let trace_id = trace_id "ops" in
    let actor_name = normalized_actor ~context_actor:ctx.agent_name actor in
    let view =
      match Option.bind view snapshot_view_of_string_opt with
      | Some view -> view
      | None -> Full
    in
    let include_keepers =
      include_keepers
      &&
      match view with
      | Summary | Keepers | Full -> true
      | Messages -> false
    in
    let include_messages =
      include_messages
      &&
      match view with
      | Summary | Messages | Full -> true
      | Keepers -> false
    in
    let summary_fields =
      timed "summary_fields" (fun () ->
        if
          include_summary_fields
          && initialized
          &&
          match view with
          | Summary | Full -> true
          | Keepers | Messages -> false
        then (
          let workspace_attention, attention_deadline =
            build_workspace_attention_observation ~now:(Time_compat.now ()) config in
          next_deadline := earlier_deadline !next_deadline attention_deadline;
          let workspace_attention = List.sort compare_attention workspace_attention in
          (* #26144 moved actions out of the fallback read model: this layer
             observes and does not recommend. The summary is constant here --
             count=0, top_action=null, provenance="fallback",
             authoritative=false. It used to read
             [workspace_recommendations config], which that change had already
             emptied to [fun _ -> []], so the config argument was only making a
             constant look derived. *)
          [ "attention_summary", summary_of_attention_items workspace_attention
          ; ( "recommendation_summary"
            , summary_of_recommendations ~actor:actor_name [] )
          ])
        else [])
    in
    let keeper_names_listing =
      if initialized && include_keepers
      then Keeper_meta_store.keeper_names_result config
      else Ok []
    in
    (* The quarantine inventory reads per named Keeper. With no list it has
       no name to read; the listing failure is reported once, in the
       [keepers] section. *)
    let keeper_names = Result.value keeper_names_listing ~default:[] in
    let persistent_keeper_names, persistent_unread =
      if initialized && include_keepers
      then Keeper_meta_store.persistent_agent_names_with_unread config
      else [], []
    in
    completeness := Dashboard_projection_read.combine_completeness !completeness
      (Dashboard_projection_read.keeper_completeness
        ~listing:Keeper_snapshot_unread.Listed ~unread:persistent_unread);
  let board_attention_quarantines =
    timed "board_attention_quarantines" (fun () ->
      if initialized && include_keepers
      then
        let read_inventory () =
             Keeper_board_attention_quarantine_command.inventory
               ~base_path:config.base_path
               ~keeper_names in
        (match read_policy with
         | Dashboard_projection_read.Current ->
             let inventory = read_inventory () in
             List.iter (fun (error : Keeper_board_attention_quarantine_command.inventory_error) ->
               let detail = match error.kind with
                 | Inventory_candidate_ledger_unavailable -> "candidate ledger unavailable"
                 | Inventory_partition_ledger_unavailable -> "partition ledger unavailable" in
               completeness := Dashboard_projection_read.combine_completeness !completeness
                 (Partial (Printf.sprintf "Keeper %s quarantine inventory: %s" error.keeper_name detail)))
               inventory.errors;
             Keeper_board_attention_quarantine_command.inventory_to_json inventory
         | Reuse ->
             let cache_key = "operator:board-quarantines:" ^ config.base_path in
             Dashboard_cache.get_or_compute cache_key ~ttl:10.0
               (Pool_work.cpu ~name:__FUNCTION__ (fun () ->
                 Keeper_board_attention_quarantine_command.inventory_to_json (read_inventory ()))))
      else `Assoc [ "count", `Int 0; "items", `List []; "errors", `List [] ])
  in
  let workspace = workspace_observation config in
  completeness := Dashboard_projection_read.combine_completeness !completeness workspace.completeness;
  let result =
      `Assoc
        ([ "trace_id", `String trace_id
         ; "server_profile", operator_server_profile_json
         ; "judgment_owner", `String "fallback_read_model"
         ; "authoritative_judgment_available", `Bool false
         ; "inference_inflight", Inference_inflight_observation.snapshot_json ()
         ; "workspace", workspace.json
         ; "board_attention_quarantines", board_attention_quarantines
         ]
         @ (let empty_section = `Assoc [ "count", `Int 0; "items", `List [] ] in
            let keepers_observation =
              timed "keepers_json" (fun () ->
                if initialized && include_keepers
                then
                  keepers_json
                    ~read_policy
                    ~keeper_names:keeper_names_listing
                    ~lightweight:lightweight_summary
                    ~include_recent_activity:(not lightweight_summary)
                    config
                else
                  (* No Keeper name was read, so none went unread. *)
                  {Dashboard_projection_read.json = `Assoc
                    [ "count", `Int 0
                    ; "items", `List []
                    ; Keeper_snapshot_unread.section_field, `List []
                    ; ( Keeper_snapshot_unread.listing_field
                      , Keeper_snapshot_unread.listing_to_json
                          Keeper_snapshot_unread.Not_listed )
                    ]; next_deadline_unix = None; completeness = Complete})
            in
            completeness := Dashboard_projection_read.combine_completeness !completeness keepers_observation.completeness;
            next_deadline := earlier_deadline !next_deadline keepers_observation.next_deadline_unix;
            let keepers_json_value = keepers_observation.json in
            let persistent_agents_json_value =
              timed "persistent_agents_json" (fun () ->
                if initialized && include_keepers
                then (
                  let keeper_rows =
                    match keepers_json_value with
                    | `Assoc fields ->
                      (match List.assoc_opt "items" fields with
                       | Some (`List rows) -> rows
                       | _ -> [])
                    | _ -> []
                  in
                  persistent_agents_json
                    ~keeper_names:persistent_keeper_names
                    ~keeper_rows
                    config)
                else empty_section)
            in
            [ "keepers", keepers_json_value
            ; "persistent_agents", persistent_agents_json_value
            ])
         @ [ ( "recent_messages"
             , if initialized && include_messages && not lightweight_summary
               then recent_messages_json config
               else `List [] )
           ]
         @ (let confirm_scope =
              timed "pending_confirms" (fun () -> pending_confirm_scope ?actor config)
            in
            next_deadline := earlier_deadline !next_deadline
              (pending_confirm_deadline_unix confirm_scope.all_entries);
            [ ( "pending_confirm_envelope"
              , `Assoc
                  [ ( "items"
                    , `List
                        (List.map pending_confirm_to_yojson confirm_scope.visible_entries)
                    )
                  ; "summary", pending_confirm_summary_json_of_scope confirm_scope
                  ] )
            ])
         @ [ "available_actions", available_actions_json
           ; ( "recent_actions"
             , if lightweight_summary then `List [] else recent_actions_json config )
           ]
         @ summary_fields)
    in
    let elapsed_total = Time_compat.now () -. t0 in
    if elapsed_total > 1.0
    then (
      Log.Dashboard.info
        "[snapshot_json] total: %.0fms (keepers=%d)"
        (elapsed_total *. 1000.0)
        (List.length keeper_names);
      List.iter
        (fun (label, dt) ->
           if dt > 0.1
           then Log.Dashboard.info "[snapshot_json]   %s: %.0fms" label (dt *. 1000.0))
        (List.rev !timing_records));
    {Dashboard_projection_read.json = result; next_deadline_unix = !next_deadline; completeness = !completeness}
  in
  let ttl = Env_config_runtime_services.Operator.cache_ttl_sec in
  match read_policy with
  | Dashboard_projection_read.Current -> Dashboard_projection_cache.Observed (compute_snapshot ())
  | Reuse -> Dashboard_projection_cache.Cached_json
      (get_or_compute cache_key ~ttl (fun () -> (compute_snapshot ()).json))
;;

let snapshot_json ?read_policy ?actor ?view ?include_messages ?include_keepers
    ?include_summary_fields ?lightweight_summary ctx =
  match snapshot_read ?read_policy ?actor ?view ?include_messages ?include_keepers
      ?include_summary_fields ?lightweight_summary ctx with
  | Dashboard_projection_cache.Cached_json json -> json
  | Observed observation -> observation.json
;;
