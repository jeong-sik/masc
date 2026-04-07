(** Keeper_evidence — deterministic post-turn evidence capture.

    After each keeper turn, captures git diff/status as immutable
    evidence of what actually changed. No LLM interpretation —
    git commands only.

    Evidence is persisted to:
      .masc/evidence/<keeper_name>/<trace_id>/turn_<N>.jsonl

    @since 2.254.0 — execution evidence system (#5620) *)

let run_git ~workdir args =
  Worktree_live_context.run_git_capture_lines ~workdir args

(** Capture post-turn evidence snapshot.
    Returns the evidence JSON and persists it to disk. *)
let capture_post_turn_evidence
    ~base_path
    ~keeper_name
    ~trace_id
    ~turn_number
    ~tool_calls_made
    ()
  : Yojson.Safe.t option =
  let repo_root =
    match Worktree_live_context.repo_root_for ~base_path with
    | Some r -> r
    | None -> base_path
  in
  let diff_stat =
    run_git ~workdir:repo_root [ "diff"; "--stat" ]
    |> Option.value ~default:[]
  in
  let shortstat =
    run_git ~workdir:repo_root [ "diff"; "--shortstat" ]
    |> Option.value ~default:[]
    |> String.concat " " |> String.trim
  in
  let branch =
    run_git ~workdir:repo_root [ "branch"; "--show-current" ]
    |> Option.value ~default:["(detached)"]
    |> List.hd
    |> String.trim
  in
  let status_lines =
    run_git ~workdir:repo_root [ "status"; "--porcelain" ]
    |> Option.value ~default:[]
    |> List.filter (fun l -> not (String_util.contains_substring l ".masc/"))
  in
  let worktrees =
    run_git ~workdir:repo_root [ "worktree"; "list"; "--porcelain" ]
    |> Option.value ~default:[]
    |> List.filter_map (fun line ->
      if String.length line > 9 && String.sub line 0 9 = "worktree " then
        Some (String.sub line 9 (String.length line - 9))
      else None)
  in
  let files_changed = List.length status_lines in
  if files_changed = 0 && diff_stat = [] then
    None
  else
    let ts = Types.now_iso () in
    let evidence = `Assoc [
      ("timestamp", `String ts);
      ("keeper_name", `String keeper_name);
      ("trace_id", `String trace_id);
      ("turn", `Int turn_number);
      ("tool_calls_made", `Int tool_calls_made);
      ("branch", `String branch);
      ("files_changed", `Int files_changed);
      ("shortstat", `String shortstat);
      ("diff_stat", `List (List.map (fun l -> `String l) diff_stat));
      ("dirty_files", `List (List.map (fun l -> `String l) status_lines));
      ("active_worktrees", `List (List.map (fun w -> `String w) worktrees));
    ] in
    (* Persist to disk *)
    (try
      let evidence_dir =
        Filename.concat base_path
          (Printf.sprintf ".masc/evidence/%s/%s"
            (Room_utils.safe_filename keeper_name)
            (Room_utils.safe_filename trace_id))
      in
      Fs_compat.mkdir_p evidence_dir;
      let evidence_file = Filename.concat evidence_dir
        (Printf.sprintf "turn_%03d.json" turn_number)
      in
      Fs_compat.save_file evidence_file
        (Yojson.Safe.pretty_to_string evidence);
      Log.Keeper.debug "evidence captured: %s turn=%d files=%d"
        keeper_name turn_number files_changed
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Keeper.warn "evidence capture failed for %s turn %d: %s"
        keeper_name turn_number (Printexc.to_string exn));
    Some evidence

(** Read the latest evidence snapshot for a keeper. *)
let latest_evidence ~base_path ~keeper_name ~trace_id
  : Yojson.Safe.t option =
  let evidence_dir =
    Filename.concat base_path
      (Printf.sprintf ".masc/evidence/%s/%s"
        (Room_utils.safe_filename keeper_name)
        (Room_utils.safe_filename trace_id))
  in
  if not (Fs_compat.file_exists evidence_dir) then None
  else
    try
      let entries = Sys.readdir evidence_dir |> Array.to_list in
      let json_files =
        List.filter (fun f -> Filename.check_suffix f ".json") entries
        |> List.sort (fun a b -> compare b a)
      in
      match json_files with
      | [] -> None
      | latest :: _ ->
        let path = Filename.concat evidence_dir latest in
        let content = Fs_compat.load_file path in
        Some (Yojson.Safe.from_string content)
    with _ -> None
