include Dashboard_execution_sessions

(** Keeper lifecycle phase — deterministic from status, context ratio,
    and activity timestamps. Serialized to string at JSON boundary only. *)
type keeper_lifecycle =
  | Lc_offline
  | Lc_handoff_imminent
  | Lc_preparing
  | Lc_compacting
  | Lc_active
  | Lc_idle

let keeper_lifecycle_to_string = function
  | Lc_offline -> "offline"
  | Lc_handoff_imminent -> "handoff-imminent"
  | Lc_preparing -> "preparing"
  | Lc_compacting -> "compacting"
  | Lc_active -> "active"
  | Lc_idle -> "idle"

(** Keeper execution state — derived from lifecycle and turn metrics.
    Maps 1:1 with [tone] but serialized separately for dashboard consumers. *)
type keeper_exec_state = Exec_critical | Exec_warning | Exec_healthy

let keeper_exec_state_to_string = function
  | Exec_critical -> "critical"
  | Exec_warning -> "warning"
  | Exec_healthy -> "healthy"

(** Signal-age guardrail thresholds (seconds).
    SSOT: [Env_config.Dashboard] module (configurable via env vars). *)
let signal_stale_sec = Env_config.Dashboard.signal_stale_sec
let signal_quiet_sec = Env_config.Dashboard.signal_quiet_sec
let signal_live_sec  = Env_config.Dashboard.signal_live_sec

(** Keeper context-ratio lifecycle thresholds.
    SSOT: [Env_config.Dashboard] module. *)
let ctx_handoff_imminent = Env_config.Dashboard.ctx_handoff_imminent
let ctx_preparing        = Env_config.Dashboard.ctx_preparing
let ctx_compacting       = Env_config.Dashboard.ctx_compacting

(** Keeper action-age threshold (seconds).
    SSOT: [Env_config.Dashboard] module. *)
let keeper_action_stale_sec = Env_config.Dashboard.keeper_action_stale_sec

let task_assignee (task : Masc_domain.task) =
  match task.task_status with
  | Claimed { assignee; _ } | InProgress { assignee; _ }
  | AwaitingVerification { assignee; _ } | Done { assignee; _ } ->
      Some assignee
  | Todo | Cancelled _ -> None

let last_message_map messages =
  let table = Hashtbl.create 32 in
  List.iter
    (fun (message : Masc_domain.message) ->
      let key = String.lowercase_ascii (String.trim message.from_agent) in
      let ts = Masc_domain.parse_iso8601 message.timestamp in
      match Hashtbl.find_opt table key with
      | Some (existing_ts, _) when existing_ts >= ts -> ()
      | _ -> Hashtbl.replace table key (ts, message))
    messages;
  table

let active_task_count tasks agent_name =
  List.fold_left
    (fun acc (task : Masc_domain.task) ->
      match task.task_status, task_assignee task with
      | (Claimed _ | InProgress _), Some assignee when assignee = agent_name -> acc + 1
      | _ -> acc)
    0 tasks

