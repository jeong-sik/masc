(** Team_context — shared context for team session workers.
    @since 3.0.0 *)

type task_summary = {
  task_id : string;
  title : string;
  status : string;
  assignee : string option;
}

type team_context = {
  team_goal : string;
  prior_decisions : string list;
  shared_findings : string list;
  active_workers : string list;
  task_tree : task_summary list;
}

let empty =
  {
    team_goal = "";
    prior_decisions = [];
    shared_findings = [];
    active_workers = [];
    task_tree = [];
  }

(** Max items kept for each list to bound prompt size. *)
let max_decisions = 3
let max_findings = 5
let max_tasks = 10
let findings_tail_max_bytes = 256 * 1024

(** Return the last [n] items without reversing the full list. *)
let take_last n items =
  if n <= 0 then []
  else
    let rec advance ahead behind gap =
      match ahead with
      | [] -> behind
      | _ :: ahead_tail when gap > 0 ->
          advance ahead_tail behind (gap - 1)
      | _ :: ahead_tail -> (
          match behind with
          | [] -> []
          | _ :: behind_tail -> advance ahead_tail behind_tail 0)
    in
    advance items items n

(** Shared findings file within the session directory. *)
let findings_path ~base_path ~team_session_id =
  Filename.concat
    (Filename.concat
       (Filename.concat base_path ".masc")
       ("session_" ^ team_session_id))
    "shared_findings.jsonl"

let add_finding ~base_path ~team_session_id ~worker_name ~finding =
  let path = findings_path ~base_path ~team_session_id in
  let dir = Filename.dirname path in
  Fs_compat.mkdir_p dir;
  let entry =
    Printf.sprintf {|{"worker":"%s","finding":"%s","ts":%.0f}|}
      (String.escaped worker_name)
      (String.escaped finding)
      (Time_compat.now ())
  in
  Fs_compat.append_file path (entry ^ "\n")

let load_findings ~base_path ~team_session_id : string list =
  let path = findings_path ~base_path ~team_session_id in
  if not (Sys.file_exists path) then []
  else
    let read_tail_lines () =
      try
        let fd = Unix.openfile path [ Unix.O_RDONLY ] 0 in
        Fun.protect
          ~finally:(fun () -> Unix.close fd)
          (fun () ->
            let stats = Unix.fstat fd in
            let file_size = stats.Unix.st_size in
            if file_size <= 0 then []
            else
              let bytes_to_read = min file_size findings_tail_max_bytes in
              let start_pos = max 0 (file_size - bytes_to_read) in
              ignore (Unix.lseek fd start_pos Unix.SEEK_SET);
              let buf = Bytes.create bytes_to_read in
              let rec read_loop offset remaining =
                if remaining <= 0 then offset
                else
                  match Unix.read fd buf offset remaining with
                  | 0 -> offset
                  | n -> read_loop (offset + n) (remaining - n)
              in
              let read_len = read_loop 0 bytes_to_read in
              if read_len <= 0 then []
              else
                let tail_chunk = Bytes.sub_string buf 0 read_len in
                let line_aligned_chunk =
                  if start_pos = 0 then tail_chunk
                  else
                    match String.index_opt tail_chunk '\n' with
                    | Some idx ->
                        String.sub tail_chunk (idx + 1)
                          (String.length tail_chunk - idx - 1)
                    (* If the bounded tail does not contain a full line boundary,
                       the remaining bytes are only a partial JSONL record and
                       must be dropped. *)
                    | None ->
                        Log.Misc.warn
                          "team_context.findings tail read dropped partial data for %s \
                           (%d/%d bytes read; increase findings_tail_max_bytes if \
                           this is expected)"
                          path read_len file_size;
                        ""
                in
                line_aligned_chunk
                |> String.split_on_char '\n'
                |> List.filter (fun line -> String.trim line <> ""))
      with
      | Unix.Unix_error _ | Sys_error _ -> []
    in
    Eio_guard.run_in_systhread read_tail_lines
    |> List.filter_map (fun line ->
           match Safe_ops.parse_json_safe ~context:"team_context.findings" line with
           | Error _ -> None
           | Ok json ->
               let open Yojson.Safe.Util in
               let worker =
                 json |> member "worker" |> to_string_option
                 |> Option.value ~default:"unknown"
               in
               let finding =
                 json |> member "finding" |> to_string_option
                 |> Option.value ~default:""
               in
               if finding <> "" then Some (Printf.sprintf "[%s] %s" worker finding)
               else None)
    |> take_last max_findings

