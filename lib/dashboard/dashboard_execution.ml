include Dashboard_execution_helpers
include Dashboard_execution_fixture
include Dashboard_execution_builders

type workspace_status_state_projection =
  | Workspace_status_uninitialized
  | Workspace_status_snapshot of Workspace.read_state_snapshot

let workspace_status_state_projection_status = function
  | Workspace_status_uninitialized -> "uninitialized"
  | Workspace_status_snapshot snapshot ->
      Workspace.read_state_status_to_string snapshot.status
;;

let workspace_status_state_projection_errors = function
  | Workspace_status_uninitialized -> []
  | Workspace_status_snapshot snapshot -> snapshot.read_errors
;;

let workspace_status_json (config : Workspace.config) : Yojson.Safe.t =
  let workspace_state_projection =
    if Workspace.is_initialized config
    then Workspace_status_snapshot (Workspace.read_state_snapshot config)
    else Workspace_status_uninitialized
  in
  let workspace_state_opt =
    match workspace_state_projection with
    | Workspace_status_uninitialized -> None
    | Workspace_status_snapshot snapshot -> Some snapshot.state
  in
  let workspace_state_read_errors =
    workspace_status_state_projection_errors workspace_state_projection
  in
  let project =
    match workspace_state_opt with
    | Some workspace_state -> workspace_state.project
    | None -> "default"
  in
  let paused =
    match workspace_state_opt with
    | Some workspace_state -> workspace_state.paused
    | None -> false
  in
  let tempo = Tempo.get_tempo config in
  `Assoc
    [ "workspace_root", `String config.base_path
    ; "workspace_path", `String config.workspace_path
    ; "workspace_differs", `Bool (config.workspace_path <> config.base_path)
    ; "cluster", `String (Env_config_core.cluster_name ())
    ; "project", `String project
    ; ( "workspace_state_status"
      , `String (workspace_status_state_projection_status workspace_state_projection) )
    ; "workspace_state_read_error_count", `Int (List.length workspace_state_read_errors)
    ; ( "workspace_state_read_errors"
      , `List (List.map (fun error -> `String error) workspace_state_read_errors) )
    ; "tempo_interval_s", `Float tempo.current_interval_s
    ; "paused", `Bool paused
    ; "version", `String Version.version
    ]
;;

let tasks_safe config =
  if Workspace.is_initialized config then Workspace.get_tasks_safe config else []
;;

let agents_safe config =
  if Workspace.is_initialized config then Workspace.get_active_agents config else []
;;

let messages_safe config =
  if Workspace.is_initialized config
  then Workspace.get_messages_raw config ~since_seq:0 ~limit:20
  else []
;;

let assoc_upsert fields key value = (key, value) :: List.remove_assoc key fields

let compact_keeper_trust_json ~(config : Workspace.config) ~(meta : Keeper_meta_contract.keeper_meta) =
  let runtime_trust =
    if Keeper_fd_pressure.active ()
    then Keeper_fd_pressure.degraded_trust_json ()
    else Keeper_runtime_trust_snapshot.summary_json ~config ~meta
  in
  let member key = Option.value ~default:`Null (Json_util.assoc_member_opt key runtime_trust) in
  `Assoc
    [ "disposition", member "disposition"
    ; "disposition_reason", member "disposition_reason"
    ; "operator_disposition", member "operator_disposition"
    ; "operator_disposition_reason", member "operator_disposition_reason"
    ; "needs_attention", member "needs_attention"
    ; "attention_reason", member "attention_reason"
    ; "next_human_action", member "next_human_action"
    ; "approval_state", member "approval"
    ; "execution_summary", member "execution"
    ; "latest_terminal_reason", member "latest_terminal_reason"
    ; "latest_next_action", member "latest_next_action"
    ; "latest_causal_event", member "latest_causal_event"
    ]
;;

let reconcile_keeper_attention_fields_with_trust fields trust =
  match trust with
  | `Assoc _ ->
    let upsert key value fields = assoc_upsert fields key value in
    fields
    |> upsert "disposition" (Option.value ~default:`Null (Json_util.assoc_member_opt "disposition" trust))
    |> upsert
         "disposition_reason"
         (Option.value ~default:`Null (Json_util.assoc_member_opt "disposition_reason" trust))
    |> upsert
         "operator_disposition"
         (Option.value ~default:`Null (Json_util.assoc_member_opt "operator_disposition" trust))
    |> upsert
         "operator_disposition_reason"
         (Option.value ~default:`Null (Json_util.assoc_member_opt "operator_disposition_reason" trust))
    |> upsert "needs_attention" (Option.value ~default:`Null (Json_util.assoc_member_opt "needs_attention" trust))
    |> upsert
         "attention_reason"
         (Option.value ~default:`Null (Json_util.assoc_member_opt "attention_reason" trust))
    |> upsert
         "next_human_action"
         (Option.value ~default:`Null (Json_util.assoc_member_opt "next_human_action" trust))
  | _ -> fields
;;

(* #10710: bound on the per-render enrich fan-out. Code constant per
   [feedback_no-hyperparameter-as-env-knob] — the calibrated value
   should not be operator-tunable. 8 is empirically just past the
   point of diminishing returns on disk-bound enrich workloads on
   laptop-class hardware (per-keeper enrich is ~70% I/O wait), and
   keeps the dashboard render's fd/fiber footprint within budget
   even under fleet expansion. Raise only with a benchmark. *)
let dashboard_enrich_max_fibers = 8

(** #9766: per-render phase timing record used to surface a breakdown
    in the [slow render] WARN.  Pure values so a unit test can pin
    the formatting / per-keeper averaging without booting Eio. *)
type render_phase_timings_ms =
  { total_ms : float
  ; snapshot_ms : float
  ; operations_ms : float
  ; enrich_ms : float
  ; data_load_ms : float
  ; assemble_ms : float
  ; n_keepers : int
  }

let per_keeper_enrich_ms (t : render_phase_timings_ms) =
  if t.n_keepers > 0 then t.enrich_ms /. float_of_int t.n_keepers else 0.0
;;

let format_slow_render_timings (t : render_phase_timings_ms) =
  Printf.sprintf
    "total=%.0fms (keepers=%d) snapshot=%.0fms operations=%.0fms enrich=%.0fms \
     (per_keeper=%.0fms) data_load=%.0fms assemble=%.0fms"
    t.total_ms
    t.n_keepers
    t.snapshot_ms
    t.operations_ms
    t.enrich_ms
    (per_keeper_enrich_ms t)
    t.data_load_ms
    t.assemble_ms
;;

let render_phase_seconds ms = if ms <= 0.0 then 0.0 else ms /. 1000.0

let observe_render_phase phase ms =
  Otel_metric_store.observe_histogram
    Otel_metric_store.metric_dashboard_execution_render_phase_sec
    ~labels:[ "phase", phase ]
    (render_phase_seconds ms)
;;

let dashboard_snapshot_latency_seconds_buckets =
  [ 0.05; 0.1; 0.25; 0.5; 1.0; 2.5; 5.0; 10.0; 30.0; 60.0 ]
;;

let observe_dashboard_snapshot_latency ms =
  let seconds = render_phase_seconds ms in
  Otel_metric_store.observe_histogram
    Otel_metric_store.metric_dashboard_snapshot_latency_seconds
    seconds;
  let inc_bucket le =
    Otel_metric_store.inc_counter
      Otel_metric_store.metric_dashboard_snapshot_latency_seconds_bucket
      ~labels:[ "le", le ]
      ()
  in
  List.iter
    (fun upper -> if seconds <= upper then inc_bucket (Printf.sprintf "%g" upper))
    dashboard_snapshot_latency_seconds_buckets;
  inc_bucket "+Inf"
;;

let dashboard_all_zero_labels = [ "keeper", "__dashboard__" ]

let render_sub_operation_timings_all_zero (t : render_phase_timings_ms) =
  t.n_keepers > 0
  && t.snapshot_ms <= 0.0
  && t.operations_ms <= 0.0
  && t.enrich_ms <= 0.0
  && t.data_load_ms <= 0.0
  && t.assemble_ms <= 0.0
;;

let record_dashboard_all_zero_metric t =
  let value = if render_sub_operation_timings_all_zero t then 1.0 else 0.0 in
  Otel_metric_store.set_gauge
    Otel_metric_store.metric_dashboard_metric_all_zeros
    ~labels:dashboard_all_zero_labels
    value
;;

let record_render_phase_timings (t : render_phase_timings_ms) =
  record_dashboard_all_zero_metric t;
  observe_render_phase "total" t.total_ms;
  observe_render_phase "snapshot" t.snapshot_ms;
  if t.snapshot_ms > 0.0 then observe_dashboard_snapshot_latency t.snapshot_ms;
  observe_render_phase "operations" t.operations_ms;
  observe_render_phase "enrich" t.enrich_ms;
  (* Idle renders (n_keepers = 0) would otherwise inject a fake 0s sample
     that drags the per-keeper average toward zero and hides slow renders.
     Observe once per keeper so Otel_metric_store [sum / count] yields the actual
     average per-keeper enrich time, weighted by fleet size, instead of
     averaging render-level means (a 1-keeper render and a 100-keeper
     render contributing equally). *)
  if t.n_keepers > 0
  then (
    let per_keeper_value = per_keeper_enrich_ms t in
    for _ = 1 to t.n_keepers do
      observe_render_phase "enrich_per_keeper" per_keeper_value
    done);
  observe_render_phase "data_load" t.data_load_ms;
  observe_render_phase "assemble" t.assemble_ms
;;

let assoc_member_if_object key json =
  Json_util.get_object json key
;;

let existing_keeper_trust_json keeper_json =
  match assoc_member_if_object "runtime_trust" keeper_json with
  | Some _ as value -> value
  | None -> assoc_member_if_object "trust" keeper_json
;;

let upsert_keeper_trust_fields fields trust =
  let fields = assoc_upsert fields "trust" trust in
  let fields = assoc_upsert fields "runtime_trust" trust in
  reconcile_keeper_attention_fields_with_trust fields trust
;;

let enrich_keeper_with_diagnostic ~(config : Workspace.config) (keeper_json : Yojson.Safe.t) =
  let result = match keeper_json with
  | `Assoc fields ->
    (* The upstream operator snapshot already carries these for most keeper rows.
       Reuse them before falling back to per-keeper file reads. *)
    let existing_diagnostic = assoc_member_if_object "diagnostic" keeper_json in
    let existing_trust = existing_keeper_trust_json keeper_json in
    (match existing_diagnostic, existing_trust with
     | Some _, Some trust -> `Assoc (upsert_keeper_trust_fields fields trust)
     | _ ->
       (match Option.value ~default:`Null (Json_util.assoc_member_opt "name" keeper_json) with
        | `String name ->
          (match Keeper_meta_store.read_meta_resolved config name with
           | Ok (Some (_resolved_name, meta)) ->
             let keepalive_running =
               match Option.value ~default:`Null (Json_util.assoc_member_opt "keepalive_running" keeper_json) with
               | `Bool value -> value
               | _ -> Keeper_status_bridge.runtime_keepalive_running config meta
             in
             let now_ts = Time_compat.now () in
             let diagnostic =
               match existing_diagnostic with
               | Some diagnostic -> diagnostic
               | None ->
                 Keeper_status_runtime.keeper_diagnostic_json
                   ~meta
                   ~agent_status:(Option.value ~default:`Null (Json_util.assoc_member_opt "agent" keeper_json))
                   ~keepalive_running
                   ~history_items:[]
                   ~now_ts
                 |> Keeper_status_runtime.augment_keeper_diagnostic_json
                      ~meta
                      ~keepalive_running
                      ~keepalive_started_at:
                        (Keeper_status_bridge.runtime_keepalive_started_at config meta)
                      ~now_ts
             in
             let trust =
               match existing_trust with
               | Some trust -> trust
               | None ->
                 (try compact_keeper_trust_json ~config ~meta with
                  | Eio.Cancel.Cancelled _ as exn -> raise exn
                  | exn ->
                    Log.Dashboard.warn
                      "dashboard_execution trust enrich failed for keeper %s: %s"
                      meta.name
                      (Printexc.to_string exn);
                    `Null)
             in
             let fields = assoc_upsert fields "diagnostic" diagnostic in
             let fields = upsert_keeper_trust_fields fields trust in
             `Assoc fields
           | Ok None | Error _ -> keeper_json)
        | _ -> keeper_json))
  | _ -> keeper_json
  in
  (* Surface the autoboot exclusion reason so the roster can show *why* a keeper
     is not booting/proactive (declarative_autoboot_disabled / paused /
     autoboot_disabled).  paused/proactive_enabled already ride on the snapshot
     keeper row; exclusion_reason is the missing visibility piece. *)
  (match result with
   | `Assoc fields ->
     (match Json_util.assoc_string_opt "name" result with
      | Some name ->
        (match Keeper_runtime.autoboot_exclusion_reason config name with
         | Some reason ->
           `Assoc
             (assoc_upsert
                fields
                "exclusion_reason"
                (Keeper_runtime.autoboot_exclusion_reason_to_yojson reason))
         | None -> result)
      | None -> result)
   | other -> other)