let worker_state_of_agent
    ~(now_ts : float)
    ~(messages_by_agent : (string, float * Masc_domain.message) Hashtbl.t)
    ~(tasks : Masc_domain.task list)
    ?related_session_id ?related_operation_id
    (agent : Masc_domain.agent) : worker_context =
  let key = String.lowercase_ascii (String.trim agent.name) in
  let message_opt = Hashtbl.find_opt messages_by_agent key in
  let last_seen_ts =
    parse_iso_opt (trim_to_option agent.last_seen) |> Option.value ~default:0.0
  in
  let last_message_ts =
    match message_opt with
    | Some (ts, _) -> ts
    | None -> 0.0
  in
  let last_signal_ts = Float.max last_seen_ts last_message_ts in
  let last_signal_at =
    if last_signal_ts <= 0.0 then None
    else if last_message_ts >= last_seen_ts then
      match message_opt with
      | Some (_, message) -> trim_to_option message.timestamp
      | None -> trim_to_option agent.last_seen
    else
      trim_to_option agent.last_seen
  in
  let signal_age_s =
    if last_signal_ts > 0.0 then max 0.0 (now_ts -. last_signal_ts)
    else infinity
  in
  let signal_truth =
    if last_signal_ts <= 0.0 then
      "absent"
    else if signal_age_s <= signal_live_sec then
      "live"
    else
      "stale"
  in
  let evidence_source =
    if last_message_ts > 0.0 && last_message_ts >= last_seen_ts then
      "message"
    else if last_seen_ts > 0.0 then
      "presence"
    else
      "none"
  in
  let active_task_count = active_task_count tasks agent.name in
  let recent_output_preview =
    match message_opt with
    | Some (_, message) -> trim_to_option (compact_text message.content)
    | None -> None
  in
  let has_work =
    Option.is_some (trim_to_option (Option.value ~default:"" agent.current_task))
    || active_task_count > 0
  in
  let status_string = Masc_domain.string_of_agent_status agent.status in
  let (state, tone, note) =
    match agent.status with
    | Masc_domain.Inactive ->
        ( "offline",
          Tone_bad,
          if last_signal_ts > 0.0 then "Offline or inactive" else "No recent presence" )
    | Masc_domain.Busy | Masc_domain.Active | Masc_domain.Listening ->
        if signal_age_s > signal_stale_sec then
          ( "quiet",
            Tone_bad,
            if has_work then "Working without a fresh signal" else "No fresh agent signal" )
        else if has_work then
          if signal_age_s > signal_quiet_sec then
            ("quiet", Tone_warn, "Execution looks quiet for too long")
          else
            ("working", Tone_ok, "Task and live signal aligned")
        else if signal_age_s > signal_quiet_sec then
          ("quiet", Tone_warn, "Quiet but still reachable")
        else
          ("watching", Tone_ok, "Standing by for the next task")
  in
  let focus =
    match trim_to_option (Option.value ~default:"" agent.current_task) with
    | Some value -> value
    | None ->
        if active_task_count > 0 then
          Printf.sprintf "%d claimed tasks waiting for explicit current_task"
            active_task_count
        else
          Option.value ~default:"Idle / waiting for assignment" recent_output_preview
  in
  let (emoji, korean_name) = get_agent_identity agent.name in
  {
    tone_rank = tone_rank tone;
    last_signal_ts;
    related_session_id;
    json =
      `Assoc
        [
          ("name", `String agent.name);
          ("agent_name", `String agent.name);
          ("keeper_name",
            match agent.meta with
            | Some meta -> json_string_option meta.keeper_name
            | None -> `Null);
          ("keeper_id",
            match agent.meta with
            | Some meta -> json_string_option meta.keeper_id
            | None -> `Null);
          ("status", `String status_string);
          ("tone", `String (string_of_tone tone));
          ("state", `String state);
          ("note", `String note);
          ("focus", `String focus);
          ("last_signal_at", json_string_option last_signal_at);
          ("last_signal_age_sec", if Float.is_finite signal_age_s then `Int (int_of_float signal_age_s) else `Null);
          ("signal_truth", `String signal_truth);
          ("evidence_source", `String evidence_source);
          ("active_task_count", `Int active_task_count);
          ("related_session_id", json_string_option related_session_id);
          ("related_operation_id", json_string_option related_operation_id);
          ("emoji", `String emoji);
          ("korean_name", `String korean_name);
          ("model", `Null);
          ("recent_output_preview", json_string_option recent_output_preview);
          ("recent_event", json_string_option recent_output_preview);
        ];
  }

