(** Team_context — shared context for coordinated workers.
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

(** Shared findings file within the .masc directory. *)
let findings_path ~base_path =
  Filename.concat
    (Coord_utils.masc_dir_from_base_path ~base_path)
    "shared_findings.jsonl"

let persistence_surface = "team_context_findings"

let record_persistence_read_drop ~reason () =
  Prometheus.inc_counter Prometheus.metric_persistence_read_drops
    ~labels:[("surface", persistence_surface); ("reason", reason)]
    ()

let add_finding ~base_path ~worker_name ~finding =
  let path = findings_path ~base_path in
  let dir = Filename.dirname path in
  Fs_compat.mkdir_p dir;
  let entry =
    `Assoc
      [
        ("worker", `String worker_name);
        ("finding", `String finding);
        ("ts", `Float (Time_compat.now ()));
      ]
    |> Yojson.Safe.to_string
  in
  Fs_compat.append_file path (entry ^ "\n")

let load_findings ~base_path : string list =
  let path = findings_path ~base_path in
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
            else (
              record_persistence_read_drop
                ~reason:Safe_ops.persistence_read_drop_reason_invalid_payload ();
              None)
          with Yojson.Json_error _ ->
            record_persistence_read_drop
              ~reason:Safe_ops.persistence_read_drop_reason_entry_load_error ();
            None
      ) lines
    with Sys_error _ ->
      record_persistence_read_drop
        ~reason:Safe_ops.persistence_read_drop_reason_entry_load_error ();
      []

let build ~base_path =
  let shared_findings = load_findings ~base_path in
  { empty with shared_findings }

let truncate_list n lst =
  List.filteri (fun i _ -> i < n) lst

let has_visible_content ctx =
  String.trim ctx.team_goal <> ""
  || ctx.prior_decisions <> []
  || ctx.shared_findings <> []
  || ctx.active_workers <> []
  || ctx.task_tree <> []

let to_prompt_section ctx =
  if not (has_visible_content ctx) then ""
  else
    let buf = Buffer.create 512 in
    Buffer.add_string buf "--- Team Context ---\n";
    if String.trim ctx.team_goal <> "" then
      Printf.bprintf buf "Goal: %s\n" ctx.team_goal;
    (match truncate_list max_decisions ctx.prior_decisions with
     | [] -> ()
     | decisions ->
         Buffer.add_string buf "\nPrior decisions:\n";
         List.iter
           (fun d -> Printf.bprintf buf "- %s\n" d)
           decisions);
    (match truncate_list max_findings ctx.shared_findings with
     | [] -> ()
     | findings ->
         Buffer.add_string buf "\nTeam findings:\n";
         List.iter
           (fun f -> Printf.bprintf buf "- %s\n" f)
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