let build ~base_path ~team_session_id =
  let room_config = Room.default_config base_path |> Room.config_with_resolved_scope in
  let session_opt =
    Team_session_store.load_session room_config team_session_id
  in
  match session_opt with
  | None -> { empty with team_goal = "(session not found)" }
  | Some session ->
      let team_goal = session.Team_session_types.goal in
      let active_workers =
        session.agent_names
        |> List.filteri (fun i _ -> i < 10)
      in
      let task_tree =
        session.planned_workers
        |> List.filteri (fun i _ -> i < max_tasks)
        |> List.map (fun (pw : Team_session_types.planned_worker) ->
               {
                 task_id = pw.spawn_agent;
                 title =
                   Option.value ~default:"(untitled)" pw.spawn_role;
                 status =
                   (match pw.execution_scope with
                    | Some scope ->
                        Team_session_types.execution_scope_to_string scope
                    | None -> "pending");
                 assignee = pw.runtime_actor;
               })
      in
      let shared_findings =
        load_findings ~base_path ~team_session_id
      in
      let prior_decisions =
        (* Extract from session events if available, otherwise empty *)
        []
      in
      {
        team_goal;
        prior_decisions;
        shared_findings;
        active_workers;
        task_tree;
      }

(* ── OAS Collaboration.t bridge ──────────────────────────────────
   Lossy projection: MASC team_session (47 fields) → OAS Collaboration.t (12 fields).
   MASC session_status has no Bootstrapping; planned_worker (16 fields) →
   Collaboration.participant (6 fields).

   New code should prefer Collaboration.t for cross-system interop.
   Existing team_session consumers remain unaffected. *)

let session_status_to_phase
    (s : Team_session_types.session_status)
    : Agent_sdk.Collaboration.phase =
  match s with
  | Running -> Active
  | Paused -> Waiting_on_participants
  | Completed -> Completed
  | Interrupted -> Failed
  | Failed -> Failed
  | Cancelled -> Cancelled

let execution_scope_to_participant_state
    (scope : Team_session_types.execution_scope option)
    : Agent_sdk.Collaboration.participant_state =
  match scope with
  | None -> Planned
  | Some Observe_only -> Joined
  | Some Limited_code_change -> Working
  | Some Autonomous -> Working

let add_json_string_if_present key value acc =
  match value with
  | Some text when String.trim text <> "" -> (key, `String (String.trim text)) :: acc
  | _ -> acc

let add_json_bool_if_present key value acc =
  match value with
  | Some flag -> (key, `Bool flag) :: acc
  | None -> acc

let add_json_int_if_present key value acc =
  match value with
  | Some n -> (key, `Int n) :: acc
  | None -> acc

let add_json_float_if_present key value acc =
  match value with
  | Some n -> (key, `Float n) :: acc
  | None -> acc

let count_assoc_to_json counts =
  `Assoc
    (counts
    |> List.map (fun (label, count) -> (label, `Int count))
    |> List.sort (fun (a, _) (b, _) -> compare a b))

type projected_worker_spec = {
  spawn_agent : string;
  runtime_actor : string option;
  spawn_role : string option;
  spawn_model : string option;
  execution_scope : string option;
  thinking_enabled : bool option;
  thinking_budget : int option;
  max_turns : int option;
  timeout_seconds : int option;
  worker_class : string option;
  parent_actor : string option;
  capsule_mode : string option;
  runtime_pool : string option;
  lane_id : string option;
  controller_level : string option;
  control_domain : string option;
  supervisor_actor : string option;
  task_profile : string option;
  risk_level : string option;
  routing_confidence : float option;
  routing_reason : string option;
  routing_escalated : bool;
}

