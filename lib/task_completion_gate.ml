type decision =
  | Pass
  | Reject of
      { reason : string
      ; rule_id : string
      ; hint : string
      ; payload_json : Yojson.Safe.t
      }

(* Retained rule id. The gate historically lived in [Cdal_evidence_gate]; the
   string is asserted by downstream tests and consumed offline by the
   completion-trust audit, so it is kept stable across the RFC-0311 rewrite.
   RFC-0311 §5 typed rejection reasons are a later phase. *)
let rule_id_evidence_incomplete = "cdal_evidence_incomplete"

(* Payload token naming the one thing every rejected completion is missing: a
   trusted, reviewer-inspectable reference on handoff_context.evidence_refs.
   Tests assert this literal in the reject payload. *)
let missing_evidence_ref_token = "handoff_context.evidence_refs"

let reason_evidence_incomplete =
  "Task-completion evidence is insufficient: no trusted, reviewer-inspectable \
   evidence reference was supplied. Completion notes alone do not satisfy the \
   gate."

let hint_evidence_incomplete =
  "Attach at least one validated handoff_context.evidence_refs reference: an \
   existing base-path artifact file/file:// URI, a commit hash that exists in \
   the local git repo, or a trace/turn/receipt ref that resolves under the local \
   .masc artifact store. Completion notes, URLs, PR numbers, and trace-shaped \
   labels do not satisfy the deterministic gate by shape alone."

let safe_stat_is_file path =
  try Sys.file_exists path && not (Sys.is_directory path) with
  | Sys_error _ -> false

let directory_entries path =
  try Sys.readdir path |> Array.to_list with
  | Sys_error _ -> []

let canonical_path path =
  try Some (Unix.realpath path) with
  | Unix.Unix_error _ | Sys_error _ -> None

let path_within_base ~base_path path =
  match canonical_path base_path, canonical_path path with
  | Some base, Some resolved ->
    String.equal base resolved
    || String.starts_with ~prefix:(base ^ Filename.dir_sep) resolved
  | _ -> false

let existing_base_path_file ~base_path path =
  safe_stat_is_file path && path_within_base ~base_path path

let is_safe_ref_segment value =
  String.length value > 0
  && Filename.is_relative value
  && not (String.contains value '/')
  && String.for_all
       (function
         | '0' .. '9'
         | 'a' .. 'z'
         | 'A' .. 'Z'
         | '_'
         | '-'
         | '.'
         | '@'
         | '#'
         | ':' -> true
         | _ -> false)
       value

let artifact_file_path ~base_path ref_path =
  let candidate =
    if Filename.is_relative ref_path
    then Filename.concat base_path ref_path
    else ref_path
  in
  if existing_base_path_file ~base_path candidate then Some candidate else None

