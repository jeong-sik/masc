(** Tool_improve_loop — keeper-first self-improvement loop substrate for
    masc-mcp.

    The loop persists selection state locally, ranks GitHub PRs/issues, and
    prepares or executes the next burn-down action in a dedicated worktree.
    It intentionally keeps the action plan explicit so a resident keeper can
    inspect and drive the lane using normal MASC tools. *)

open Tool_args

module U = Yojson.Safe.Util

type result = bool * string

type 'a context = {
  config : Room.config;
  agent_name : string;
  sw : Eio.Switch.t option;
  clock : 'a Eio.Time.clock option;
  proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option;
}

type loop_status =
  | Disabled
  | Running
  | Paused

type candidate_kind =
  | Merge_ready_pr
  | Conflict_pr
  | Failing_pr
  | Priority_issue
  | Backlog_issue

type pr_summary = {
  number : int;
  title : string;
  url : string option;
  head_ref_name : string;
  base_ref_name : string option;
  mergeable : string option;
  merge_state_status : string option;
  is_draft : bool;
  failing_checks : string list;
  pending_checks : string list;
}

type issue_summary = {
  number : int;
  title : string;
  url : string option;
  labels : string list;
}

type candidate = {
  kind : candidate_kind;
  number : int;
  title : string;
  url : string option;
  head_ref_name : string option;
  base_ref_name : string option;
  mergeable : string option;
  merge_state_status : string option;
  labels : string list;
  failing_checks : string list;
  pending_checks : string list;
}

type state = {
  enabled : bool;
  status : loop_status;
  keeper_name : string;
  poll_interval_sec : int;
  repo : string;
  repo_scope : string;
  merge_policy : string;
  dry_run : bool;
  current_candidate : candidate option;
  current_phase : string option;
  last_success : string option;
  last_failure : string option;
  consecutive_failures : int;
  last_merged_pr : int option;
  last_closed_issue : int option;
  paused_reason : string option;
  updated_at : float;
}

type command_result = {
  exit_code : int;
  stdout : string;
  stderr : string;
}

type driver = {
  list_prs : repo:string -> (pr_summary list, string) Stdlib.result;
  list_issues : repo:string -> (issue_summary list, string) Stdlib.result;
  run_command : string list -> command_result;
  now : unit -> float;
}

type action_plan = {
  action_id : string;
  phase : string;
  summary : string;
  candidate : candidate;
  worktree_path : string option;
  branch_name : string option;
  commands : string list;
  merge_command : string option;
  requires_team_session : bool;
  notes : string list;
}

let schemas = Tool_improve_loop_schemas.schemas

let default_repo = "jeong-sik/masc-mcp"
let default_keeper_name = "masc-improver"
let default_poll_interval_sec = 300
let default_repo_scope = "masc-mcp-only"
let default_merge_policy = "squash"

let string_member name json =
  match U.member name json with
  | `String value ->
      let trimmed = String.trim value in
      if trimmed = "" then None else Some trimmed
  | _ -> None

let bool_member name json =
  match U.member name json with
  | `Bool value -> Some value
  | _ -> None

let int_member name json =
  match U.member name json with
  | `Int value -> Some value
  | `Intlit raw -> Some (Safe_ops.int_of_string_with_default ~default:0 raw)
  | _ -> None

let float_member name json =
  match U.member name json with
  | `Float value -> Some value
  | `Int value -> Some (float_of_int value)
  | `Intlit raw -> Some (float_of_int (Safe_ops.int_of_string_with_default ~default:0 raw))
  | _ -> None

let list_string_member name json =
  match U.member name json with
  | `List values ->
      values
      |> List.filter_map (function
           | `String value ->
               let trimmed = String.trim value in
               if trimmed = "" then None else Some trimmed
           | _ -> None)
  | _ -> []

let shell_join argv =
  String.concat " " (List.map Filename.quote argv)

let option_or_else left right =
  match left with
  | Some _ -> left
  | None -> right ()

let option_exists pred = function
  | Some value -> pred value
  | None -> false

let list_hd_opt = function
  | head :: _ -> Some head
  | [] -> None

let slugify title =
  let lowered = String.lowercase_ascii title in
  let buf = Buffer.create (String.length lowered) in
  let push_dash () =
    if Buffer.length buf > 0 && Buffer.nth buf (Buffer.length buf - 1) <> '-' then
      Buffer.add_char buf '-'
  in
  String.iter
    (fun c ->
      match c with
      | 'a' .. 'z' | '0' .. '9' -> Buffer.add_char buf c
      | _ -> push_dash ())
    lowered;
  let rec trim_bounds s =
    let len = String.length s in
    if len = 0 then "item"
    else if s.[0] = '-' then trim_bounds (String.sub s 1 (len - 1))
    else if s.[len - 1] = '-' then trim_bounds (String.sub s 0 (len - 1))
    else s
  in
  trim_bounds (Buffer.contents buf)

let loop_status_to_string = function
  | Disabled -> "disabled"
  | Running -> "running"
  | Paused -> "paused"

let loop_status_of_string = function
  | "running" -> Running
  | "paused" -> Paused
  | _ -> Disabled

let candidate_kind_to_string = function
  | Merge_ready_pr -> "merge_ready_pr"
  | Conflict_pr -> "conflict_pr"
  | Failing_pr -> "failing_pr"
  | Priority_issue -> "priority_issue"
  | Backlog_issue -> "backlog_issue"

let candidate_kind_of_string = function
  | "merge_ready_pr" -> Merge_ready_pr
  | "conflict_pr" -> Conflict_pr
  | "failing_pr" -> Failing_pr
  | "priority_issue" -> Priority_issue
  | _ -> Backlog_issue

let candidate_id (candidate : candidate) =
  Printf.sprintf "%s#%d"
    (candidate_kind_to_string candidate.kind)
    candidate.number

let candidate_to_json (candidate : candidate) =
  `Assoc
    [
      ("id", `String (candidate_id candidate));
      ("kind", `String (candidate_kind_to_string candidate.kind));
      ("number", `Int candidate.number);
      ("title", `String candidate.title);
      ("url", Option.fold ~none:`Null ~some:(fun value -> `String value) candidate.url);
      ( "head_ref_name",
        Option.fold ~none:`Null ~some:(fun value -> `String value)
          candidate.head_ref_name );
      ( "base_ref_name",
        Option.fold ~none:`Null ~some:(fun value -> `String value)
          candidate.base_ref_name );
      ( "mergeable",
        Option.fold ~none:`Null ~some:(fun value -> `String value)
          candidate.mergeable );
      ( "merge_state_status",
        Option.fold ~none:`Null ~some:(fun value -> `String value)
          candidate.merge_state_status );
      ("labels", `List (List.map (fun value -> `String value) candidate.labels));
      ( "failing_checks",
        `List (List.map (fun value -> `String value) candidate.failing_checks) );
      ( "pending_checks",
        `List (List.map (fun value -> `String value) candidate.pending_checks) );
    ]