type projected_session_metadata = {
  room_id : string;
  created_by : string;
  origin_kind : string;
  execution_scope : string;
  orchestration_mode : string;
  control_profile : string;
  scale_profile : string;
  instruction_profile : string;
  fallback_policy : string;
  communication_mode : string;
  alert_channel : string;
  duration_seconds : int;
  checkpoint_interval_sec : int;
  min_agents : int;
  auto_resume : bool;
  planned_worker_count : int;
  model_cascade : string list;
  worker_class_counts : (string * int) list;
  runtime_pool_counts : (string * int) list;
  lane_counts : (string * int) list;
  controller_level_counts : (string * int) list;
  control_domain_counts : (string * int) list;
  worker_specs : projected_worker_spec list;
}

type runtime_health = {
  base_path_exists : bool;
  room_initialized : bool;
  session_running : bool;
}

let projected_worker_spec_of_planned_worker
    (pw : Team_session_types.planned_worker) : projected_worker_spec =
  {
    spawn_agent = pw.spawn_agent;
    runtime_actor = pw.runtime_actor;
    spawn_role = pw.spawn_role;
    spawn_model = pw.spawn_model;
    execution_scope =
      Option.map Team_session_types.execution_scope_to_string pw.execution_scope;
    thinking_enabled = pw.thinking_enabled;
    thinking_budget = pw.thinking_budget;
    max_turns = pw.max_turns;
    timeout_seconds = pw.timeout_seconds;
    worker_class =
      Option.map Team_session_types.worker_class_to_string pw.worker_class;
    parent_actor = pw.parent_actor;
    capsule_mode =
      Option.map Team_session_types.capsule_mode_to_string pw.capsule_mode;
    runtime_pool = pw.runtime_pool;
    lane_id = pw.lane_id;
    controller_level =
      Option.map Team_session_types.controller_level_to_string
        pw.controller_level;
    control_domain =
      Option.map Team_session_types.control_domain_to_string pw.control_domain;
    supervisor_actor = pw.supervisor_actor;
    task_profile =
      Option.map Team_session_types.task_profile_to_string pw.task_profile;
    risk_level =
      Option.map Team_session_types.risk_level_to_string pw.risk_level;
    routing_confidence = pw.routing_confidence;
    routing_reason = pw.routing_reason;
    routing_escalated = pw.routing_escalated;
  }

let projected_session_metadata_of_session
    (session : Team_session_types.session) : projected_session_metadata =
  {
    room_id = session.room_id;
    created_by = session.created_by;
    origin_kind =
      Team_session_types.session_origin_kind_to_string session.origin_kind;
    execution_scope =
      Team_session_types.execution_scope_to_string session.execution_scope;
    orchestration_mode =
      Team_session_types.orchestration_mode_to_string
        session.orchestration_mode;
    control_profile =
      Team_session_types.control_profile_to_string session.control_profile;
    scale_profile =
      Team_session_types.scale_profile_to_string session.scale_profile;
    instruction_profile =
      Team_session_types.instruction_profile_to_string
        session.instruction_profile;
    fallback_policy =
      Team_session_types.fallback_policy_to_string session.fallback_policy;
    communication_mode =
      Team_session_types.communication_mode_to_string
        session.communication_mode;
    alert_channel =
      Team_session_types.alert_channel_to_string session.alert_channel;
    duration_seconds = session.duration_seconds;
    checkpoint_interval_sec = session.checkpoint_interval_sec;
    min_agents = session.min_agents;
    auto_resume = session.auto_resume;
    planned_worker_count = List.length session.planned_workers;
    model_cascade = session.model_cascade;
    worker_class_counts =
      Team_session_types.worker_class_counts session.planned_workers;
    runtime_pool_counts =
      Team_session_types.runtime_pool_counts session.planned_workers;
    lane_counts = Team_session_types.lane_counts session.planned_workers;
    controller_level_counts =
      Team_session_types.controller_level_counts session.planned_workers;
    control_domain_counts =
      Team_session_types.control_domain_counts session.planned_workers;
    worker_specs =
      List.map projected_worker_spec_of_planned_worker session.planned_workers;
  }