;;

let bool_field ?(default = false) key json =
  match member_assoc key json with
  | `Bool value -> value
  | _ -> default
;;

let keeper_runtime_trust_json keeper =
  match member_assoc "runtime_trust" keeper with
  | `Assoc _ as trust -> trust
  | _ -> member_assoc "trust" keeper
;;

let lowercase_json_string key json =
  Json_util.get_string json key |> Option.map String.lowercase_ascii
;;

let terminal_reason_json trust = member_assoc "latest_terminal_reason" trust
let terminal_reason_code trust = terminal_reason_json trust |> (fun j -> Json_util.get_string j "code")

let terminal_reason_severity trust =
  terminal_reason_json trust |> lowercase_json_string "severity"
;;

let terminal_reason_disposition trust =
  terminal_reason_json trust
  |> (fun j -> Json_util.get_string j "disposition")
  |> Option.map Keeper_turn_disposition.of_wire
;;

let terminal_reason_requires_attention trust =
  match terminal_reason_disposition trust with
  | Some Keeper_turn_disposition.Success -> false
  | Some _ -> true
  | None ->
    (match terminal_reason_severity trust with
     | Some ("bad" | "warn") -> true
     | _ ->
       (match terminal_reason_code trust |> Option.map String.lowercase_ascii with
        | Some ("success" | "completed") | None -> false
        | Some _ -> true))