let candidate_of_json json =
  {
    kind =
      string_member "kind" json
      |> Option.map candidate_kind_of_string
      |> Option.value ~default:Backlog_issue;
    number = int_member "number" json |> Option.value ~default:0;
    title = string_member "title" json |> Option.value ~default:"";
    url = string_member "url" json;
    head_ref_name = string_member "head_ref_name" json;
    base_ref_name = string_member "base_ref_name" json;
    mergeable = string_member "mergeable" json;
    merge_state_status = string_member "merge_state_status" json;
    labels = list_string_member "labels" json;
    failing_checks = list_string_member "failing_checks" json;
    pending_checks = list_string_member "pending_checks" json;
  }

let default_state ?(repo = default_repo) ?(now = Time_compat.now ()) () =
  {
    enabled = false;
    status = Disabled;
    keeper_name = default_keeper_name;
    poll_interval_sec = default_poll_interval_sec;
    repo;
    repo_scope = default_repo_scope;
    merge_policy = default_merge_policy;
    dry_run = false;
    current_candidate = None;
    current_phase = None;
    last_success = None;
    last_failure = None;
    consecutive_failures = 0;
    last_merged_pr = None;
    last_closed_issue = None;
    paused_reason = None;
    updated_at = now;
  }

let state_to_json (state : state) =
  `Assoc
    [
      ("enabled", `Bool state.enabled);
      ("status", `String (loop_status_to_string state.status));
      ("keeper_name", `String state.keeper_name);
      ("poll_interval_sec", `Int state.poll_interval_sec);
      ("repo", `String state.repo);
      ("repo_scope", `String state.repo_scope);
      ("merge_policy", `String state.merge_policy);
      ("dry_run", `Bool state.dry_run);
      ( "current_candidate",
        Option.fold ~none:`Null ~some:candidate_to_json state.current_candidate );
      ( "current_phase",
        Option.fold ~none:`Null ~some:(fun value -> `String value)
          state.current_phase );
      ( "last_success",
        Option.fold ~none:`Null ~some:(fun value -> `String value)
          state.last_success );
      ( "last_failure",
        Option.fold ~none:`Null ~some:(fun value -> `String value)
          state.last_failure );
      ("consecutive_failures", `Int state.consecutive_failures);
      ( "last_merged_pr",
        Option.fold ~none:`Null ~some:(fun value -> `Int value)
          state.last_merged_pr );
      ( "last_closed_issue",
        Option.fold ~none:`Null ~some:(fun value -> `Int value)
          state.last_closed_issue );
      ( "paused_reason",
        Option.fold ~none:`Null ~some:(fun value -> `String value)
          state.paused_reason );
      ("updated_at", `Float state.updated_at);
    ]

let state_of_json json =
  let default = default_state () in
  {
    enabled = bool_member "enabled" json |> Option.value ~default:default.enabled;
    status =
      string_member "status" json
      |> Option.map loop_status_of_string
      |> Option.value ~default:default.status;
    keeper_name =
      string_member "keeper_name" json |> Option.value ~default:default.keeper_name;
    poll_interval_sec =
      int_member "poll_interval_sec" json |> Option.value ~default:default.poll_interval_sec;
    repo = string_member "repo" json |> Option.value ~default:default.repo;
    repo_scope =
      string_member "repo_scope" json |> Option.value ~default:default.repo_scope;
    merge_policy =
      string_member "merge_policy" json |> Option.value ~default:default.merge_policy;
    dry_run = bool_member "dry_run" json |> Option.value ~default:default.dry_run;
    current_candidate =
      (match U.member "current_candidate" json with
       | `Assoc _ as payload -> Some (candidate_of_json payload)
       | _ -> None);
    current_phase = string_member "current_phase" json;
    last_success = string_member "last_success" json;
    last_failure = string_member "last_failure" json;
    consecutive_failures =
      int_member "consecutive_failures" json
      |> Option.value ~default:default.consecutive_failures;
    last_merged_pr = int_member "last_merged_pr" json;
    last_closed_issue = int_member "last_closed_issue" json;
    paused_reason = string_member "paused_reason" json;
    updated_at = float_member "updated_at" json |> Option.value ~default:default.updated_at;
  }

let loop_dir config =
  Filename.concat (Room.masc_dir config) "improve-loop"

let state_file config =
  Filename.concat (loop_dir config) "state.json"

let events_file config =
  Filename.concat (loop_dir config) "events.jsonl"

let save_state config (state : state) =
  let dir = loop_dir config in
  Fs_compat.mkdir_p dir;
  Fs_compat.save_file (state_file config)
    (Yojson.Safe.pretty_to_string (state_to_json state))

let load_state config =
  let path = state_file config in
  if Sys.file_exists path then
    try Yojson.Safe.from_file path |> state_of_json
    with _ -> default_state ()
  else
    default_state ()

let append_event config event_type json =
  let dir = loop_dir config in
  Fs_compat.mkdir_p dir;
  Fs_compat.append_jsonl (events_file config)
    (`Assoc
      [
        ("timestamp", `Float (Time_compat.now ()));
        ("event_type", `String event_type);
        ("payload", json);
      ])

let run_process argv =
  match argv with
  | [] -> { exit_code = 127; stdout = ""; stderr = "empty argv" }
  | prog :: _ ->
      let result =
        Tool_command_plane_support.run_process ~prog ~argv
          ~env:(Unix.environment ())
      in
      { exit_code = result.exit_code; stdout = result.stdout; stderr = result.stderr }

let parse_check_state json =
  let label =
    option_or_else (string_member "name" json)
      (fun () -> string_member "context" json)
    |> Option.value ~default:"unnamed-check"
  in
  let state =
    option_or_else (string_member "conclusion" json)
      (fun () -> string_member "status" json)
    |> fun value ->
    option_or_else value
      (fun () -> string_member "state" json)
    |> Option.map String.uppercase_ascii
    |> Option.value ~default:"UNKNOWN"
  in
  (label, state)

let failing_check_states =
  [ "FAILURE"; "FAILED"; "ERROR"; "TIMED_OUT"; "CANCELLED"; "ACTION_REQUIRED";
    "STARTUP_FAILURE"; "STALE" ]

let pending_check_states =
  [ "PENDING"; "QUEUED"; "IN_PROGRESS"; "EXPECTED"; "WAITING" ]

let parse_pr json =
  let check_rows =
    match U.member "statusCheckRollup" json with
    | `List rows -> rows |> List.filter_map (function `Assoc _ as row -> Some row | _ -> None)
    | _ -> []
  in
  let failing_checks, pending_checks =
    List.fold_left
      (fun (failing, pending) row ->
        let label, state = parse_check_state row in
        if List.mem state failing_check_states then
          (label :: failing, pending)
        else if List.mem state pending_check_states then
          (failing, label :: pending)
        else
          (failing, pending))
      ([], []) check_rows
  in
  {
    number = int_member "number" json |> Option.value ~default:0;
    title = string_member "title" json |> Option.value ~default:"";
    url = string_member "url" json;
    head_ref_name = string_member "headRefName" json |> Option.value ~default:"";
    base_ref_name = string_member "baseRefName" json;
    mergeable = string_member "mergeable" json;
    merge_state_status = string_member "mergeStateStatus" json;
    is_draft = bool_member "isDraft" json |> Option.value ~default:false;
    failing_checks = List.rev failing_checks;
    pending_checks = List.rev pending_checks;
  }

let parse_issue json =
  let labels =
    match U.member "labels" json with
    | `List rows ->
        rows
        |> List.filter_map (function
             | `Assoc _ as row ->
                 string_member "name" row
             | `String label ->
                 let trimmed = String.trim label in
                 if trimmed = "" then None else Some trimmed
             | _ -> None)
        |> List.sort_uniq String.compare
    | _ -> []
  in
  {
    number = int_member "number" json |> Option.value ~default:0;
    title = string_member "title" json |> Option.value ~default:"";
    url = string_member "url" json;
    labels;
  }

let default_driver =
  let gh_json argv parse_item =
    let result = run_process argv in
    if result.exit_code <> 0 then
      Error
        (String.trim
           (if String.trim result.stderr <> "" then result.stderr else result.stdout))
    else
      try
        match Yojson.Safe.from_string result.stdout with
        | `List rows -> Ok (rows |> List.filter_map (function `Assoc _ as row -> Some (parse_item row) | _ -> None))
        | _ -> Error "gh returned non-list JSON"
      with Yojson.Json_error msg ->
        Error ("failed to parse gh JSON: " ^ msg)
  in
  {
    list_prs =
      (fun ~repo ->
        gh_json
          [
            "gh"; "pr"; "list"; "--repo"; repo; "--state"; "open";
            "--json";
            "number,title,url,headRefName,baseRefName,isDraft,mergeable,mergeStateStatus,statusCheckRollup";
          ]
          parse_pr);
    list_issues =
      (fun ~repo ->
        gh_json
          [
            "gh"; "issue"; "list"; "--repo"; repo; "--state"; "open";
            "--json"; "number,title,url,labels";
          ]
          parse_issue);
    run_command = run_process;
    now = Time_compat.now;
  }

let normalize_label label =
  String.lowercase_ascii (String.trim label)

let has_priority_label labels =
  List.exists
    (fun label ->
      let normalized = normalize_label label in
      List.mem normalized [ "high"; "bug"; "safety"; "priority:high"; "type:bug" ])
    labels

let is_conflicting_pr (pr : pr_summary) =
  match (pr.mergeable, pr.merge_state_status) with
  | Some "CONFLICTING", _ -> true
  | _, Some "DIRTY" -> true
  | _ -> false

let is_loop_owned_branch branch_name =
  String.starts_with ~prefix:"loop/" branch_name

let is_merge_ready_pr ?(review_ok = false) (pr : pr_summary) =
  is_loop_owned_branch pr.head_ref_name
  && review_ok
  && not pr.is_draft
  && pr.failing_checks = []
  && pr.pending_checks = []
  &&
  match pr.mergeable with
  | Some "MERGEABLE" -> (
      match pr.base_ref_name with
      | Some ("main" | "master") -> true
      | _ -> false)
  | _ -> false

let candidate_priority = function
  | Merge_ready_pr -> 0
  | Conflict_pr -> 1
  | Failing_pr -> 2
  | Priority_issue -> 3
  | Backlog_issue -> 4

let candidate_compare left right =
  let priority_cmp =
    compare (candidate_priority left.kind) (candidate_priority right.kind)
  in
  if priority_cmp <> 0 then priority_cmp else compare left.number right.number

let candidate_of_pr ?(review_ok = false) (pr : pr_summary) =
  let kind =
    if is_merge_ready_pr ~review_ok pr then Merge_ready_pr
    else if is_conflicting_pr pr then Conflict_pr
    else Failing_pr
  in
  {
    kind;
    number = pr.number;
    title = pr.title;
    url = pr.url;
    head_ref_name = Some pr.head_ref_name;
    base_ref_name = pr.base_ref_name;
    mergeable = pr.mergeable;
    merge_state_status = pr.merge_state_status;
    labels = [];
    failing_checks = pr.failing_checks;
    pending_checks = pr.pending_checks;
  }

let candidate_of_issue (issue : issue_summary) =
  {
    kind = if has_priority_label issue.labels then Priority_issue else Backlog_issue;
    number = issue.number;
    title = issue.title;
    url = issue.url;
    head_ref_name = None;
    base_ref_name = None;
    mergeable = None;
    merge_state_status = None;
    labels = issue.labels;
    failing_checks = [];
    pending_checks = [];
  }

let rank_candidates ?skip_candidate_id ?(review_ok = false)
    ~(prs : pr_summary list) ~(issues : issue_summary list) () =
  let candidates =
    (prs
    |> List.filter (fun pr -> is_conflicting_pr pr || pr.failing_checks <> [] || is_merge_ready_pr ~review_ok pr)
    |> List.map (candidate_of_pr ~review_ok))
    @ (issues |> List.map candidate_of_issue)
  in
  candidates
  |> List.filter (fun candidate ->
         match skip_candidate_id with
         | Some skip -> not (String.equal skip (candidate_id candidate))
         | None -> true)
  |> List.sort candidate_compare

let repo_root (config : Room.config) =
  match Autoresearch.git_top_level ~workdir:config.base_path with
  | Ok root -> root
  | Error _ -> config.base_path

let loop_worktree_path repo_root slug =
  Filename.concat (Filename.concat repo_root ".worktrees/loop") slug

let issue_branch_name candidate =
  Printf.sprintf "loop/issue-%d-%s" candidate.number (slugify candidate.title)

let issue_worktree_path repo_root candidate =
  loop_worktree_path repo_root
    (Printf.sprintf "issue-%d-%s" candidate.number (slugify candidate.title))

let pr_worktree_path repo_root candidate =
  loop_worktree_path repo_root
    (Printf.sprintf "pr-%d-%s" candidate.number (slugify candidate.title))

let ensure_parent_dir path =
  Fs_compat.mkdir_p (Filename.dirname path)

let merge_gate_reasons ~review_ok (candidate : candidate) =
  let owned =
    option_exists is_loop_owned_branch candidate.head_ref_name
  in
  let checks_green =
    candidate.failing_checks = [] && candidate.pending_checks = []
  in
  let target_main =
    match candidate.base_ref_name with
    | Some ("main" | "master") -> true
    | _ -> false
  in
  let mergeable =
    match candidate.mergeable with
    | Some "MERGEABLE" -> true
    | _ -> false
  in
  []
  |> fun acc -> if owned then acc else "branch_not_owned_by_loop" :: acc
  |> fun acc -> if checks_green then acc else "checks_not_green" :: acc
  |> fun acc -> if review_ok then acc else "review_gate_not_passed" :: acc
  |> fun acc -> if target_main then acc else "base_not_main" :: acc
  |> fun acc -> if mergeable then acc else "not_mergeable" :: acc
  |> List.rev

let merge_command_if_ready (state : state) ~review_ok (candidate : candidate) =
  if (not review_ok) || candidate.kind <> Merge_ready_pr then
    None
  else
    match merge_gate_reasons ~review_ok candidate with
    | [] ->
        Some
          (shell_join
             [
               "gh";
               "pr";
               "merge";
               string_of_int candidate.number;
               "--repo";
               state.repo;
               Printf.sprintf "--%s" state.merge_policy;
               "--delete-branch";
             ])
    | _ -> None

let issue_plan repo_root state (candidate : candidate) =
  let branch_name = issue_branch_name candidate in
  let worktree_path = issue_worktree_path repo_root candidate in
  let commands =
    [
      shell_join [ "gh"; "issue"; "view"; string_of_int candidate.number; "--repo"; state.repo ];
      shell_join [ "git"; "-C"; repo_root; "fetch"; "origin"; "--prune" ];
      shell_join
        [
          "git";
          "-C";
          repo_root;
          "worktree";
          "add";
          "-B";
          branch_name;
          worktree_path;
          "origin/main";
        ];
      shell_join [ "cd"; worktree_path ];
      shell_join [ "./scripts/review/local-review.sh"; "--base"; "origin/main"; "--head"; "HEAD"; "--format"; "markdown" ];
      shell_join [ "./scripts/pr-open.sh"; "--repo"; state.repo; "--no-watch" ];
    ]
  in
  {
    action_id = Printf.sprintf "issue-%d" candidate.number;
    phase = "issue_burn_down";
    summary = Printf.sprintf "Prepare issue #%d in an isolated worktree" candidate.number;
    candidate;
    worktree_path = Some worktree_path;
    branch_name = Some branch_name;
    commands;
    merge_command = None;
    requires_team_session = true;
    notes =
      [
        "Reproduce the issue before editing.";
        "Patch narrowly, then run targeted verification before opening the draft PR.";
      ];
  }

let failing_pr_plan repo_root state (candidate : candidate) =
  let branch_name =
    candidate.head_ref_name |> Option.value ~default:(Printf.sprintf "loop/pr-%d" candidate.number)
  in
  let worktree_path = pr_worktree_path repo_root candidate in
  {
    action_id = Printf.sprintf "pr-%d-failing" candidate.number;
    phase = "pr_failing_checks";
    summary =
      Printf.sprintf "Prepare PR #%d branch for local check/fix work" candidate.number;
    candidate;
    worktree_path = Some worktree_path;
    branch_name = Some branch_name;
    commands =
      [
        shell_join [ "gh"; "pr"; "checks"; string_of_int candidate.number; "--repo"; state.repo ];
        shell_join [ "git"; "-C"; repo_root; "fetch"; "origin"; "--prune" ];
        shell_join
          [
            "git";
            "-C";
            repo_root;
            "worktree";
            "add";
            "-B";
            branch_name;
            worktree_path;
            Printf.sprintf "origin/%s" branch_name;
          ];
        shell_join [ "cd"; worktree_path ];
        shell_join [ "./scripts/review/local-review.sh"; "--base"; "origin/main"; "--head"; "HEAD"; "--format"; "markdown" ];
      ];
    merge_command = None;
    requires_team_session = true;
    notes =
      List.map (fun check_name -> "Failing check: " ^ check_name) candidate.failing_checks;
  }

let conflict_pr_plan repo_root _state (candidate : candidate) =
  let branch_name =
    candidate.head_ref_name |> Option.value ~default:(Printf.sprintf "pr-%d-head" candidate.number)
  in
  let worktree_path = pr_worktree_path repo_root candidate in
  {
    action_id = Printf.sprintf "pr-%d-conflict" candidate.number;
    phase = "pr_conflict";
    summary =
      Printf.sprintf "Prepare PR #%d conflict-resolution worktree" candidate.number;
    candidate;
    worktree_path = Some worktree_path;
    branch_name = Some branch_name;
    commands =
      [
        shell_join [ "git"; "-C"; repo_root; "fetch"; "origin"; "--prune" ];
        shell_join
          [
            "git";
            "-C";
            repo_root;
            "worktree";
            "add";
            "-B";
            branch_name;
            worktree_path;
            Printf.sprintf "origin/%s" branch_name;
          ];
        shell_join [ "git"; "-C"; worktree_path; "merge"; "--no-edit"; "origin/main" ];
        shell_join [ "./scripts/review/local-review.sh"; "--base"; "origin/main"; "--head"; "HEAD"; "--format"; "markdown" ];
      ];
    merge_command = None;
    requires_team_session = false;
    notes =
      [
        "If merge exits non-zero with unmerged paths, keep the worktree and resolve conflicts there.";
      ];
  }

let merge_ready_plan state (candidate : candidate) =
  let merge_command = merge_command_if_ready state ~review_ok:true candidate in
  {
    action_id = Printf.sprintf "pr-%d-merge" candidate.number;
    phase = "merge_ready";
    summary = Printf.sprintf "Merge loop-owned PR #%d" candidate.number;
    candidate;
    worktree_path = None;
    branch_name = candidate.head_ref_name;
    commands = (match merge_command with Some cmd -> [ cmd ] | None -> []);
    merge_command;
    requires_team_session = false;
    notes = [ "Merge only after required checks and cross-model review are both green." ];
  }

let plan_for_candidate repo_root state ?review_ok:(_review_ok = false) candidate =
  match candidate.kind with
  | Merge_ready_pr -> merge_ready_plan state candidate
  | Conflict_pr -> conflict_pr_plan repo_root state candidate
  | Failing_pr -> failing_pr_plan repo_root state candidate
  | Priority_issue | Backlog_issue -> issue_plan repo_root state candidate

let action_plan_to_json (plan : action_plan) =
  `Assoc
    [
      ("action_id", `String plan.action_id);
      ("phase", `String plan.phase);
      ("summary", `String plan.summary);
      ("candidate", candidate_to_json plan.candidate);
      ( "worktree_path",
        Option.fold ~none:`Null ~some:(fun value -> `String value)
          plan.worktree_path );
      ( "branch_name",
        Option.fold ~none:`Null ~some:(fun value -> `String value)
          plan.branch_name );
      ("commands", `List (List.map (fun value -> `String value) plan.commands));
      ( "merge_command",
        Option.fold ~none:`Null ~some:(fun value -> `String value)
          plan.merge_command );
      ("requires_team_session", `Bool plan.requires_team_session);
      ("notes", `List (List.map (fun value -> `String value) plan.notes));
    ]

let command_ok result =
  result.exit_code = 0

let run_and_capture driver argv =
  driver.run_command argv

let team_session_goal_of_plan (state : state) (plan : action_plan) =
  let candidate = plan.candidate in
  let candidate_ref =
    match candidate.kind with
    | Conflict_pr | Failing_pr | Merge_ready_pr ->
        Printf.sprintf "PR #%d" candidate.number
    | Priority_issue | Backlog_issue ->
        Printf.sprintf "Issue #%d" candidate.number
  in
  let header =
    Printf.sprintf
      "Improve-loop lane for %s in repo %s.\nTitle: %s\nPhase: %s"
      candidate_ref state.repo candidate.title plan.phase
  in
  let worktree_hint =
    match plan.worktree_path, plan.branch_name with
    | Some worktree_path, Some branch_name ->
        Printf.sprintf
          "\nPreferred worktree path: %s\nPreferred branch: %s"
          worktree_path branch_name
    | _ -> ""
  in
  let commands =
    if plan.commands = [] then
      ""
    else
      "\nPlanned commands:\n"
      ^ String.concat "\n" (List.map (fun line -> "- " ^ line) plan.commands)
  in
  let notes =
    if plan.notes = [] then
      ""
    else
      "\nConstraints:\n"
      ^ String.concat "\n" (List.map (fun line -> "- " ^ line) plan.notes)
  in
  String.concat "\n"
    [
      header ^ worktree_hint;
      "Required workflow:";
      "- reproduce or inspect the candidate first";
      "- use worktree-first changes";
      "- patch narrowly";
      "- run targeted verification";
      "- open or update a draft PR only after local verification";
      "- do not merge without cross-model review and green required checks";
      commands;
      notes;
    ]

let execute_team_session_plan (ctx : _ context) (state : state) (plan : action_plan) =
  match ctx.sw, ctx.clock with
  | Some sw, Some clock ->
      let team_ctx : _ Tool_team_session.context =
        {
          Tool_team_session.config = ctx.config;
          agent_name = ctx.agent_name;
          sw;
          clock;
          proc_mgr = ctx.proc_mgr;
        }
      in
      let args =
        `Assoc
          [
            ("goal", `String (team_session_goal_of_plan state plan));
            ("duration_seconds", `Int 1800);
            ("checkpoint_interval_sec", `Int 120);
            ("min_agents", `Int 2);
            ("execution_scope", `String "limited_code_change");
            ("orchestration_mode", `String "assist");
            ("communication_mode", `String "broadcast");
            ("instruction_profile", `String "standard");
            ("alert_channel", `String "both");
          ]
      in
      (match Tool_team_session.dispatch team_ctx ~name:"masc_team_session_start" ~args with
       | Some (true, body) -> (
           try
             let json = Yojson.Safe.from_string body in
             Ok
               (`Assoc
                 [
                   ("mode", `String "team_session_started");
                   ("plan", action_plan_to_json plan);
                   ("session", json);
                 ])
           with Yojson.Json_error _ ->
             Ok
               (`Assoc
                 [
                   ("mode", `String "team_session_started");
                   ("plan", action_plan_to_json plan);
                   ("session_raw", `String body);
                 ]))
       | Some (false, message) ->
           Error ("team session start failed: " ^ message)
       | None ->
           Error "team session dispatch unavailable")
  | _ ->
      Error "team session runtime unavailable for improve-loop execute path"

let execute_merge_plan driver (state : state) (plan : action_plan) =
  match plan.merge_command with
  | None -> Error "merge plan missing merge command"
  | Some _ ->
      let argv =
        [
          "gh";
          "pr";
          "merge";
          string_of_int plan.candidate.number;
          "--repo";
          state.repo;
          Printf.sprintf "--%s" state.merge_policy;
          "--delete-branch";
        ]
      in
      let result = run_and_capture driver argv in
      if command_ok result then
        Ok
          (`Assoc
            [
              ("mode", `String "executed");
              ("merged_pr", `Int plan.candidate.number);
            ])
      else
        Error ("gh pr merge failed: " ^ String.trim result.stderr)

let execute_plan driver (_repo_root : string) (ctx : _ context) state
    (plan : action_plan) =
  match plan.phase with
  | "issue_burn_down" | "pr_failing_checks" | "pr_conflict" ->
      execute_team_session_plan ctx state plan
  | "merge_ready" ->
      let plan =
        { plan with merge_command = merge_command_if_ready state ~review_ok:true plan.candidate }
      in
      execute_merge_plan driver state plan
  | _ -> Error ("unknown phase: " ^ plan.phase)

let mark_success state ?merged_pr ?closed_issue ~now ~phase message =
  {
    state with
    status = Running;
    enabled = true;
    current_phase = Some phase;
    last_success = Some message;
    last_failure = None;
    consecutive_failures = 0;
    last_merged_pr = (match merged_pr with Some value -> Some value | None -> state.last_merged_pr);
    last_closed_issue = (match closed_issue with Some value -> Some value | None -> state.last_closed_issue);
    paused_reason = None;
    updated_at = now;
  }

let mark_failure state ~now message =
  let consecutive_failures = state.consecutive_failures + 1 in
  if consecutive_failures >= 3 then
    {
      state with
      enabled = true;
      status = Paused;
      current_phase = Some "paused_after_failures";
      last_failure = Some message;
      consecutive_failures;
      paused_reason = Some "paused_after_three_consecutive_failures";
      updated_at = now;
    }
  else
    {
      state with
      enabled = true;
      status = Running;
      last_failure = Some message;
      consecutive_failures;
      updated_at = now;
    }

let queue_json queue ~limit =
  queue
  |> (fun rows ->
       let rec take acc n = function
         | [] -> List.rev acc
         | _ when n <= 0 -> List.rev acc
         | row :: rest -> take (row :: acc) (n - 1) rest
       in
       take [] limit rows)
  |> List.map candidate_to_json
  |> fun rows -> `List rows

let state_status_json ?plan ?queue (state : state) =
  let base =
    match state_to_json state with
    | `Assoc fields -> fields
    | _ -> []
  in
  let extra =
    (match plan with Some value -> [ ("plan", action_plan_to_json value) ] | None -> [])
    @
    match queue with
    | Some (rows, limit) -> [ ("queue", queue_json rows ~limit); ("queue_size", `Int (List.length rows)) ]
    | None -> []
  in
  `Assoc (base @ extra)

let tick_due (state : state) ~now =
  if not state.enabled || state.status <> Running then
    false
  else if state.last_success = None && state.last_failure = None
          && state.current_candidate = None
  then
    true
  else
    now -. state.updated_at >= float_of_int (max 30 state.poll_interval_sec)

let resolve_selected_candidate state queue =
  match state.current_candidate with
  | Some current ->
      option_or_else
        (List.find_opt
           (fun candidate -> String.equal (candidate_id candidate) (candidate_id current))
           queue)
        (fun () -> list_hd_opt queue)
  | None -> list_hd_opt queue

let tick_with_driver (driver : driver) (ctx : _ context) args : result =
  let state = load_state ctx.config in
  let limit = max 1 (get_int args "limit" 10) in
  let review_ok = get_bool args "review_ok" false in
  if not state.enabled || state.status = Disabled then
    (true, Yojson.Safe.pretty_to_string (state_status_json state))
  else if state.status = Paused then
    (true, Yojson.Safe.pretty_to_string (state_status_json state))
  else
    let now = driver.now () in
    match driver.list_prs ~repo:state.repo, driver.list_issues ~repo:state.repo with
    | Error pr_error, _ ->
        let updated = mark_failure state ~now ("gh pr list failed: " ^ pr_error) in
        save_state ctx.config updated;
        append_event ctx.config "tick_failure"
          (`Assoc [ ("reason", `String pr_error) ]);
        (false, Yojson.Safe.pretty_to_string (state_status_json updated))
    | _, Error issue_error ->
        let updated = mark_failure state ~now ("gh issue list failed: " ^ issue_error) in
        save_state ctx.config updated;
        append_event ctx.config "tick_failure"
          (`Assoc [ ("reason", `String issue_error) ]);
        (false, Yojson.Safe.pretty_to_string (state_status_json updated))
    | Ok prs, Ok issues ->
        let queue = rank_candidates ~review_ok ~prs ~issues () in
        match resolve_selected_candidate state queue with
        | None ->
            let updated =
              {
                state with
                current_candidate = None;
                current_phase = Some "idle";
                last_success = Some "queue_empty";
                updated_at = now;
              }
            in
            save_state ctx.config updated;
            append_event ctx.config "tick_idle"
              (`Assoc [ ("repo", `String state.repo) ]);
            (true, Yojson.Safe.pretty_to_string (state_status_json ~queue:(queue, limit) updated))
        | Some candidate ->
            let repo_root = repo_root ctx.config in
            let planned_state =
              {
                state with
                current_candidate = Some candidate;
                current_phase = Some (candidate_kind_to_string candidate.kind);
                updated_at = now;
              }
            in
            let plan = plan_for_candidate repo_root planned_state ~review_ok candidate in
            let execute = get_bool args "execute" (not state.dry_run) in
            if not execute || state.dry_run then begin
              save_state ctx.config planned_state;
              append_event ctx.config "tick_planned"
                (`Assoc
                  [
                    ("candidate", candidate_to_json candidate);
                    ("plan", action_plan_to_json plan);
                  ]);
              (true,
               Yojson.Safe.pretty_to_string
                 (state_status_json ~plan ~queue:(queue, limit) planned_state))
            end else
              match execute_plan driver repo_root ctx planned_state plan with
              | Ok exec_json ->
                  let updated =
                    mark_success planned_state ~now ~phase:plan.phase
                      (Printf.sprintf "executed %s" plan.action_id)
                      ?merged_pr:
                        (if plan.phase = "merge_ready" then Some candidate.number else None)
                  in
                  save_state ctx.config updated;
                  append_event ctx.config "tick_executed"
                    (`Assoc
                      [
                        ("candidate", candidate_to_json candidate);
                        ("plan", action_plan_to_json plan);
                        ("execution", exec_json);
                      ]);
                  let json =
                    match state_status_json ~plan ~queue:(queue, limit) updated with
                    | `Assoc fields -> `Assoc (("execution", exec_json) :: fields)
                    | other -> other
                  in
                  (true, Yojson.Safe.pretty_to_string json)
              | Error message ->
                  let updated = mark_failure planned_state ~now message in
                  save_state ctx.config updated;
                  append_event ctx.config "tick_failure"
                    (`Assoc
                      [
                        ("candidate", candidate_to_json candidate);
                        ("plan", action_plan_to_json plan);
                        ("reason", `String message);
                      ]);
                  let json =
                    match state_status_json ~plan ~queue:(queue, limit) updated with
                    | `Assoc fields -> `Assoc (("execution_error", `String message) :: fields)
                    | other -> other
                  in
                  (false, Yojson.Safe.pretty_to_string json)

let handle_start (ctx : _ context) args =
  let current = load_state ctx.config in
  let now = Time_compat.now () in
  let state =
    {
      current with
      enabled = true;
      status = Running;
      keeper_name = get_string args "keeper_name" current.keeper_name;
      poll_interval_sec = max 30 (get_int args "poll_interval_sec" current.poll_interval_sec);
      repo = get_string args "repo" current.repo;
      repo_scope = default_repo_scope;
      merge_policy = default_merge_policy;
      dry_run = get_bool args "dry_run" current.dry_run;
      paused_reason = None;
      updated_at = now;
    }
  in
  save_state ctx.config state;
  append_event ctx.config "loop_started"
    (`Assoc
      [
        ("agent_name", `String ctx.agent_name);
        ("state", state_to_json state);
      ]);
  (true, Yojson.Safe.pretty_to_string (state_status_json state))

let handle_status (ctx : _ context) _args =
  let state = load_state ctx.config in
  (true, Yojson.Safe.pretty_to_string (state_status_json state))

let handle_pause (ctx : _ context) args =
  let current = load_state ctx.config in
  let state =
    {
      current with
      enabled = true;
      status = Paused;
      paused_reason = Some (get_string args "reason" "manual_pause");
      updated_at = Time_compat.now ();
    }
  in
  save_state ctx.config state;
  append_event ctx.config "loop_paused"
    (`Assoc
      [
        ("agent_name", `String ctx.agent_name);
        ("reason", Option.fold ~none:`Null ~some:(fun value -> `String value) state.paused_reason);
      ]);
  (true, Yojson.Safe.pretty_to_string (state_status_json state))

let handle_resume (ctx : _ context) args =
  let current = load_state ctx.config in
  let state =
    {
      current with
      enabled = true;
      status = Running;
      dry_run = get_bool args "dry_run" current.dry_run;
      paused_reason = None;
      updated_at = Time_compat.now ();
    }
  in
  save_state ctx.config state;
  append_event ctx.config "loop_resumed"
    (`Assoc [ ("agent_name", `String ctx.agent_name); ("state", state_to_json state) ]);
  (true, Yojson.Safe.pretty_to_string (state_status_json state))

let maybe_tick_from_keepalive ~(config : Room.config) ~(agent_name : string)
    ~(keeper_name : string) ~(sw : Eio.Switch.t)
    ~(clock : _ Eio.Time.clock)
    ~(proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option) () =
  let state = load_state config in
  let now = Time_compat.now () in
  if state.enabled && state.status = Running
     && String.equal state.keeper_name keeper_name
     && tick_due state ~now
  then
    let ctx = { config; agent_name; sw = Some sw; clock = Some clock; proc_mgr } in
    let _ok, _body =
      tick_with_driver default_driver ctx
        (`Assoc [ ("execute", `Bool true) ])
    in
    ()
  else
    ()

let dispatch (ctx : _ context) ~name ~args : result option =
  match name with
  | "masc_improve_loop_start" -> Some (handle_start ctx args)
  | "masc_improve_loop_status" -> Some (handle_status ctx args)
  | "masc_improve_loop_pause" -> Some (handle_pause ctx args)
  | "masc_improve_loop_resume" -> Some (handle_resume ctx args)
  | "masc_improve_loop_tick" -> Some (tick_with_driver default_driver ctx args)
  | _ -> None
