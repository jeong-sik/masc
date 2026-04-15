(** Keeper_evidence — deterministic turn-level git evidence.

    Captures git state transitions (before/after) for each keeper turn.
    No LLM interpretation — git commands only. Hash chain ensures
    tamper-evident ordering.

    Evidence path: .masc/evidence/<keeper_name>/<trace_id>/turn_<N>.json

    @since 2.254.0 — execution evidence system (#5620) *)

(* ── Git helpers (delegate to Worktree_live_context) ─────────── *)

let run_git ~workdir args =
  Worktree_live_context.run_git_capture_lines ~workdir args

let repo_root ~base_path =
  match Worktree_live_context.repo_root_for ~base_path with
  | Some r -> r
  | None -> base_path

let git_status_lines ~repo_root =
  Worktree_live_context.current_status_lines ~repo_root

let hash_lines lines =
  Worktree_live_context.hash_lines lines

(* ── Hash chain state (process-scoped) ───────────────────────── *)

let chain_mu = Eio.Mutex.create ()
let chain_latest : (string, string) Hashtbl.t = Hashtbl.create 8

let chain_key ~keeper_name ~trace_id =
  Printf.sprintf "%s/%s" keeper_name trace_id

let get_prev_hash ~keeper_name ~trace_id =
  Eio.Mutex.use_ro chain_mu (fun () ->
      match Hashtbl.find_opt chain_latest (chain_key ~keeper_name ~trace_id) with
      | Some h -> h
      | None -> "genesis")

let set_latest_hash ~keeper_name ~trace_id hash =
  Eio.Mutex.use_rw ~protect:true chain_mu (fun () ->
      Hashtbl.replace chain_latest (chain_key ~keeper_name ~trace_id) hash)

(* ── Phase 1: Turn-level evidence capture ────────────────────── *)

(** Snapshot git status before a turn. Returns hash of status lines. *)
let snapshot_before_turn ~base_path ~keeper_name:_ : string option =
  try
    let root = repo_root ~base_path in
    let lines = git_status_lines ~repo_root:root in
    Some (hash_lines lines)
  with Eio.Cancel.Cancelled _ as e -> raise e | _ -> None

(** Capture turn evidence after a turn completes.
    Compares before_hash with current state to detect delta. *)
let capture_turn_evidence
    ~base_path ~keeper_name ~trace_id
    ~turn_number ~tool_calls_made
    ~(before_hash : string option)
    ()
  : Yojson.Safe.t option =
  let root = repo_root ~base_path in
  let status_lines = git_status_lines ~repo_root:root in
  let after_hash = hash_lines status_lines in
  let before_h = Option.value ~default:"unknown" before_hash in
  let delta_detected = before_h <> after_hash in
  let diff_stat =
    run_git ~workdir:root [ "diff"; "--stat" ]
    |> Option.value ~default:[]
  in
  let shortstat =
    run_git ~workdir:root [ "diff"; "--shortstat" ]
    |> Option.value ~default:[]
    |> String.concat " " |> String.trim
  in
  let branch =
    run_git ~workdir:root [ "branch"; "--show-current" ]
    |> Option.value ~default:["(detached)"]
    |> (fun l -> match l with h :: _ -> String.trim h | [] -> "(detached)")
  in
  let worktrees =
    run_git ~workdir:root [ "worktree"; "list"; "--porcelain" ]
    |> Option.value ~default:[]
    |> List.filter_map (fun line ->
      if String.length line > 9 && String.sub line 0 9 = "worktree " then
        Some (String.sub line 9 (String.length line - 9))
      else None)
  in
  let files_changed = List.length status_lines in
  (* Collision detection *)
  let collision_warnings =
    if delta_detected && files_changed > 0 then
      Keeper_file_tracker.record_turn_files ~keeper_name ~files:status_lines
    else []
  in
  if collision_warnings <> [] then begin
    let n = List.length collision_warnings in
    Prometheus.inc_counter "masc_keeper_collision_detected_total"
      ~labels:[("keeper", keeper_name)] ();
    Log.Keeper.warn
      "evidence: %s has %d file collision(s) with other keeper(s) — \
       overlapping writes may corrupt shared state"
      keeper_name n
  end;
  let prev_evidence_hash = get_prev_hash ~keeper_name ~trace_id in
  let ts = Types.now_iso () in
  let evidence_body = `Assoc ([
    ("timestamp", `String ts);
    ("keeper_name", `String keeper_name);
    ("trace_id", `String trace_id);
    ("turn", `Int turn_number);
    ("tool_calls_made", `Int tool_calls_made);
    ("branch", `String branch);
    ("files_changed", `Int files_changed);
    ("shortstat", `String shortstat);
    ("delta_detected", `Bool delta_detected);
    ("before_hash", `String before_h);
    ("after_hash", `String after_hash);
    ("diff_stat", `List (List.map (fun l -> `String l) diff_stat));
    ("dirty_files", `List (List.map (fun l -> `String l) status_lines));
    ("active_worktrees", `List (List.map (fun w -> `String w) worktrees));
    ("prev_evidence_hash", `String prev_evidence_hash);
  ] @ (if collision_warnings <> [] then
    [("collision_warnings", `List (List.map Keeper_file_tracker.collision_to_json collision_warnings))]
  else [])) in
  (* Compute this entry's hash *)
  let turn_evidence_hash =
    Digest.string (Yojson.Safe.to_string evidence_body) |> Digest.to_hex
  in
  let evidence = match evidence_body with
    | `Assoc fields -> `Assoc (fields @ [("turn_evidence_hash", `String turn_evidence_hash)])
    | other -> other
  in
  set_latest_hash ~keeper_name ~trace_id turn_evidence_hash;
  (* Persist *)
  (try
    let evidence_dir =
      Filename.concat base_path
        (Printf.sprintf ".masc/evidence/%s/%s"
          (Coord_utils.safe_filename keeper_name)
          (Coord_utils.safe_filename trace_id))
    in
    Fs_compat.mkdir_p evidence_dir;
    let evidence_file = Filename.concat evidence_dir
      (Printf.sprintf "turn_%03d.json" turn_number)
    in
    Fs_compat.save_file evidence_file (Yojson.Safe.pretty_to_string evidence);
    Log.Keeper.debug "evidence: %s turn=%d delta=%b files=%d chain=%s"
      keeper_name turn_number delta_detected files_changed
      (String.sub turn_evidence_hash 0 8)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Keeper.warn "evidence capture failed for %s turn %d: %s"
      keeper_name turn_number (Printexc.to_string exn));
  Some evidence

(* ── Phase 3: Hash chain verification ────────────────────────── *)

let verify_evidence_chain ~base_path ~keeper_name ~trace_id
  : (unit, int * string * string) result =
  let evidence_dir =
    Filename.concat base_path
      (Printf.sprintf ".masc/evidence/%s/%s"
        (Coord_utils.safe_filename keeper_name)
        (Coord_utils.safe_filename trace_id))
  in
  if not (Fs_compat.file_exists evidence_dir) then Ok ()
  else
    let entries = Sys.readdir evidence_dir |> Array.to_list in
    let json_files =
      List.filter (fun f -> Filename.check_suffix f ".json") entries
      |> List.sort String.compare
    in
    let rec check ~expected_prev = function
      | [] -> Ok ()
      | file :: rest ->
        let path = Filename.concat evidence_dir file in
        let content = Fs_compat.load_file path in
        let json = Yojson.Safe.from_string content in
        let get key = match json with
          | `Assoc fields ->
            (match List.assoc_opt key fields with
             | Some (`String s) -> s
             | _ -> "")
          | _ -> ""
        in
        let turn = match json with
          | `Assoc fields ->
            (match List.assoc_opt "turn" fields with
             | Some (`Int n) -> n
             | _ -> 0)
          | _ -> 0
        in
        let actual_prev = get "prev_evidence_hash" in
        if actual_prev <> expected_prev then
          Error (turn, expected_prev, actual_prev)
        else
          let stored_hash = get "turn_evidence_hash" in
          (* Recompute hash from body without turn_evidence_hash *)
          let body_fields = match json with
            | `Assoc fields ->
              List.filter (fun (k, _) -> k <> "turn_evidence_hash") fields
            | _ -> []
          in
          let recomputed =
            Digest.string (Yojson.Safe.to_string (`Assoc body_fields))
            |> Digest.to_hex
          in
          if stored_hash <> recomputed then
            Error (turn, stored_hash, recomputed)
          else
            check ~expected_prev:stored_hash rest
    in
    check ~expected_prev:"genesis" json_files

(* ── Query ───────────────────────────────────────────────────── *)

let latest_evidence ~base_path ~keeper_name ~trace_id
  : Yojson.Safe.t option =
  let evidence_dir =
    Filename.concat base_path
      (Printf.sprintf ".masc/evidence/%s/%s"
        (Coord_utils.safe_filename keeper_name)
        (Coord_utils.safe_filename trace_id))
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
    with Eio.Cancel.Cancelled _ as e -> raise e | _ -> None