;;

let trust_disposition_requires_attention trust =
  match lowercase_json_string "disposition" trust with
  | Some ("alert" | "blocked" | "pause") -> true
  | _ -> false
;;

let keeper_queue_severity keeper trust =
  match terminal_reason_disposition trust with
  | Some disp ->
    (match Keeper_turn_disposition.severity disp with
     | Ok -> "ok"
     | Warn -> "warn"
     | Bad | Unknown_bad -> "bad")
  | None ->
    (match terminal_reason_severity trust with
     | Some "bad" -> "bad"
     | Some "warn" -> "warn"
     | _ ->
       (match lowercase_json_string "disposition" trust with
        | Some "alert" -> "bad"
        | Some ("blocked" | "pause") -> "warn"
        | _ ->
          if Option.is_some (Json_util.assoc_string_opt "runtime_blocker_class" keeper)
          then "bad"
          else "warn"))
;;

let first_text values =
  List.find_map
    (function
      | Some value ->
        let compacted = compact_text value in
        if compacted = "" then None else Some compacted
      | None -> None)
    values
;;

let keeper_queue_summary keeper trust =
  let terminal = terminal_reason_json trust in
  first_text
    [ Json_util.assoc_string_opt "attention_reason" trust
    ; Json_util.assoc_string_opt "summary" terminal
    ; Json_util.assoc_string_opt "runtime_blocker_summary" keeper
    ; Json_util.assoc_string_opt "operator_disposition_reason" trust
    ; Json_util.assoc_string_opt "disposition_reason" trust
    ; Json_util.assoc_string_opt "latest_next_action" trust
    ; Some "keeper needs operator attention"
    ]
  |> Option.value ~default:"keeper needs operator attention"
