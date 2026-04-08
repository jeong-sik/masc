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

let task_summary_to_json (t : task_summary) : Yojson.Safe.t =
  `Assoc
    ([ ("task_id", `String t.task_id);
       ("title", `String t.title);
       ("status", `String t.status) ]
     @ (match t.assignee with
        | Some a -> [ ("assignee", `String a) ]
        | None -> []))

let to_json (ctx : team_context) : Yojson.Safe.t =
  `Assoc
    [ ("team_goal", `String ctx.team_goal);
      ("prior_decisions", `List (List.map (fun s -> `String s) ctx.prior_decisions));
      ("shared_findings", `List (List.map (fun s -> `String s) ctx.shared_findings));
      ("active_workers", `List (List.map (fun s -> `String s) ctx.active_workers));
      ("task_tree", `List (List.map task_summary_to_json ctx.task_tree)) ]

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