let projected_worker_spec_to_json (spec : projected_worker_spec) :
    Yojson.Safe.t =
  let fields =
    []
    |> add_json_string_if_present "runtime_actor" spec.runtime_actor
    |> add_json_string_if_present "spawn_role" spec.spawn_role
    |> add_json_string_if_present "spawn_model" spec.spawn_model
    |> add_json_string_if_present "execution_scope" spec.execution_scope
    |> add_json_string_if_present "worker_class" spec.worker_class
    |> add_json_string_if_present "parent_actor" spec.parent_actor
    |> add_json_string_if_present "capsule_mode" spec.capsule_mode
    |> add_json_string_if_present "runtime_pool" spec.runtime_pool
    |> add_json_string_if_present "lane_id" spec.lane_id
    |> add_json_string_if_present "controller_level" spec.controller_level
    |> add_json_string_if_present "control_domain" spec.control_domain
    |> add_json_string_if_present "supervisor_actor" spec.supervisor_actor
    |> add_json_string_if_present "task_profile" spec.task_profile
    |> add_json_string_if_present "risk_level" spec.risk_level
    |> add_json_string_if_present "routing_reason" spec.routing_reason
    |> add_json_bool_if_present "thinking_enabled" spec.thinking_enabled
    |> add_json_int_if_present "thinking_budget" spec.thinking_budget
    |> add_json_int_if_present "max_turns" spec.max_turns
    |> add_json_int_if_present "timeout_seconds" spec.timeout_seconds
    |> add_json_float_if_present "routing_confidence" spec.routing_confidence
  in
  `Assoc
    (List.rev
       (("spawn_agent", `String spec.spawn_agent)
        :: ("routing_escalated", `Bool spec.routing_escalated)
        :: fields))

let metadata_of_session_projection (projection : projected_session_metadata) :
    (string * Yojson.Safe.t) list =
  [
    ("room_id", `String projection.room_id);
    ("created_by", `String projection.created_by);
    ("origin_kind", `String projection.origin_kind);
    ("execution_scope", `String projection.execution_scope);
    ("orchestration_mode", `String projection.orchestration_mode);
    ("control_profile", `String projection.control_profile);
    ("scale_profile", `String projection.scale_profile);
    ("instruction_profile", `String projection.instruction_profile);
    ("fallback_policy", `String projection.fallback_policy);
    ("communication_mode", `String projection.communication_mode);
    ("alert_channel", `String projection.alert_channel);
    ("duration_seconds", `Int projection.duration_seconds);
    ("checkpoint_interval_sec", `Int projection.checkpoint_interval_sec);
    ("min_agents", `Int projection.min_agents);
    ("auto_resume", `Bool projection.auto_resume);
    ("planned_worker_count", `Int projection.planned_worker_count);
    ("model_cascade", `List (List.map (fun model -> `String model) projection.model_cascade));
    ("worker_class_counts", count_assoc_to_json projection.worker_class_counts);
    ("runtime_pool_counts", count_assoc_to_json projection.runtime_pool_counts);
    ("lane_counts", count_assoc_to_json projection.lane_counts);
    ( "controller_level_counts",
      count_assoc_to_json projection.controller_level_counts );
    ("control_domain_counts", count_assoc_to_json projection.control_domain_counts);
    ( "worker_specs",
      `List (List.map projected_worker_spec_to_json projection.worker_specs) );
  ]

let runtime_health_to_json (health : runtime_health) =
  `Assoc
    [
      ("base_path_exists", `Bool health.base_path_exists);
      ("room_initialized", `Bool health.room_initialized);
      ("session_running", `Bool health.session_running);
      ( "ready",
        `Bool
          (health.base_path_exists && health.room_initialized
         && health.session_running) );
    ]

let replace_metadata_field key value metadata =
  let remaining =
    List.filter (fun (existing, _) -> not (String.equal existing key)) metadata
  in
  (key, value) :: remaining

let with_runtime_health
    (collaboration : Agent_sdk.Collaboration.t)
    (health : runtime_health) : Agent_sdk.Collaboration.t =
  {
    collaboration with
    metadata =
      replace_metadata_field "runtime_health" (runtime_health_to_json health)
        collaboration.metadata;
  }

let planned_worker_summary (pw : Team_session_types.planned_worker) : string option =
  let parts = ref [] in
  let add label value =
    if String.trim value <> "" then
      parts := (label ^ "=" ^ value) :: !parts
  in
  add "role" (Option.value ~default:"" pw.spawn_role);
  add "actor" (Option.value ~default:"" pw.runtime_actor);
  add "model" (Option.value ~default:"" pw.spawn_model);
  add "scope"
    (match pw.execution_scope with
    | Some scope -> Team_session_types.execution_scope_to_string scope
    | None -> "");
  add "max_turns"
    (match pw.max_turns with
    | Some turns -> string_of_int turns
    | None -> "");
  add "class"
    (match pw.worker_class with
     | Some worker_class -> Team_session_types.worker_class_to_string worker_class
     | None -> "");
  add "pool" (Option.value ~default:"" pw.runtime_pool);
  add "lane" (Option.value ~default:"" pw.lane_id);
  add "domain"
    (match pw.control_domain with
     | Some domain -> Team_session_types.control_domain_to_string domain
     | None -> "");
  add "risk"
    (match pw.risk_level with
     | Some risk -> Team_session_types.risk_level_to_string risk
     | None -> "");
  add "routing"
    (match pw.routing_confidence with
     | Some confidence -> Printf.sprintf "%.2f" confidence
     | None -> "");
  match List.rev !parts with
  | [] -> None
  | parts -> Some (String.concat "; " parts)

let planned_worker_to_participant
    (pw : Team_session_types.planned_worker)
    : Agent_sdk.Collaboration.participant =
  {
    name = pw.spawn_agent;
    role = pw.spawn_role;
    state = execution_scope_to_participant_state pw.execution_scope;
    joined_at = None;
    finished_at = None;
    summary = planned_worker_summary pw;
  }

(** Project a MASC team session into an OAS {!Agent_sdk.Collaboration.t}.

    This is a lossy projection: planned_worker (16 fields) compresses to
    participant (6 fields).  MASC has no explicit contributions or artifacts
    list in the session record, so those are empty.

    [shared_context] is populated from [shared_findings] if available. *)
let collaboration_of_session
    ~base_path
    (session : Team_session_types.session)
    : Agent_sdk.Collaboration.t =
  let ctx = Agent_sdk.Context.create () in
  (* Inject shared findings into context *)
  let findings =
    load_findings ~base_path ~team_session_id:session.session_id
  in
  List.iteri (fun i f ->
    Agent_sdk.Context.set ctx
      (Printf.sprintf "finding_%d" i) (`String f)
  ) findings;
  let projection = projected_session_metadata_of_session session in
  {
    id = session.session_id;
    goal = session.goal;
    phase = session_status_to_phase session.status;
    participants =
      List.map planned_worker_to_participant session.planned_workers;
    artifacts = [];
    contributions = [];
    shared_context = ctx;
    created_at = session.started_at;
    updated_at =
      (match session.last_event_at with
       | Some t -> t
       | None -> session.started_at);
    outcome = session.stop_reason;
    max_participants = None;
    metadata = metadata_of_session_projection projection;
  }

