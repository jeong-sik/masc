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
    try
      let content = Fs_compat.load_file path in
      let lines = String.split_on_char '\n' content in
      List.filter_map (fun line ->
        if String.trim line = "" then None
        else
          try
            let json = Yojson.Safe.from_string line in
            let open Yojson.Safe.Util in
            let worker = json |> member "worker" |> to_string_option
                         |> Option.value ~default:"unknown" in
            let finding = json |> member "finding" |> to_string_option
                          |> Option.value ~default:"" in
            if finding <> "" then
              Some (Printf.sprintf "[%s] %s" worker finding)
            else None
          with Yojson.Json_error _ -> None
      ) lines
    with Sys_error _ -> []

let build ~base_path ~team_session_id =
  let room_config = Room.default_config base_path in
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

let planned_worker_to_participant
    (pw : Team_session_types.planned_worker)
    : Agent_sdk.Collaboration.participant =
  {
    name = pw.spawn_agent;
    role = pw.spawn_role;
    state = execution_scope_to_participant_state pw.execution_scope;
    joined_at = None;
    finished_at = None;
    summary = None;
  }

(** Project a MASC team session into an OAS {!Agent_sdk.Collaboration.t}.

    This is a lossy projection: planned_worker (16 fields) compresses to
    participant (6 fields).  MASC has no explicit votes or artifacts list
    in the session record, so those are empty.

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
  {
    id = session.session_id;
    goal = session.goal;
    phase = session_status_to_phase session.status;
    participants =
      List.map planned_worker_to_participant session.planned_workers;
    artifacts = [];
    votes = [];
    shared_context = ctx;
    created_at = session.started_at;
    updated_at =
      (match session.last_event_at with
       | Some t -> t
       | None -> session.started_at);
    outcome = session.stop_reason;
    max_participants = None;
    metadata =
      [("room_id", `String session.room_id);
       ("orchestration_mode",
        `String (Team_session_types.orchestration_mode_to_string
                   session.orchestration_mode))];
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
