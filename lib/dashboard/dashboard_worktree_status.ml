(** Dashboard_worktree_status — Live worktree status surface.

    Enumerates MASC linked worktrees and enriches each with git status
    counts, HEAD SHA, optional PR link (via [gh]), and a keeper-attached
    flag derived from the live {!Keeper_registry}. *)

(* ------------------------------------------------------------------ *)
(* Internal git helpers                                                 *)
(* ------------------------------------------------------------------ *)

let exec_gate_raw_source argv =
  String.concat " " (List.map Filename.quote argv)

let run_in_worktree path argv =
  let full_argv = [ "git"; "-C"; path ] @ argv in
  Masc_exec.Exec_gate.run_argv
    ~actor:"dashboard/worktree_status"
    ~raw_source:(exec_gate_raw_source full_argv)
    ~summary:"dashboard_worktree_status git"
    ~timeout_sec:Env_config_runtime.Coord_git.local_op_timeout_sec
    full_argv

let first_nonempty_line output =
  output
  |> String.split_on_char '\n'
  |> List.map String.trim
  |> List.find_opt (fun s -> s <> "")

(* ------------------------------------------------------------------ *)
(* git status --porcelain parsing                                       *)
(* ------------------------------------------------------------------ *)

(** Parse [git status --porcelain] output.
    Returns [(staged_count, changed_count)].
    XY format: X = index (staged), Y = work-tree (unstaged).
    '?' = untracked, ' ' = unmodified, '!' = ignored. *)
let count_porcelain_lines output =
  let lines =
    String.split_on_char '\n' output
    |> List.filter (fun s -> String.length s >= 2)
  in
  let staged =
    List.length
      (List.filter
         (fun line ->
           let x = line.[0] in
           x <> ' ' && x <> '?' && x <> '!')
         lines)
  in
  let changed =
    List.length
      (List.filter
         (fun line ->
           let y = line.[1] in
           y <> ' ' && y <> '?' && y <> '!')
         lines)
  in
  (staged, changed)

(* ------------------------------------------------------------------ *)
(* git status / HEAD for one worktree                                   *)
(* ------------------------------------------------------------------ *)

let get_worktree_counts path =
  let output = run_in_worktree path [ "status"; "--porcelain" ] in
  count_porcelain_lines output

let get_head_sha path =
  let output = run_in_worktree path [ "rev-parse"; "--short"; "HEAD" ] in
  Option.value ~default:"" (first_nonempty_line output)

(* ------------------------------------------------------------------ *)
(* gh pr list (best-effort)                                             *)
(* ------------------------------------------------------------------ *)

(** Try [gh pr list --head <branch> --json number,state --limit 1].
    Returns [(pr_number, pr_state)] on success; both [None] on failure
    (gh not installed, auth missing, not a GitHub repo). *)
let query_pr_for_branch branch =
  if branch = "" then (None, None)
  else
    try
      let argv =
        [
          "gh";
          "pr";
          "list";
          "--head";
          branch;
          "--json";
          "number,state";
          "--limit";
          "1";
        ]
      in
      let output =
        Masc_exec.Exec_gate.run_argv
          ~actor:"dashboard/worktree_status"
          ~raw_source:(exec_gate_raw_source argv)
          ~summary:"dashboard_worktree_status gh pr list"
          ~timeout_sec:10.0
          argv
      in
      (* Output is a JSON array: [{"number":42,"state":"OPEN"}] or [] *)
      (match Yojson.Safe.from_string (String.trim output) with
      | `List ((`Assoc fields) :: _) ->
          let number =
            match List.assoc_opt "number" fields with
            | Some (`Int n) -> Some n
            | _ -> None
          in
          let state =
            match List.assoc_opt "state" fields with
            | Some (`String s) -> Some (String.lowercase_ascii s)
            | _ -> None
          in
          (number, state)
      | _ -> (None, None))
    with _ -> (None, None)

(* ------------------------------------------------------------------ *)
(* Keeper-attached detection                                            *)
(* ------------------------------------------------------------------ *)

