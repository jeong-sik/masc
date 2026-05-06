(** Dashboard_branches — live git branch selector data.

    This backs [/api/v1/dashboard/branches] with repo-local git state instead of
    CI-time branch environment variables. *)

type branch_status =
  | Clean
  | Ahead
  | Behind
  | Diverged
  | Untracked

type branch_entry =
  { name : string
  ; tag : string option
  ; status : branch_status
  ; ahead : int
  ; behind : int
  ; head : string
  ; keepers : string list
  }

let exec_gate_raw_source argv = String.concat " " (List.map Filename.quote argv)

let run_git ~repo args =
  let argv = [ "git"; "-C"; repo; "--no-optional-locks" ] @ args in
  Masc_exec.Exec_gate.run_argv
    ~actor:"dashboard/branches"
    ~raw_source:(exec_gate_raw_source argv)
    ~summary:"dashboard branches git"
    ~timeout_sec:Env_config_runtime.Coord_git.local_op_timeout_sec
    argv
;;

let first_nonempty_line output =
  output
  |> String.split_on_char '\n'
  |> List.map String.trim
  |> List.find_opt (fun s -> s <> "")
;;

let parse_branch_ref_line line =
  match String.split_on_char '\t' line with
  | [ name; head ] ->
    let name = String.trim name in
    let head = String.trim head in
    if name = "" || head = "" then None else Some (name, head)
  | _ -> None
;;

let parse_branch_refs output =
  output |> String.split_on_char '\n' |> List.filter_map parse_branch_ref_line
;;

let parse_ahead_behind output =
  match String.split_on_char '\t' (String.trim output) with
  | [ ahead; behind ] ->
    (match int_of_string_opt ahead, int_of_string_opt behind with
     | Some ahead, Some behind -> Some (ahead, behind)
     | _ -> None)
  | _ -> None
;;

let status_of_counts ~has_upstream ~ahead ~behind =
  if not has_upstream
  then Untracked
  else (
    match ahead, behind with
    | 0, 0 -> Clean
    | _, 0 when ahead > 0 -> Ahead
    | 0, _ when behind > 0 -> Behind
    | _ -> Diverged)
;;

let status_to_string = function
  | Clean -> "clean"
  | Ahead -> "ahead"
  | Behind -> "behind"
  | Diverged -> "diverged"
  | Untracked -> "untracked"
;;

let current_branch ~repo =
  try first_nonempty_line (run_git ~repo [ "branch"; "--show-current" ]) with
  | _ -> None
;;

let upstream_for_branch ~repo branch =
  try
    run_git ~repo [ "rev-parse"; "--abbrev-ref"; branch ^ "@{upstream}" ]
    |> first_nonempty_line
  with
  | _ -> None
;;

let ahead_behind_for_branch ~repo branch upstream =
  try
    run_git ~repo [ "rev-list"; "--left-right"; "--count"; branch ^ "..." ^ upstream ]
    |> parse_ahead_behind
  with
  | _ -> None
;;

let keepers_by_branch ~config =
  let tasks = if Coord.is_initialized config then Coord.get_tasks_safe config else [] in
  let branch_by_task_id =
    tasks
    |> List.filter_map (fun (task : Masc_domain.task) ->
      match task.worktree with
      | Some worktree when String.trim worktree.branch <> "" ->
        Some (task.id, String.trim worktree.branch)
      | _ -> None)
  in
  let add_keeper acc branch keeper =
    let existing =
      match List.assoc_opt branch acc with
      | Some keepers -> keepers
      | None -> []
    in
    let updated = if List.mem keeper existing then existing else keeper :: existing in
    (branch, updated) :: List.remove_assoc branch acc
  in
  Keeper_registry.all ()
  |> List.fold_left
       (fun acc (entry : Keeper_registry.registry_entry) ->
          match entry.meta.current_task_id with
          | None -> acc
          | Some task_id ->
            let task_id = Keeper_id.Task_id.to_string task_id in
            (match List.assoc_opt task_id branch_by_task_id with
             | None -> acc
             | Some branch -> add_keeper acc branch entry.meta.name))
       []
  |> List.map (fun (branch, keepers) -> branch, List.sort String.compare keepers)
;;

let build_entry ~repo ~current ~keepers_by_branch (name, head) =
  let upstream = upstream_for_branch ~repo name in
  let ahead, behind =
    match upstream with
    | None -> 0, 0
    | Some upstream ->
      Option.value ~default:(0, 0) (ahead_behind_for_branch ~repo name upstream)
  in
  let tag =
    match current with
    | Some branch when String.equal branch name -> Some "current"
    | _ -> None
  in
  { name
  ; tag
  ; status = status_of_counts ~has_upstream:(Option.is_some upstream) ~ahead ~behind
  ; ahead
  ; behind
  ; head
  ; keepers = Option.value ~default:[] (List.assoc_opt name keepers_by_branch)
  }
;;

let list_entries ~config =
  let repo = Keeper_alerting_path.project_root_of_config config in
  let refs =
    run_git
      ~repo
      [ "for-each-ref"; "--format=%(refname:short)%09%(objectname)"; "refs/heads" ]
    |> parse_branch_refs
  in
  let current = current_branch ~repo in
  let keepers_by_branch = keepers_by_branch ~config in
  refs
  |> List.map (build_entry ~repo ~current ~keepers_by_branch)
  |> List.sort (fun a b -> String.compare a.name b.name)
;;

let entry_to_json entry =
  `Assoc
    [ "name", `String entry.name
    ; "tag", Json_util.string_opt_to_json entry.tag
    ; "status", `String (status_to_string entry.status)
    ; "ahead", `Int entry.ahead
    ; "behind", `Int entry.behind
    ; "head", `String entry.head
    ; "keepers", `List (List.map (fun keeper -> `String keeper) entry.keepers)
    ]
;;

let json ~config =
  try
    let branches = list_entries ~config in
    `Assoc
      [ "generated_at", `String (Masc_domain.now_iso ())
      ; "repo", `String (Keeper_alerting_path.project_root_of_config config)
      ; "count", `Int (List.length branches)
      ; "branches", `List (List.map entry_to_json branches)
      ]
  with
  | exn ->
    `Assoc
      [ "generated_at", `String (Masc_domain.now_iso ())
      ; "repo", `String (Keeper_alerting_path.project_root_of_config config)
      ; "count", `Int 0
      ; "branches", `List []
      ; "error", `String (Printexc.to_string exn)
      ]
;;