let git_commit_exists ~base_path commit =
  let check_root root =
    try Workspace_git.commit_exists ~root ~commit
    with Eio.Cancel.Cancelled _ as e -> raise e | _ -> false
  in
  match Workspace_git.git_root ~base_path with
  | Some root -> check_root root
  | None ->
    (* base_path (sandbox root) is not a git repo.
       Scan repos/*/ subdirectories for clones containing the commit. *)
    let repos_dir = Filename.concat base_path "repos" in
    let entries = directory_entries repos_dir in
    List.exists (fun entry ->
        let repo_path = Filename.concat repos_dir entry in
        match Workspace_git.git_root ~base_path:repo_path with
        | None -> false
        | Some root -> check_root root)
      entries

let trajectory_paths_for_trace ~base_path trace_id =
  if not (is_safe_ref_segment trace_id)
  then []
  else
    let trajectories_root =
      Common.masc_dir_from_base_path ~base_path |> fun masc_root ->
      Filename.concat masc_root "trajectories"
    in
    if not
         (try Sys.file_exists trajectories_root && Sys.is_directory trajectories_root with
          | Sys_error _ -> false)
    then []
    else
      directory_entries trajectories_root
      |> List.filter_map (fun keeper_name ->
        let keeper_dir = Filename.concat trajectories_root keeper_name in
        let candidate = Filename.concat keeper_dir (trace_id ^ ".jsonl") in
        if existing_base_path_file ~base_path candidate then Some candidate else None)

let read_nonempty_lines path =
  try
    let input = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr input)
      (fun () ->
         let rec loop acc =
           match input_line input with
           | line ->
             let trimmed = String.trim line in
             loop (if String.equal trimmed "" then acc else trimmed :: acc)
           | exception End_of_file -> List.rev acc
         in
         loop [])
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | Sys_error _ -> []

let jsonl_has_parseable_json path =
  read_nonempty_lines path
  |> List.exists (fun line ->
    try
      let (_ : Yojson.Safe.t) = Yojson.Safe.from_string line in
      true
    with
    | Yojson.Json_error _ -> false)

let trace_ref_exists ~base_path trace_id =
  trajectory_paths_for_trace ~base_path trace_id
  |> List.exists jsonl_has_parseable_json

let turn_ref_exists ~base_path value =
  match Ids.Turn_ref.of_string value with
  | None -> false
  | Some turn_ref ->
    let trace_id = Ids.Turn_ref.trace_id turn_ref in
    let wanted_turn = Ids.Turn_ref.absolute_turn turn_ref in
    trajectory_paths_for_trace ~base_path trace_id
    |> List.exists (fun path ->
      let lines = read_nonempty_lines path in
      let parsed, _, _ = Trajectory.trajectory_lines_of_jsonl_lines ~trace_id lines in
      List.exists
        (function
          | Trajectory.Tool_call entry -> Int.equal entry.turn wanted_turn
          | Trajectory.Thinking entry -> Int.equal entry.turn wanted_turn)
        parsed)

let receipt_ref_exists ~base_path value =
  match Ids.Turn_ref.of_string value with
  | None -> false
  | Some turn_ref ->
    let trace_id = Ids.Turn_ref.trace_id turn_ref in
    let wanted_turn = Ids.Turn_ref.absolute_turn turn_ref in
    let keepers_root =
      Common.keepers_runtime_dir_of_base ~base_path
    in
    directory_entries keepers_root
    |> List.exists (fun keeper_name ->
      let receipts_dir =
        Filename.concat
          (Filename.concat keepers_root keeper_name)
          "execution-receipts"
      in
      directory_entries receipts_dir
      |> List.exists (fun month ->
        let month_dir = Filename.concat receipts_dir month in
        directory_entries month_dir
        |> List.exists (fun file_name ->
          let path = Filename.concat month_dir file_name in
          Filename.check_suffix file_name ".jsonl"
          && existing_base_path_file ~base_path path
          && (read_nonempty_lines path
              |> List.exists (fun line ->
                try
                  let json = Yojson.Safe.from_string line in
                  Json_util.get_string json "trace_id" = Some trace_id
                  && (Json_util.get_int json "turn_count" = Some wanted_turn
                      || Json_util.get_int json "keeper_turn_id" = Some wanted_turn)
                with
                | Yojson.Json_error _ -> false)))))

(* L1 core: an evidence reference is gate-trusted only after resolving the
   typed candidate against deterministic local state. Shape recognition alone is
   deliberately insufficient; network-only refs (URL/PR) fail closed here until
   a forge/verifier resolver can prove them. *)
let evidence_ref_is_gate_trusted ~base_path ref_ =
  match Evidence_ref.of_string ref_ with
  | Some (Evidence_ref.File_path path | Evidence_ref.File_uri path) ->
    Option.is_some (artifact_file_path ~base_path path)
  | Some (Evidence_ref.Commit commit) -> git_commit_exists ~base_path commit
  | Some (Evidence_ref.Trace_ref (Evidence_ref.Trace, trace_id)) ->
    trace_ref_exists ~base_path trace_id
  | Some (Evidence_ref.Trace_ref (Evidence_ref.Turn, turn_ref)) ->
    turn_ref_exists ~base_path turn_ref
  | Some (Evidence_ref.Trace_ref (Evidence_ref.Receipt, receipt_ref)) ->
    receipt_ref_exists ~base_path receipt_ref
  | Some (Evidence_ref.Url _ | Evidence_ref.Pr _) -> false
  | None -> false

let handoff_supplies_trusted_ref ~base_path
    (handoff_context : Masc_domain.task_handoff_context option) : bool =
  match handoff_context with
  | None -> false
  | Some hc -> List.exists (evidence_ref_is_gate_trusted ~base_path) hc.evidence_refs

let evidence_summary_payload
    ~(notes : string)
    ~(handoff_context : Masc_domain.task_handoff_context option) : Yojson.Safe.t =
  `Assoc
    [ "notes_length", `Int (String.length (String.trim notes))
    ; ( "handoff_evidence_refs_count"
      , `Int
          (match handoff_context with
           | None -> 0
           | Some hc -> List.length hc.evidence_refs) )
    ]

let reject_payload ~task_id ~contract_required ~notes ~handoff_context : Yojson.Safe.t =
  `Assoc
    [ "task_id", `String task_id
    ; "contract_required", `Bool contract_required
    ; ( "required_evidence_unsatisfied"
      , `List [ `String missing_evidence_ref_token ] )
    ; "evidence_summary", evidence_summary_payload ~notes ~handoff_context
    ]

(* RFC-0311 Phase 1 (L1, universal default): a task completion is accepted iff
   the caller supplies at least one trusted, reviewer-inspectable evidence
   reference on handoff_context.evidence_refs. Completion [notes] are IGNORED
   for the pass/fail decision — they cannot be inspected and were the substring
   surface that previously let BOTH over-blocking (unknown keepers rejected) and
   fake-done (labels pasted to pass) through the same line. The contract's
   [required_evidence] descriptive entries are likewise not consulted here (they
   still feed the anti-rationalization reviewer prompt and verifier records);
   binding completion to specific evidence KINDS is RFC-0311 Phase 2. A missing
   live task fails closed. *)
let decide ~base_path ~task_id ~task_opt ~notes ~handoff_context () =
  let handoff_refs_count =
    match (handoff_context : Masc_domain.task_handoff_context option) with
    | None -> 0
    | Some hc -> List.length hc.evidence_refs
  in
  match (task_opt : Masc_domain.task option) with
  | None ->
    (* Fail closed: there is no live task to verify. The sole production caller
       already rejects a missing task before reaching the gate, so this branch
       is defense-in-depth, not a keeper-visible path. *)
    Log.Task.warn "task_completion_gate REJECT task=%s reason=no_live_task rule=%s"
      task_id rule_id_evidence_incomplete;
    Reject
      { reason = "Task-completion evidence gate reached with no live task."
      ; rule_id = rule_id_evidence_incomplete
      ; hint = hint_evidence_incomplete
      ; payload_json =
          reject_payload ~task_id ~contract_required:false ~notes ~handoff_context
      }
  | Some t ->
    if handoff_supplies_trusted_ref ~base_path handoff_context
    then begin
      Log.Task.info "task_completion_gate PASS task=%s notes_len=%d handoff_refs=%d"
        task_id (String.length (String.trim notes)) handoff_refs_count;
      Pass
    end
    else begin
      Log.Task.warn
        "task_completion_gate REJECT task=%s notes_len=%d handoff_refs=%d rule=%s"
        task_id (String.length (String.trim notes)) handoff_refs_count
        rule_id_evidence_incomplete;
      Reject
        { reason = reason_evidence_incomplete
        ; rule_id = rule_id_evidence_incomplete
        ; hint = hint_evidence_incomplete
        ; payload_json =
            reject_payload ~task_id
              ~contract_required:(Option.is_some t.contract)
              ~notes ~handoff_context
        }
    end