(** Parse a MASC worktree branch name of the form [agent/task_id] and
    return the task_id portion, or [None] if the format doesn't match. *)
let task_id_of_branch branch =
  match String.split_on_char '/' branch with
  | _ :: rest when rest <> [] -> Some (String.concat "/" rest)
  | _ -> None

let keeper_task_ids () =
  Keeper_registry.all ()
  |> List.filter_map (fun (entry : Keeper_registry.registry_entry) ->
         match entry.meta.current_task_id with
         | Some task_id -> Some (Keeper_id.Task_id.to_string task_id)
         | None -> None)

let is_keeper_attached branch =
  match task_id_of_branch branch with
  | None -> false
  | Some task_id ->
      let active_tasks = keeper_task_ids () in
      List.mem task_id active_tasks

(* ------------------------------------------------------------------ *)
(* Worktree entry assembly                                              *)
(* ------------------------------------------------------------------ *)

type worktree_entry = {
  worktree_path : string;
  branch : string;
  changed_count : int;
  staged_count : int;
  head_sha : string;
  pr_number : int option;
  pr_state : string option;
  keeper_attached : bool;
}

let strip_refs_heads branch =
  let prefix = "refs/heads/" in
  if String.starts_with ~prefix branch then
    String.sub branch (String.length prefix)
      (String.length branch - String.length prefix)
  else branch

let build_entry path branch =
  let branch = strip_refs_heads branch in
  let staged_count, changed_count = get_worktree_counts path in
  let head_sha = get_head_sha path in
  let pr_number, pr_state = query_pr_for_branch branch in
  let keeper_attached = is_keeper_attached branch in
  {
    worktree_path = path;
    branch;
    changed_count;
    staged_count;
    head_sha;
    pr_number;
    pr_state;
    keeper_attached;
  }

(* ------------------------------------------------------------------ *)
(* Public: list_entries                                                 *)
(* ------------------------------------------------------------------ *)

(** Extract worktrees from the JSON returned by {!Coord_git.list}. *)
let extract_worktrees json =
  match json with
  | `Assoc fields -> (
      match List.assoc_opt "worktrees" fields with
      | Some (`List items) ->
          List.filter_map
            (fun item ->
              match item with
              | `Assoc wt_fields ->
                  let path =
                    match List.assoc_opt "path" wt_fields with
                    | Some (`String s) -> s
                    | _ -> ""
                  in
                  let branch =
                    match List.assoc_opt "branch" wt_fields with
                    | Some (`String s) -> s
                    | _ -> ""
                  in
                  let is_masc =
                    match List.assoc_opt "is_masc" wt_fields with
                    | Some (`Bool b) -> b
                    | _ -> false
                  in
                  if is_masc && path <> "" then Some (path, branch) else None
              | _ -> None)
            items
      | _ -> [])
  | _ -> []

let list_entries ~base_path =
  let worktrees_json = Coord_git.list ~base_path in
  let pairs = extract_worktrees worktrees_json in
  let entries =
    List.filter_map
      (fun (path, branch) ->
        try Some (build_entry path branch)
        with _ -> None)
      pairs
  in
  List.sort_uniq
    (fun a b -> String.compare a.worktree_path b.worktree_path)
    entries

(* ------------------------------------------------------------------ *)
(* JSON serialisation                                                   *)
(* ------------------------------------------------------------------ *)

let opt_int_json = function
  | Some n -> `Int n
  | None -> `Null

let opt_string_json = function
  | Some s -> `String s
  | None -> `Null

let entry_to_json entry =
  `Assoc
    [
      ("worktree_path", `String entry.worktree_path);
      ("branch", `String entry.branch);
      ("changed_count", `Int entry.changed_count);
      ("staged_count", `Int entry.staged_count);
      ("head_sha", `String entry.head_sha);
      ("pr_number", opt_int_json entry.pr_number);
      ("pr_state", opt_string_json entry.pr_state);
      ("keeper_attached", `Bool entry.keeper_attached);
    ]

let json ~base_path =
  let entries = list_entries ~base_path in
  `Assoc
    [
      ("generated_at", `String (Masc_domain.now_iso ()));
      ("count", `Int (List.length entries));
      ("entries", `List (List.map entry_to_json entries));
    ]

(* ------------------------------------------------------------------ *)
(* SSE helpers                                                          *)
(* ------------------------------------------------------------------ *)

let format_sse_event value =
  Printf.sprintf "data: %s\n\n" (Yojson.Safe.to_string value)

let sse_events ~base_path =
  let entries = list_entries ~base_path in
  let data_events = List.map (fun e -> format_sse_event (entry_to_json e)) entries in
  let done_event = "event: done\ndata: {}\n\n" in
  data_events @ [ done_event ]