let continuity_row_of_keeper ~(now_ts : float) ?related_session_id keeper :
    continuity_context =
  let name = string_field "name" keeper in
  let agent_name =
    match trim_to_option (string_field "agent_name" keeper) with
    | Some value -> value
    | None -> name
  in
  let audit = tool_audit_snapshot agent_name in
  let agent = member_assoc "agent" keeper in
  let status = string_field ~default:"unknown" "status" keeper in
  let context_ratio =
    match member_assoc "context_ratio" keeper with
    | `Float value -> Some value
    | `Int value -> Some (float_of_int value)
    | _ -> None
  in
  let last_action_at =
    trim_to_option (string_field "last_autonomous_action_at" keeper)
  in
  let last_heartbeat_at =
    latest_iso_timestamp
      [
        trim_to_option (string_field "updated_at" keeper);
        trim_to_option (string_field "last_seen" agent);
        trim_to_option (string_field "tool_audit_at" keeper);
        audit.tool_audit_at;
      ]
  in
  let last_signal_at = latest_iso_timestamp [ last_action_at; last_heartbeat_at ] in
  let last_action_ts = parse_iso_opt last_action_at |> Option.value ~default:0.0 in
  let last_signal_ts = parse_iso_opt last_signal_at |> Option.value ~default:0.0 in
  let last_action_age_s =
    if last_action_ts > 0.0 then max 0.0 (now_ts -. last_action_ts)
    else infinity
  in
  let effective_activity_age_s =
    if last_action_ts > 0.0 then last_action_age_s
    else if last_signal_ts > 0.0 then max 0.0 (now_ts -. last_signal_ts)
    else infinity
  in
  let autonomous_action_count = int_field "autonomous_action_count" keeper in
  let autonomous_turn_count = int_field "autonomous_turn_count" keeper in
  let noop_turn_count = int_field "noop_turn_count" keeper in
  let turn_count = int_field "turn_count" keeper in
  let generation = int_field "generation" keeper in
  let goal_count = List.length (list_field "active_goal_ids" keeper) in
  let lifecycle =
    if is_keeper_offline status then Lc_offline
    else if Option.value ~default:0.0 context_ratio >= ctx_handoff_imminent then Lc_handoff_imminent
    else if Option.value ~default:0.0 context_ratio >= ctx_preparing then Lc_preparing
    else if Option.value ~default:0.0 context_ratio >= ctx_compacting then Lc_compacting
    else if last_action_ts > 0.0 then Lc_active
    else if last_signal_ts > 0.0 then Lc_idle
    else Lc_idle
  in
  let (state, tone, note) =
    if is_keeper_offline status then
      (Exec_critical, Tone_bad, "keeper 오프라인")
    else
      match lifecycle with
      | Lc_handoff_imminent ->
          (Exec_critical, Tone_bad, "핸드오프 임박")
      | Lc_preparing | Lc_compacting ->
          (Exec_warning, Tone_warn, "연속성 압력이 높습니다")
      | Lc_offline | Lc_active | Lc_idle ->
          if autonomous_turn_count = 0 && turn_count > 0 then
            (Exec_warning, Tone_warn,
             Printf.sprintf "자율 턴 없음 (턴 %d회 수행)" turn_count)
          else if effective_activity_age_s >= keeper_action_stale_sec then
            (Exec_warning, Tone_warn,
             Printf.sprintf "마지막 활동 %.0f시간 전" (effective_activity_age_s /. 3600.0))
          else
            (Exec_healthy, Tone_ok, "정상 동작 중")
  in
  let continuity =
    Printf.sprintf "Gen %d · Turns %d · Auto turns %d · Tool actions %d · Goals %d"
      generation turn_count autonomous_turn_count autonomous_action_count goal_count
  in
  let focus =
    match trim_to_option (string_field "short_goal" keeper) with
    | Some value -> value
    | None -> (
        match trim_to_option (string_field "goal" keeper) with
        | Some value -> value
        | None -> "현재 포커스 없음")
  in
  let recent_input_preview =
    trim_to_option (string_field "recent_input_preview" keeper)
  in
  let recent_output_preview =
    trim_to_option (string_field "recent_output_preview" keeper)
    |> option_or_else (fun () -> trim_to_option (string_field "last_proactive_preview" keeper))
  in
  let recent_tool_names =
    let keeper_tools = string_list_of_field "recent_tool_names" keeper in
    (if keeper_tools <> [] then keeper_tools else audit.latest_tool_names)
    |> cap_string_list
  in
  let allowed_tool_names =
    let keeper_tools = string_list_of_field "allowed_tool_names" keeper in
    if keeper_tools <> [] then keeper_tools else audit.allowed_tool_names
  in
  let latest_tool_names =
    let keeper_tools = string_list_of_field "latest_tool_names" keeper in
    (if keeper_tools <> [] then keeper_tools else audit.latest_tool_names)
    |> cap_string_list
  in
  let latest_action_source =
    trim_to_option (string_field "latest_action_source" keeper)
    |> option_or_else (fun () -> audit.latest_action_source)
  in
  let skill_route_summary = skill_route_summary_of_keeper keeper in
  let (emoji, korean_name) = get_agent_identity name in
  {
    tone_rank = tone_rank tone;
    last_signal_ts;
    related_session_id;
    json =
      `Assoc
        ([
           ("name", `String name);
           ("agent_name", member_assoc "agent_name" keeper);
           ("keeper_id", member_assoc "keeper_id" keeper);
           ("status", `String status);
           ("tone", `String (string_of_tone tone));
           ("state", `String (keeper_exec_state_to_string state));
           ("note", `String note);
           ("focus", `String focus);
           ("last_signal_at", json_string_option last_signal_at);
           ("last_autonomous_action_at", json_string_option last_signal_at);
           ("generation", member_assoc "generation" keeper);
           ("turn_count", member_assoc "turn_count" keeper);
           ("context_ratio", option_to_json (fun value -> `Float value) context_ratio);
           ("continuity", `String continuity);
           ("lifecycle", `String (keeper_lifecycle_to_string lifecycle));
           ("related_session_id", json_string_option related_session_id);
           ("recent_input_preview", json_string_option recent_input_preview);
           ("recent_output_preview", json_string_option recent_output_preview);
           ("recent_tool_names", string_list_json recent_tool_names);
           ("latest_tool_names", string_list_json latest_tool_names);
         ]
        @ tool_preview_fields "allowed_tool" allowed_tool_names
        @ [
            ("latest_tool_call_count", option_to_json (fun value -> `Int value) audit.latest_tool_call_count);
            ("latest_action_source", json_string_option latest_action_source);
            ("tool_audit_source", json_string_option audit.tool_audit_source);
            ("tool_audit_at", json_string_option audit.tool_audit_at);
            ("autonomous_action_count", `Int autonomous_action_count);
            ("autonomous_turn_count", `Int autonomous_turn_count);
            ("noop_turn_count", `Int noop_turn_count);
            ("last_heartbeat_at", json_string_option last_heartbeat_at);
            ("proactive_enabled", member_assoc "proactive_enabled" keeper);
            ("proactive_idle_sec", member_assoc "proactive_idle_sec" keeper);
            ("proactive_cooldown_sec", member_assoc "proactive_cooldown_sec" keeper);
            ("last_proactive_preview", member_assoc "last_proactive_preview" keeper);
            ("continuity_summary", `String (
              match trim_to_option (string_field "continuity_summary" keeper) with
              | Some s -> s
              | None ->
                if autonomous_turn_count = 0 && turn_count = 0 then
                  "아직 활동 기록이 없습니다"
                else if autonomous_turn_count = 0 then
                  Printf.sprintf "대기 중 (턴 %d회, 자율 턴 0회)" turn_count
                else
                  let noop_note =
                    if noop_turn_count > 0 then
                      Printf.sprintf " · noop %d회" noop_turn_count
                    else ""
                  in
                  Printf.sprintf "자율 턴 %d회, 도구 행동 %d회, 턴 %d회, 세대 %d%s"
                    autonomous_turn_count autonomous_action_count turn_count generation noop_note));
            ("skill_route_summary", json_string_option skill_route_summary);
            ( "model",
              match trim_to_option (string_field "active_model" keeper) with
              | Some value -> `String value
              | None -> `Null );
            ("emoji", `String emoji);
            ("korean_name", `String korean_name);
            ("skill_reason", json_string_option (trim_to_option (string_field "goal" keeper)));
          ]);
  }

(* Issue #8645: removed dead [operation_severity ~status ~blocker_summary]
   helper — zero callers in lib/test, not exposed via .mli. The body
   also carried the #8605 anti-pattern (catch-all to [Tone_ok]). If
   future code needs status-based severity, re-introduce with a Variant
   input + exhaustive match instead of a string. *)

let task_operation_status (task : Masc_domain.task) =
  match task.task_status with
  | Masc_domain.Todo | Masc_domain.Claimed _ | Masc_domain.InProgress _ -> Some "active"
  | Masc_domain.AwaitingVerification _ -> Some "paused"
  | Masc_domain.Done _ | Masc_domain.Cancelled _ -> None

let task_operation_severity (task : Masc_domain.task) =
  match task.task_status with
  | Masc_domain.AwaitingVerification _ -> Tone_warn
  | Masc_domain.Todo | Masc_domain.Claimed _ | Masc_domain.InProgress _ -> Tone_ok
  | Masc_domain.Done _ | Masc_domain.Cancelled _ -> Tone_ok

let task_operation_updated_at (task : Masc_domain.task) =
  match task.task_status with
  | Masc_domain.Done { completed_at; _ } -> completed_at
  | Masc_domain.Cancelled { cancelled_at; _ } -> cancelled_at
  | Masc_domain.InProgress { started_at; _ } -> started_at
  | Masc_domain.AwaitingVerification { submitted_at; _ } -> submitted_at
  | Masc_domain.Claimed { claimed_at; _ } -> claimed_at
  | Masc_domain.Todo -> task.created_at

let task_operation_links (task : Masc_domain.task) =
  match task.contract with
  | Some contract -> contract.links
  | None -> { Masc_domain.operation_id = None; session_id = None; autoresearch_loop_id = None }

let task_operation_id (task : Masc_domain.task) =
  let links = task_operation_links task in
  match trim_to_option (Option.value ~default:"" links.operation_id) with
  | Some operation_id -> operation_id
  | None -> task.id

let build_operation_contexts ~(tasks : Masc_domain.task list) =
  tasks
  |> List.filter_map (fun (task : Masc_domain.task) ->
         match task_operation_status task with
         | None -> None
         | Some status ->
           let links = task_operation_links task in
           let operation_id = task_operation_id task in
           let updated_at = task_operation_updated_at task in
           let severity = task_operation_severity task in
           let stage = Option.map Task_stage.to_string task.stage in
           let linked_session_id =
             Option.bind links.session_id (fun value -> trim_to_option value)
           in
           let last_seen_ts =
             parse_iso_opt (Some updated_at) |> Option.value ~default:0.0
           in
           Some
             {
               operation_id;
               severity;
               last_seen_ts;
               linked_session_id;
               linked_detachment_id = None;
               json =
                 `Assoc
                   [
                     ("operation_id", `String operation_id);
                     ("status", `String status);
                     ("task_status", `String (Masc_domain.task_status_to_string task.task_status));
                     ("stage", json_string_option stage);
                     ("objective", `String task.title);
                     ("updated_at", `String updated_at);
                     ("source", `String "task_contract");
                     ("task_id", `String task.id);
                     ("severity", `String (string_of_tone severity));
                     ("linked_session_id", json_string_option linked_session_id);
                     ("linked_detachment_id", `Null);
                     ( "handoff",
                       handoff_json ~surface:"dashboard_execution"
                         ?operation_id:(Some operation_id)
                         ~label:"Open task"
                         ~target_type:"task"
                         ~target_id:task.id
                         ~focus_kind:"task"
                         () );
                   ];
             })
  |> List.sort (fun left right ->
         let by_tone = Int.compare (tone_rank right.severity) (tone_rank left.severity) in
         if by_tone <> 0 then by_tone
         else Float.compare right.last_seen_ts left.last_seen_ts)

let build_worker_support_briefs ~(now_ts : float) ~(tasks : Masc_domain.task list)
    ~(agents : Masc_domain.agent list) ~(messages : Masc_domain.message list) session_contexts :
    worker_context list =
  let messages_by_agent = last_message_map messages in
  agents
  |> List.map (fun (agent : Masc_domain.agent) ->
         let related =
           related_session_for_member session_contexts agent.name
         in
         let related_session_id =
           match related with
           | Some session -> Some session.session_id
           | None -> None
         in
         let related_operation_id =
           match related with
           | Some session -> session.linked_operation_id
           | None -> None
         in
         worker_state_of_agent ~now_ts ~messages_by_agent ~tasks ?related_session_id
           ?related_operation_id agent)
  |> List.filter (fun (row : worker_context) ->
         row.related_session_id <> None || string_field "tone" row.json <> "ok")
  |> List.sort (fun (left : worker_context) (right : worker_context) ->
         let by_tone = Int.compare right.tone_rank left.tone_rank in
         if by_tone <> 0 then by_tone
         else Float.compare right.last_signal_ts left.last_signal_ts)

let build_continuity_briefs ~(now_ts : float) keepers session_contexts :
    continuity_context list =
  keepers
  |> List.filter_map (fun keeper ->
         let name = string_field "name" keeper in
         if name = "" then None
         else
           let related_session =
             related_session_for_member session_contexts name
           in
           let related_session_id =
             match related_session with
             | Some session -> Some session.session_id
             | None -> (
                 match trim_to_option (string_field "agent_name" keeper) with
                 | Some agent_name -> (
                     match related_session_for_member session_contexts agent_name with
                     | Some session -> Some session.session_id
                     | None -> None)
                 | None -> None)
           in
           let row =
             continuity_row_of_keeper ~now_ts ?related_session_id keeper
           in
           Some row)
  |> List.sort (fun (left : continuity_context) (right : continuity_context) ->
         let by_tone = Int.compare right.tone_rank left.tone_rank in
         if by_tone <> 0 then by_tone
         else Float.compare right.last_signal_ts left.last_signal_ts)
