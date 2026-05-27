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
    ~actor:(Masc_exec.Agent_id.of_string "dashboard/branches")
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
  ignore config;
  let branch_by_task_id = [] in
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

(* Single-pass replacement for [list_entries].

   The legacy [list_entries] above issues one [for-each-ref] and then
   three more git processes per branch ([current_branch],
   [upstream_for_branch], [ahead_behind_for_branch]).  On masc-mcp
   (~290 local branches) that fanned out to ~870 synchronous git
   subprocesses on the Eio main domain — measured at 30-53s for
   /api/v1/dashboard/branches.

   This version uses a single [for-each-ref] that asks git for
   [%(refname:short) %(objectname) %(upstream:short)
    %(upstream:track,nobracket) %(HEAD)] in one pass.  The track field
   already encodes ahead/behind counts ("ahead 3, behind 1") and the
   [%(HEAD)] field marks the current branch with "*", so no extra
   git calls are needed. *)

let single_pass_for_each_ref_format =
  "%(refname:short)%09%(objectname)%09%(upstream:short)\
   %09%(upstream:track,nobracket)%09%(HEAD)"
;;

(* Parse [%(upstream:track,nobracket)].

   git emits one of:
   - "" (empty)                  -> at upstream (clean)
   - "gone"                      -> upstream ref no longer exists
   - "ahead N"
   - "behind N"
   - "ahead N, behind M"

   [None] means "treat upstream as missing"; [Some (a, b)] returns the
   counts (both zero for clean). *)
let parse_track_field raw =
  match String.trim raw with
  | "" -> Some (0, 0)
  | "gone" -> None
  | s ->
    let parse_segment acc segment =
      match acc, String.split_on_char ' ' (String.trim segment) with
      | None, _ -> None
      | Some (_, b), [ "ahead"; n ] ->
        (match int_of_string_opt n with
         | Some n -> Some (n, b)
         | None -> None)
      | Some (a, _), [ "behind"; n ] ->
        (match int_of_string_opt n with
         | Some n -> Some (a, n)
         | None -> None)
      | _, _ -> None
    in
    List.fold_left parse_segment (Some (0, 0)) (String.split_on_char ',' s)
;;

let run_git_single_pass ~repo =
  let argv =
    [ "git"
    ; "-C"
    ; repo
    ; "--no-optional-locks"
    ; "for-each-ref"
    ; "--format=" ^ single_pass_for_each_ref_format
    ; "refs/heads"
    ]
  in
  Masc_exec.Exec_gate.run_argv
    ~actor:(Masc_exec.Agent_id.of_string "dashboard/branches")
    ~raw_source:(exec_gate_raw_source argv)
    ~summary:"dashboard branches git single-pass"
    ~timeout_sec:Env_config_runtime.Coord_git.local_op_timeout_sec
    argv
;;

let parse_single_pass_line line =
  match String.split_on_char '\t' line with
  | [ name; head; upstream_raw; track_raw; head_marker ] ->
    let name = String.trim name in
    if name = ""
    then None
    else (
      let upstream =
        let u = String.trim upstream_raw in
        if u = "" then None else Some u
      in
      let track = parse_track_field track_raw in
      let is_current = String.equal (String.trim head_marker) "*" in
      Some (name, String.trim head, upstream, track, is_current))
  | _ -> None
;;

let entry_of_single_pass ~keepers_by_branch (name, head, upstream, track, is_current) =
  let has_upstream =
    match upstream, track with
    | None, _ -> false
    | Some _, None -> false (* upstream "gone" — treat as untracked *)
    | Some _, Some _ -> true
  in
  let ahead, behind =
    match track with
    | Some pair -> pair
    | None -> 0, 0
  in
  { name
  ; tag = (if is_current then Some "current" else None)
  ; status = status_of_counts ~has_upstream ~ahead ~behind
  ; ahead
  ; behind
  ; head
  ; keepers = Option.value ~default:[] (List.assoc_opt name keepers_by_branch)
  }
;;

let list_entries_single_pass ~config =
  let repo = Keeper_alerting_path.project_root_of_config config in
  let output = run_git_single_pass ~repo in
  let lines = String.split_on_char '\n' output in
  let parsed = List.filter_map parse_single_pass_line lines in
  let keepers_by_branch = keepers_by_branch ~config in
  parsed
  |> List.map (entry_of_single_pass ~keepers_by_branch)
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

let compute_json ~config =
  try
    let branches = list_entries_single_pass ~config in
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

(* TTL chosen so a single branches refresh costs at most one git
   subprocess every 10s per repo, and the user-visible path always
   serves from cache (stale-while-revalidate handles the boundary). *)
let cache_ttl_sec = 10.0

let json ~config =
  let repo = Keeper_alerting_path.project_root_of_config config in
  let key = "dashboard.branches:" ^ repo in
  Dashboard_cache.get_or_compute key ~ttl:cache_ttl_sec (fun () ->
    Domain_pool_ref.submit_io_or_inline (fun () -> compute_json ~config))
;;