let truncate_list n lst =
  List.filteri (fun i _ -> i < n) lst

let to_prompt_section ctx =
  if ctx.team_goal = "" then ""
  else
    let buf = Buffer.create 512 in
    Buffer.add_string buf "--- Team Context ---\n";
    Buffer.add_string buf (Printf.sprintf "Goal: %s\n" ctx.team_goal);
    (match truncate_list max_decisions ctx.prior_decisions with
     | [] -> ()
     | decisions ->
         Buffer.add_string buf "\nPrior decisions:\n";
         List.iter
           (fun d -> Buffer.add_string buf (Printf.sprintf "- %s\n" d))
           decisions);
    (match truncate_list max_findings ctx.shared_findings with
     | [] -> ()
     | findings ->
         Buffer.add_string buf "\nTeam findings:\n";
         List.iter
           (fun f -> Buffer.add_string buf (Printf.sprintf "- %s\n" f))
           findings);
    (match ctx.active_workers with
     | [] -> ()
     | workers ->
         Buffer.add_string buf
           (Printf.sprintf "\nActive workers: %s\n"
              (String.concat ", " workers)));
    (match truncate_list max_tasks ctx.task_tree with
     | [] -> ()
     | tasks ->
         Buffer.add_string buf "\nTasks:\n";
         List.iter
           (fun t ->
             let assignee_str =
               match t.assignee with
               | Some a -> Printf.sprintf " (%s)" a
               | None -> ""
             in
             Buffer.add_string buf
               (Printf.sprintf "- [%s] %s: %s%s\n" t.status t.task_id
                  t.title assignee_str))
           tasks);
    Buffer.add_string buf "--- End Team Context ---";
    Buffer.contents buf