;;

let keeper_queue_last_seen keeper trust =
  let latest_causal = member_assoc "latest_causal_event" trust in
  let last_seen_at =
    latest_iso_timestamp
      [ Json_util.assoc_string_opt "ts" latest_causal
      ; Json_util.assoc_string_opt "observed_at" latest_causal
      ; Json_util.assoc_string_opt "last_autonomous_action_at" keeper
      ; Json_util.assoc_string_opt "last_heartbeat" keeper
      ; Json_util.assoc_string_opt "updated_at" keeper
      ; Json_util.assoc_string_opt "created_at" keeper
      ]
  in
  last_seen_at, Dashboard_utils.parse_iso_opt last_seen_at |> Option.value ~default:0.0
;;

let build_keeper_execution_queue keepers =
  keepers
  |> List.filter_map (fun keeper ->
    match Json_util.assoc_string_opt "name" keeper with
    | None -> None
    | Some keeper_name ->
      let trust = keeper_runtime_trust_json keeper in
      let trust_needs_attention =
        bool_field "needs_attention" trust
        || trust_disposition_requires_attention trust
        || terminal_reason_requires_attention trust
      in
      let runtime_blocked =
        Option.is_some (Json_util.assoc_string_opt "runtime_blocker_class" keeper)
      in
      if not (trust_needs_attention || runtime_blocked)
      then None
      else (
        let severity = keeper_queue_severity keeper trust in
        let summary = keeper_queue_summary keeper trust in
        let last_seen_at, last_seen_ts = keeper_queue_last_seen keeper trust in
        let terminal_code = terminal_reason_code trust in
        let next_human_action =
          match Json_util.assoc_string_opt "next_human_action" trust with
          | Some _ as value -> value
          | None ->
            (match Json_util.assoc_string_opt "latest_next_action" trust with
             | Some _ as value -> value
             | None -> terminal_reason_json trust |> Json_util.assoc_string_opt "next_action")
        in
        let intervene_handoff =
          handoff_json
            ~surface:"intervene"
            ~label:"Keeper 상태 보기"
            ~target_type:"keeper"
            ~target_id:keeper_name
            ~focus_kind:"keeper"
            ()
        in
        let command_handoff =
          handoff_json
            ~surface:"command"
            ~command_surface:"agents"
            ~label:"Keeper 원인 보기"
            ~target_type:"keeper"
            ~target_id:keeper_name
            ~focus_kind:"keeper"
            ()
        in
        Some
          { severity_rank = severity_rank severity
          ; last_seen_ts
          ; json =
              `Assoc
                [ "id", `String ("keeper-" ^ keeper_name)
                ; "kind", `String "keeper"
                ; "severity", `String severity
                ; "status", member_assoc "status" keeper
                ; "summary", `String summary
                ; "target_type", `String "keeper"
                ; "target_id", `String keeper_name
                ; "linked_session_id", `Null
                ; "linked_operation_id", `Null
                ; "last_seen_at", Json_util.string_opt_to_json last_seen_at
                ; "attention_reason", member_assoc "attention_reason" trust
                ; "next_human_action", Json_util.string_opt_to_json next_human_action
                ; "terminal_reason_code", Json_util.string_opt_to_json terminal_code
                ; "runtime_trust", trust
                ; "top_handoff", command_handoff
                ; "intervene_handoff", intervene_handoff
                ; "command_handoff", command_handoff
                ]
          }))
;;

let merge_execution_queue left right =
  left @ right
  |> List.sort (fun left right ->
    let by_severity = Int.compare right.severity_rank left.severity_rank in
    if by_severity <> 0
    then by_severity
    else Float.compare right.last_seen_ts left.last_seen_ts)
;;

let model_map_of_keeper_rows keepers =
  let model_map : (string, string) Hashtbl.t = Hashtbl.create 8 in
  List.iter
    (function
      | `Assoc _ as keeper_json ->
        (match Json_util.assoc_member_opt "name" keeper_json,
               Json_util.assoc_member_opt "active_model" keeper_json with
         | Some (`String _), Some (`String _)
         | Some (`String _), _
         | _, Some (`String _)
         | _, _ -> ())
      | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> ())
    keepers;
  model_map
;;

let task_updated_at (task : Masc_domain.task) =
  match task.task_status with
  | Masc_domain.Done { completed_at; _ } -> completed_at
  | Masc_domain.Cancelled { cancelled_at; _ } -> cancelled_at
  | Masc_domain.InProgress { started_at; _ } -> started_at
  | Masc_domain.AwaitingVerification { submitted_at; _ } -> submitted_at
  | Masc_domain.Claimed { claimed_at; _ } -> claimed_at
  | Masc_domain.Todo -> task.created_at
;;

let task_completed_at (task : Masc_domain.task) =
  match task.task_status with
  | Masc_domain.Done { completed_at; _ } -> Some completed_at
  | Masc_domain.Cancelled { cancelled_at; _ } -> Some cancelled_at
  | Masc_domain.Todo
  | Masc_domain.Claimed _
  | Masc_domain.InProgress _
  | Masc_domain.AwaitingVerification _ -> None
;;

let task_execution_links_json (task : Masc_domain.task) =
  match task.contract with
  | Some contract -> Masc_domain.task_execution_links_to_yojson contract.links
  | None -> `Null
;;

(* RFC-0267 Phase 1: project the registry's canonical goal_id onto the wire.
   The task record carries no goal_id (the goal_task_links registry is SSOT);
   this is a read-time projection so the Work board can nest jobs under goals.
   A task may appear under multiple goals in the legacy registry — the first
   match is chosen deterministically and the multi-goal case is logged rather
   than hidden, surfacing the single-goal-per-task invariant violation. *)
let task_canonical_goal_id goal_task_index (task : Masc_domain.task) =
  match Hashtbl.find_opt goal_task_index task.id with
  | None | Some [] -> None
  | Some [ goal_id ] -> Some goal_id
  | Some (goal_id :: extra) ->
    Log.Dashboard.warn
      "[dashboard_execution] task %s linked to %d goals; projecting canonical %s (extra: %s)"
      task.id
      (1 + List.length extra)
      goal_id
      (String.concat "," extra);
    Some goal_id
;;

let task_json ~goal_task_index ?goal_id_read_error (task : Masc_domain.task) =
  let fields =
    match Masc_domain.task_to_yojson task with
    | `Assoc assoc -> assoc
    | _ -> []
  in
  let fields =
    assoc_upsert fields "assignee" (Json_util.string_opt_to_json (task_assignee task))
  in
  let fields = assoc_upsert fields "updated_at" (`String (task_updated_at task)) in
  let fields = assoc_upsert fields "execution_links" (task_execution_links_json task) in
  let fields =
    assoc_upsert
      fields
      "goal_id"
      (Json_util.string_opt_to_json (task_canonical_goal_id goal_task_index task))
  in
  let fields =
    assoc_upsert
      fields
      "goal_id_read_error"
      (Json_util.string_opt_to_json goal_id_read_error)
  in
  let fields =
    match task_completed_at task with
    | Some timestamp -> assoc_upsert fields "completed_at" (`String timestamp)
    | None -> List.remove_assoc "completed_at" fields
  in
  `Assoc fields
;;

let agent_json ~(model_map : (string, string) Hashtbl.t) (agent : Masc_domain.agent) =
  let profile = get_agent_profile agent.name in
  let model_value =
    match Hashtbl.find_opt model_map agent.name with
    | Some m when m <> "" -> `String m
    | _ -> `Null
  in
  `Assoc
    [ "name", `String agent.name
    ; "agent_type", `String agent.agent_type
    ; "status", `String (Masc_domain.string_of_agent_status agent.status)
    ; ( "current_task", Json_util.string_opt_to_json agent.current_task )
    ; "session_bound_at", `String agent.session_bound_at
    ; "last_seen", `String agent.last_seen
    ; "capabilities", `List (List.map (fun value -> `String value) agent.capabilities)
    ; "emoji", `String profile.emoji
    ; "koreanName", `String profile.korean_name
    ; "profile_errors", agent_profile_errors_json profile
    ; "profile_error_count", `Int (List.length profile.profile_errors)
    ; "model", model_value
    ]
;;

let message_json (message : Masc_domain.message) =
  `Assoc
    [ "from", `String message.from_agent
    ; "type", `String message.msg_type
    ; "content", `String message.content
    ; "mention", Json_util.string_opt_to_json message.mention
    ; "timestamp", `String message.timestamp
    ; "trace_context", Json_util.string_opt_to_json message.trace_context
    ; "expires_at", Json_util.float_opt_to_json message.expires_at
    ; "relevance", `String message.relevance
    ; "seq", `Int message.seq
    ]
;;

(** Maximum wall-clock time for a single dashboard render.
    Keep a real guard for PG stalls, but allow slow cold-start projections
    to finish at least once so cached surfaces can hydrate. The default
    (60s) is preserved by [Env_config_runtime.Dashboard.render_timeout_sec];
    operators can override via [MASC_DASHBOARD_RENDER_TIMEOUT_SEC]. *)
let render_timeout_s = Env_config_runtime.Dashboard.render_timeout_sec

let json_render ~effective_actor ~light ~config ~sw ~clock ~proc_mgr () =
  let ctx : _ Tool_operator.context =
    { config
    ; agent_name = effective_actor
    ; sw
    ; clock
    ; proc_mgr
    ; net = None
    ; mcp_session_id = None
    }
  in
  (* Yield between heavy phases so SSE / health-check fibers can progress *)
  Eio.Fiber.yield ();
  let t_start = Time_compat.now () in
  (* Phase markers are mutable so that the Fun.protect [finally] below can
         emit a partial render timing even when [json_render] raises (e.g.
         render timeout, PG stall propagated as exception).  Without this, the
         pathologically slow renders the metric is meant to surface stay
         invisible because the previous record_render_phase_timings call site
         was at the very end of the function and was skipped on raise. *)
  let t_after_snapshot : float option ref = ref None in
  let t_after_operations : float option ref = ref None in
  let t_after_enrich : float option ref = ref None in
  let t_after_data_load : float option ref = ref None in
  let n_keepers_emitted = ref 0 in
  let timings_emitted = ref false in
  let emit_render_timings () =
    if not !timings_emitted
    then (
      timings_emitted := true;
      let t_end = Time_compat.now () in
      let phase_ms_between start_opt end_opt =
        match start_opt, end_opt with
        | Some s, Some e -> (e -. s) *. 1000.0
        | _ -> 0.0
      in
      let timings : render_phase_timings_ms =
        { total_ms = (t_end -. t_start) *. 1000.0
        ; snapshot_ms =
            (match !t_after_snapshot with
             | Some t -> (t -. t_start) *. 1000.0
             | None -> 0.0)
        ; operations_ms = phase_ms_between !t_after_snapshot !t_after_operations
        ; enrich_ms = phase_ms_between !t_after_operations !t_after_enrich
        ; data_load_ms = phase_ms_between !t_after_enrich !t_after_data_load
        ; assemble_ms =
            (match !t_after_data_load with
             | Some s -> (t_end -. s) *. 1000.0
             | None -> 0.0)
        ; n_keepers = !n_keepers_emitted
        }
      in
      record_render_phase_timings timings;
      if timings.total_ms > 10000.0
      then
        Log.Dashboard.warn
          "[dashboard_execution] slow render: %s"
          (format_slow_render_timings timings)
      else
        Log.Dashboard.debug
          "[dashboard_execution] timing: total=%.0fms snapshot=%.0fms enrich=%.0fms \
           data_load=%.0fms assemble=%.0fms"
          timings.total_ms
          timings.snapshot_ms
          timings.enrich_ms
          timings.data_load_ms
          timings.assemble_ms)
  in
  Eio_guard.protect ~finally:emit_render_timings (fun () ->
    let snapshot_json =
      Dashboard_projection_cache.get_or_compute_snapshot_json
        ~config
        ~actor:(Some effective_actor)
        (fun actor_name ->
           Dashboard_projection_cache.operator_snapshot_json
             ~actor:actor_name
             ~view:"summary"
             ~include_messages:false
             ~include_keepers:true
             ~include_summary_fields:false
             ~lightweight_summary:true
             ctx)
    in
    t_after_snapshot := Some (Time_compat.now ());
    Eio.Fiber.yield ();
    (* Yield between heavy computation phases to prevent fiber starvation.
         Eio's cooperative scheduler needs explicit yields in CPU-bound paths
         so other fibers (SSE, health checks) can progress. *)
    Eio.Fiber.yield ();
    let tasks = tasks_safe config in
    (* RFC-0267 Phase 1: build the task→goals index once; task_json projects the
       canonical goal_id per task from it (registry is SSOT for the linkage). *)
    let goal_task_index, goal_task_links_read_error =
      match Workspace_goal_index.build_task_goal_index_for_config_result config with
      | Ok index -> index, None
      | Error msg ->
        let message = Workspace_goal_index.goal_task_links_read_failed_message msg in
        Log.Dashboard.warn
          "[dashboard_execution] goal-task link registry read failed: %s"
          message;
        Hashtbl.create 0, Some message
    in
    let operation_contexts = build_operation_contexts ~tasks in
    let session_contexts = [] in
    let execution_queue = build_execution_queue session_contexts operation_contexts in
    t_after_operations := Some (Time_compat.now ());
    let keepers =
      member_assoc "keepers" snapshot_json
      |> member_assoc "items"
      |> function
      | `List items ->
        (* #10710: enrich_keeper_with_diagnostic was being run as
               [List.map _ items] — strict N+1 against the keeper list.
               Field log: 14 keepers * 2.4s/keeper = 33s render walltime
               (4 of 11 slow renders had enrich at 70-99% of total).
               [enrich_keeper_with_diagnostic] reads each keeper's meta
               from its own file and computes per-keeper diagnostic JSON
               with no shared mutable state, so the work is embarrassingly
               parallel.

               [Eio.Fiber.List.map ~max_fibers] runs the enrich body
               cooperatively across a bounded fiber pool. The cap
               ([dashboard_enrich_max_fibers]) is intentionally below
               typical fleet size (14 today, growing) so we never burn
               more file descriptors / scheduler slots than the dashboard
               render strictly needs; raising it past ~8 buys little for
               disk-bound enrich workloads on a laptop and just makes the
               scheduler quantum thrash. *)
        Eio.Fiber.List.map
          ~max_fibers:dashboard_enrich_max_fibers
          (enrich_keeper_with_diagnostic ~config)
          items
      | _ -> []
    in
    t_after_enrich := Some (Time_compat.now ());
    n_keepers_emitted := List.length keepers;
    let execution_queue =
      merge_execution_queue execution_queue (build_keeper_execution_queue keepers)
    in
    Eio.Fiber.yield ();
    (* Load tasks/agents/messages — needed for worker_support_briefs.
         In light mode, tasks and messages are NOT serialized in the
         response payload (saves ~143KB) but are still loaded for
         worker_support_briefs computation. *)
    let agents = agents_safe config in
    let messages = messages_safe config in
    t_after_data_load := Some (Time_compat.now ());
    let now_ts = Time_compat.now () in
    let worker_rows =
      build_worker_support_briefs ~now_ts ~tasks ~agents ~messages session_contexts
    in
    let offline_worker_briefs, worker_support_briefs =
      List.partition
        (fun (row : worker_context) -> string_field "state" row.json = "offline")
        worker_rows
    in
    let continuity_rows = build_continuity_briefs ~now_ts keepers session_contexts in
    (* Operations: only active/paused, max 20 *)
    let active_ops =
      List.filter
        (fun (op : operation_context) ->
           let status = Json_util.assoc_string_opt "status" op.json in
           status = Some "active" || status = Some "paused")
        operation_contexts
    in
    let limited_ops = take 20 active_ops in
    (* Execution queue: top 10 priority items *)
    let limited_queue = take 10 execution_queue in
    let base_fields =
      let utf8_repair = Safe_ops.persistence_utf8_repair_stats () in
      [ "generated_at", `String (Masc_domain.now_iso ())
      ; "status", workspace_status_json config
      ; ( "projection_diagnostics"
        , `Assoc
            [ "surface", `String "execution"
            ; "workspace_root", `String config.base_path
            ; "workspace_path", `String config.workspace_path
            ; "persistence_sanitized_count", `Int utf8_repair.repaired_reads
            ; "persistence_sanitized_bytes", `Int utf8_repair.repaired_bytes
            ; ( "persistence_sanitized_paths_sample"
              , `List (List.map (fun path -> `String path) utf8_repair.path_samples) )
            ] )
      ; ( "execution_queue"
        , `List (List.map (fun (row : queue_context) -> row.json) limited_queue) )
      ; ( "operation_briefs"
        , `List (List.map (fun (row : operation_context) -> row.json) limited_ops) )
      ; ( "worker_support_briefs"
        , `List (List.map (fun (row : worker_context) -> row.json) worker_support_briefs)
        )
      ; ( "continuity_briefs"
        , `List (List.map (fun (row : continuity_context) -> row.json) continuity_rows) )
      ; ( "offline_worker_briefs"
        , `List (List.map (fun (row : worker_context) -> row.json) offline_worker_briefs)
        )
      ; ( "agents"
        , let model_map = model_map_of_keeper_rows keepers in
          `List (List.map (agent_json ~model_map) agents) )
      ; (* pipeline_stage is now included in the snapshot keepers_json,
             so no redundant read_meta + parse_agent_status needed here. *)
        "keepers", `List keepers
      ]
    in
    let now = Time_compat.now () in
    let recent_cutoff = now -. Masc_time_constants.day in
    (* 24 hours *)
    let active_tasks =
      List.filter
        (fun (t : Masc_domain.task) ->
           not (Masc_domain.task_status_is_terminal t.task_status))
        tasks
    in
    let recent_done =
      tasks
      |> List.filter (fun (t : Masc_domain.task) ->
        match t.task_status with
        | Masc_domain.Done { completed_at; _ } ->
          (match Masc_domain.parse_iso8601_opt completed_at with
           | Some ts -> ts >= recent_cutoff
           | None -> false)
        | Masc_domain.Cancelled { cancelled_at; _ } ->
          (match Masc_domain.parse_iso8601_opt cancelled_at with
           | Some ts -> ts >= recent_cutoff
           | None -> false)
        | _ -> false)
      |> take 20
    in
    (* Cap removed (2026-04-16): active_tasks is already bounded by
         how many tasks exist in state, and recent_done is capped at 20
         above. The previous [take 50] silently truncated the backlog in
         the dashboard planning view at exactly 50 entries, which surfaced
         as a "total tasks = 50" bug once the real backlog exceeded that
         number. The raw list is surfaced instead; frontend paginates. *)
    let all_visible = active_tasks @ recent_done in
    let task_fields =
      [ ( "tasks"
        , `List
            (List.map
               (task_json ~goal_task_index ?goal_id_read_error:goal_task_links_read_error)
               all_visible) )
      ; ( "goal_task_links_known"
        , `Bool (Option.is_none goal_task_links_read_error) )
      ; ( "goal_task_links_read_error"
        , Json_util.string_opt_to_json goal_task_links_read_error )
      ; ( "task_counts"
        , `Assoc
            [ "active", `Int (List.length active_tasks)
            ; "done_recent", `Int (List.length recent_done)
            ; "total", `Int (List.length tasks)
            ; "shown", `Int (List.length all_visible)
            ] )
      ]
    in
    (* #9766: phase breakdown is emitted by [emit_render_timings] in the
         Fun.protect [finally] above, so timeout/exception paths still
         surface partial render telemetry.  The slow-render WARN is also
         emitted from there, off the same captured timings. *)
    emit_render_timings ();
    if light
    then `Assoc (base_fields @ task_fields)
    else
      (* Full mode: include messages in addition to tasks *)
      `Assoc
        (base_fields
         @ task_fields
         @ [ "messages", `List (List.map message_json messages) ]))
;;

let json ?actor ?fixture ?(light = true) ~config ~sw ~clock ~proc_mgr () =
  let effective_actor = Dashboard_projection_cache.normalize_actor_name actor in
  match dashboard_fixture_name ?fixture () with
  | Some "execution_smoke" -> execution_smoke_fixture_json ()
  | _ ->
    (* Guard: abort render if it exceeds render_timeout_s.
       PG connection failures during render can block fibers for hours
       (observed: 11,018s render on 2026-03-21). *)
    (match
       Eio.Time.with_timeout clock render_timeout_s (fun () ->
         Ok (json_render ~effective_actor ~light ~config ~sw ~clock ~proc_mgr ()))
     with
     | Ok result -> result
     | Error `Timeout ->
       Log.Dashboard.error
         "[dashboard_execution] render timed out after %.0fs"
         render_timeout_s;
       `Assoc
         [ "generated_at", `String (Masc_domain.now_iso ())
         ; ( "error"
           , `String (Printf.sprintf "render timed out after %.0fs" render_timeout_s) )
         ; "status", workspace_status_json config
         ])
;;
