(** Code Swarm Plan — Parallel code modification via team_session workers.

    Grep pattern → file collection → worker splitting → verify → merge.
    Uses team_session for worker lifecycle, verifier.ml for diff validation,
    and tool_worktree for git worktree isolation.

    @since 2.100.0 *)

open Printf

(* ================================================================ *)
(* Types                                                            *)
(* ================================================================ *)

type worker_plan = {
  worker_id : string;
  files : string list;
  match_count : int;
  worktree_branch : string;
}

type swarm_plan = {
  plan_id : string;
  pattern : string;
  file_glob : string;
  total_matches : int;
  workers : worker_plan list;
  team_session_goal : string;
  created_at : float;
  base_path : string;
}

type verdict = Pass | Warn of string | Fail of string

type worker_verify_result = {
  worker_id : string;
  files_changed : int;
  diff_summary : string;
  verdict : verdict;
  issues : string list;
}

type verify_result = {
  results : worker_verify_result list;
  all_pass : bool;
  pass_count : int;
  fail_count : int;
}

type merge_result = {
  merged_branch : string;
  files_changed : int;
  conflicts : string list;
  build_ok : bool;
  skipped_workers : string list;
  pr_url : string option;
}

(* ================================================================ *)
(* Plan storage                                                     *)
(* ================================================================ *)

let plans_dir base_path =
  let d = Filename.concat base_path ".masc/code_swarm_plans" in
  Fs_compat.mkdir_p d;
  d

(** Validate plan_id: alphanumeric + dash only, no path separators. *)
let validate_plan_id plan_id =
  let is_safe c =
    match c with
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' -> true
    | _ -> false
  in
  String.length plan_id > 0
  && String.length plan_id <= 64
  && String.to_seq plan_id |> Seq.for_all is_safe

let plan_file base_path plan_id =
  if not (validate_plan_id plan_id) then
    Error (sprintf "Invalid plan_id: %s" plan_id)
  else
    Ok (Filename.concat (plans_dir base_path) (plan_id ^ ".json"))

let save_plan (plan : swarm_plan) =
  let workers_json =
    `List
      (List.map
         (fun (w : worker_plan) ->
           `Assoc
             [
               ("worker_id", `String w.worker_id);
               ("files", `List (List.map (fun f -> `String f) w.files));
               ("match_count", `Int w.match_count);
               ("worktree_branch", `String w.worktree_branch);
             ])
         plan.workers)
  in
  let json =
    `Assoc
      [
        ("plan_id", `String plan.plan_id);
        ("pattern", `String plan.pattern);
        ("file_glob", `String plan.file_glob);
        ("total_matches", `Int plan.total_matches);
        ("workers", workers_json);
        ("team_session_goal", `String plan.team_session_goal);
        ("created_at", `Float plan.created_at);
        ("base_path", `String plan.base_path);
      ]
  in
  match plan_file plan.base_path plan.plan_id with
  | Error e -> Log.Misc.error "save_plan: %s" e
  | Ok path -> Fs_compat.save_file path (Yojson.Safe.pretty_to_string json)

let load_plan base_path plan_id : (swarm_plan, string) result =
  match plan_file base_path plan_id with
  | Error e -> Error e
  | Ok path ->
  if not (Sys.file_exists path) then Error (sprintf "Plan not found: %s" plan_id)
  else
    try
      let json = Safe_ops.read_json_eio path in
      let open Yojson.Safe.Util in
      let workers =
        json |> member "workers" |> to_list
        |> List.map (fun w ->
               {
                 worker_id = w |> member "worker_id" |> to_string;
                 files =
                   w |> member "files" |> to_list
                   |> List.map to_string;
                 match_count = w |> member "match_count" |> to_int;
                 worktree_branch = w |> member "worktree_branch" |> to_string;
               })
      in
      Ok
        {
          plan_id = json |> member "plan_id" |> to_string;
          pattern = json |> member "pattern" |> to_string;
          file_glob = json |> member "file_glob" |> to_string;
          total_matches = json |> member "total_matches" |> to_int;
          workers;
          team_session_goal = json |> member "team_session_goal" |> to_string;
          created_at = json |> member "created_at" |> to_float;
          base_path = json |> member "base_path" |> to_string;
        }
    with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Error (sprintf "Failed to load plan: %s" (Printexc.to_string exn))

(* ================================================================ *)
(* Plan — grep + split                                              *)
(* ================================================================ *)

(** Run grep to find files matching pattern within glob.
    Returns (file_path, match_count) list sorted by match_count desc. *)
let grep_matches ~base_path ~pattern ~file_glob ~exclude_files =
  let argv =
    [ "grep"; "-rc"; "--include=" ^ file_glob; "-E"; pattern; base_path ]
  in
  let output =
    try Process_eio.run_argv ~timeout_sec:30.0 argv
    with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
      Log.CodeSwarm.error "grep failed: %s" (Printexc.to_string exn);
      ""
  in
  output |> String.split_on_char '\n'
  |> List.filter_map (fun line ->
         match String.split_on_char ':' line with
         | [] | [ _ ] -> None
         | file :: rest -> (
             let count_str = String.concat ":" rest in
             match int_of_string_opt (String.trim count_str) with
             | Some n when n > 0 ->
                 let blen = String.length base_path in
                 let flen = String.length file in
                 let rel =
                   if flen > blen + 1
                      && String.sub file 0 blen = base_path
                      && file.[blen] = '/' then
                     String.sub file (blen + 1) (flen - blen - 1)
                   else file
                 in
                 if List.mem rel exclude_files then None
                 else Some (rel, n)
             | _ -> None))
  |> List.sort (fun (_, a) (_, b) -> compare b a)

(** Split files into N workers, balancing by match count (greedy bin-packing). *)
let split_into_workers ~max_workers files_with_counts =
  let n = min max_workers (max 1 (List.length files_with_counts)) in
  let bins = Array.init n (fun _ -> (ref [], ref 0)) in
  (* Greedy: assign each file to the bin with smallest total *)
  List.iter
    (fun (file, count) ->
      let min_idx = ref 0 in
      let min_val = ref max_int in
      Array.iteri
        (fun i (_, total) ->
          if !(total) < !min_val then (
            min_idx := i;
            min_val := !(total)))
        bins;
      let files_ref, total_ref = bins.(!min_idx) in
      files_ref := (file, count) :: !files_ref;
      total_ref := !(total_ref) + count)
    files_with_counts;
  Array.to_list bins
  |> List.mapi (fun i (files_ref, _) ->
         let file_list = List.rev !files_ref in
         let match_total =
           List.fold_left (fun acc (_, c) -> acc + c) 0 file_list
         in
         {
           worker_id = sprintf "worker-%d" i;
           files = List.map fst file_list;
           match_count = match_total;
           worktree_branch =
             sprintf "code-swarm/%s/worker-%d"
               (string_of_int (int_of_float (Unix.gettimeofday () *. 1000.0)
                               mod 100000))
               i;
         })
  |> List.filter (fun w -> w.files <> [])

let create_plan ~base_path ~pattern ~file_glob ~max_workers ~exclude_files =
  let hard_limit = max_workers |> max 1 |> min 5 in
  let files_with_counts =
    grep_matches ~base_path ~pattern ~file_glob ~exclude_files
  in
  let total_matches =
    List.fold_left (fun acc (_, c) -> acc + c) 0 files_with_counts
  in
  if total_matches = 0 then
    Error (sprintf "No matches found for pattern '%s' in '%s'" pattern file_glob)
  else
    let workers = split_into_workers ~max_workers:hard_limit files_with_counts in
    let plan_id =
      sprintf "swarm-%d" (int_of_float (Unix.gettimeofday () *. 1000.0) mod 1000000)
    in
    let plan =
      {
        plan_id;
        pattern;
        file_glob;
        total_matches;
        workers;
        team_session_goal =
          sprintf
            "Apply pattern transformation: grep '%s' across %d files in %d workers"
            pattern total_matches (List.length workers);
        created_at = Unix.gettimeofday ();
        base_path;
      }
    in
    save_plan plan;
    Ok plan

(* ================================================================ *)
(* Verify — diff collection + MODEL verification                     *)
(* ================================================================ *)

(** Get git diff from a worktree branch *)
let get_worker_diff ~base_path (worker : worker_plan) =
  let worktree_path =
    Filename.concat base_path
      (sprintf ".worktrees/%s" worker.worktree_branch)
  in
  if not (Sys.file_exists worktree_path) then
    ("(worktree not found)", 0)
  else
    let argv =
      [ "git"; "-C"; worktree_path; "diff"; "--stat"; "HEAD~1..HEAD" ]
    in
    let stat =
      try Process_eio.run_argv ~timeout_sec:15.0 argv
      with
      | Eio.Io _ | Unix.Unix_error _ | Failure _ as exn ->
        Log.CodeSwarm.warn "git diff --stat failed: %s"
          (Printexc.to_string exn);
        ""
    in
    let argv_full =
      [ "git"; "-C"; worktree_path; "diff"; "HEAD~1..HEAD" ]
    in
    let diff =
      try Process_eio.run_argv ~timeout_sec:15.0 argv_full
      with
      | Eio.Io _ | Unix.Unix_error _ | Failure _ as exn ->
        Log.CodeSwarm.warn "git diff failed: %s"
          (Printexc.to_string exn);
        ""
    in
    let changed =
      stat |> String.split_on_char '\n'
      |> List.filter (fun l -> String.contains l '|')
      |> List.length
    in
    (diff, changed)

(** Build a verification prompt for a code diff. *)
let build_verify_prompt ~pattern ~allowed_files diff =
  let files_str = String.concat ", " allowed_files in
  let truncated_diff =
    if String.length diff > 2000 then String.sub diff 0 2000 ^ "\n..."
    else diff
  in
  sprintf
    {|You are a code review verifier. Check this diff for correctness.

Pattern being applied: %s
Allowed files: %s

Diff:
%s

Check:
1. Does the diff ONLY modify files in the allowed list? (scope creep)
2. Does the code look syntactically valid?
3. Does the change preserve the original return values and behavior?

Respond with exactly one of:
PASS - if the diff is correct and scoped
WARN: <reason> - if acceptable but has concerns
FAIL: <reason> - if the diff has problems

One line only.|}
    pattern files_str truncated_diff

let verify_worker ~pattern (worker : worker_plan) diff =
  if String.length diff = 0 then
    {
      worker_id = worker.worker_id;
      files_changed = 0;
      diff_summary = "(no changes)";
      verdict = Warn "no changes produced";
      issues = [ "Worker produced no diff" ];
    }
  else
    let prompt = build_verify_prompt ~pattern ~allowed_files:worker.files diff in
    let verdict =
      match
        Oas_worker.run_named ~cascade_name:"code_swarm_verify"
          ~goal:prompt ~max_turns:1
          ~temperature:0.0 ~max_tokens:200
          ~priority:Oas.Llm_provider.Request_priority.Proactive ()
      with
      | Ok result ->
        (match Verifier_oas.parse_verdict (Oas_response.text_of_response result.Oas_worker.response) with
         | Ok v -> v
         | Error parse_err -> Verifier_oas.Warn ("verdict_parse_failed: " ^ parse_err))
      | Error e -> Verifier_oas.Warn ("verifier_unavailable: " ^ e)
    in
    let our_verdict =
      match verdict with
      | Verifier_oas.Pass -> Pass
      | Verifier_oas.Warn s -> Warn s
      | Verifier_oas.Fail s -> Fail s
    in
    let issues =
      match our_verdict with
      | Pass -> []
      | Warn s -> [ s ]
      | Fail s -> [ s ]
    in
    let stat_lines =
      diff |> String.split_on_char '\n'
      |> List.filteri (fun i _ -> i < 5)
      |> String.concat "\n"
    in
    {
      worker_id = worker.worker_id;
      files_changed =
        (diff |> String.split_on_char '\n'
        |> List.filter (fun l ->
               String.length l > 0
               && (l.[0] = '+' || l.[0] = '-')
               && not (String.length l > 3 && String.sub l 0 3 = "+++"
                       || String.length l > 3 && String.sub l 0 3 = "---"))
        |> List.length);
      diff_summary = stat_lines;
      verdict = our_verdict;
      issues;
    }

let verify_plan ~base_path ~plan_id ~verify_model:_ =
  match load_plan base_path plan_id with
  | Error e -> Error e
  | Ok plan ->
      let results =
        List.map
          (fun worker ->
            let diff, _changed = get_worker_diff ~base_path worker in
            verify_worker ~pattern:plan.pattern worker diff)
          plan.workers
      in
      let pass_count =
        List.length
          (List.filter (fun r -> match r.verdict with Pass -> true | _ -> false) results)
      in
      let fail_count =
        List.length
          (List.filter (fun r -> match r.verdict with Fail _ -> true | _ -> false) results)
      in
      Ok
        {
          results;
          all_pass = fail_count = 0;
          pass_count;
          fail_count;
        }

(* ================================================================ *)
(* Merge — cherry-pick + build + PR                                 *)
(* ================================================================ *)

let merge_workers ~base_path ~plan_id ~strategy ~auto_pr ~build_verify
    ~require_all_pass =
  match load_plan base_path plan_id with
  | Error e -> Error e
  | Ok plan -> (
      (* Determine which workers to include *)
      let verify_result = verify_plan ~base_path ~plan_id ~verify_model:None in
      let verdicts =
        match verify_result with
        | Ok vr -> vr.results
        | Error _ -> []
      in
      let is_passing wid =
        match
          List.find_opt (fun (r : worker_verify_result) -> r.worker_id = wid) verdicts
        with
        | Some r -> (
            match r.verdict with Pass -> true | Warn _ -> true | Fail _ -> false)
        | None -> not require_all_pass
      in
      let passing_workers =
        List.filter (fun (w : worker_plan) -> is_passing w.worker_id) plan.workers
      in
      let skipped =
        List.filter_map
          (fun (w : worker_plan) ->
            if is_passing w.worker_id then None else Some w.worker_id)
          plan.workers
      in
      if passing_workers = [] then
        Error "No workers passed verification"
      else
        let merged_branch =
          sprintf "code-swarm/%s/merged" plan.plan_id
        in
        (* Create merge branch from main *)
        let create_branch =
          Process_eio.run_argv_with_status ~timeout_sec:30.0
            [ "git"; "-C"; base_path; "checkout"; "-b"; merged_branch; "main" ]
        in
        let branch_ok =
          match create_branch with
          | Unix.WEXITED 0, _ -> true
          | _ -> false
        in
        if not branch_ok then
          let _, msg = create_branch in
          Error
            (sprintf "Failed to create merge branch '%s': %s"
               merged_branch msg)
        else
        (* Cherry-pick or merge each worker *)
        let conflicts = ref [] in
        let total_files = ref 0 in
        List.iter
          (fun (worker : worker_plan) ->
            let worktree_path =
              Filename.concat base_path
                (sprintf ".worktrees/%s" worker.worktree_branch)
            in
            let argv =
              match strategy with
              | "octopus" ->
                  [ "git"; "-C"; base_path; "merge"; "--no-ff";
                    worker.worktree_branch ]
              | _ (* sequential *) ->
                  let commit_argv =
                    [ "git"; "-C"; worktree_path; "rev-parse"; "HEAD" ]
                  in
                  let commit =
                    try
                      String.trim
                        (Process_eio.run_argv ~timeout_sec:10.0 commit_argv)
                    with
                    | Eio.Io _ | Unix.Unix_error _ | Failure _ as exn ->
                      Log.CodeSwarm.warn
                        "git rev-parse failed for %s: %s"
                        worker.worker_id (Printexc.to_string exn);
                      worker.worktree_branch
                  in
                  [ "git"; "-C"; base_path; "cherry-pick"; commit ]
            in
            let status, output =
              Process_eio.run_argv_with_status ~timeout_sec:60.0 argv
            in
            let abort_cmd =
              match strategy with
              | "octopus" -> "merge"
              | _ -> "cherry-pick"
            in
            (match status with
            | Unix.WEXITED 0 ->
                total_files := !total_files + List.length worker.files
            | _ ->
                conflicts := worker.worker_id :: !conflicts;
                ignore
                  (Process_eio.run_argv_with_status ~timeout_sec:10.0
                     [ "git"; "-C"; base_path; abort_cmd; "--abort" ]);
                Log.CodeSwarm.warn "merge conflict for %s: %s"
                  worker.worker_id output))
          passing_workers;
        (* Build verification *)
        let build_ok =
          if build_verify then
            let status, _ =
              Process_eio.run_argv_with_status ~timeout_sec:120.0
                [ "dune"; "build"; "--root"; base_path ]
            in
            match status with Unix.WEXITED 0 -> true | _ -> false
          else true
        in
        (* Auto PR *)
        let pr_url =
          if auto_pr && !conflicts = [] && build_ok then
            let body =
              sprintf "Code swarm: applied pattern '%s' across %d files\n\nPlan: %s\nWorkers: %d\nSkipped: %s"
                plan.pattern !total_files plan.plan_id
                (List.length passing_workers)
                (String.concat ", " skipped)
            in
            let status, output =
              Process_eio.run_argv_with_status ~timeout_sec:60.0
                [
                  "gh"; "pr"; "create"; "--draft";
                  "--title";
                  sprintf "[code-swarm] %s" plan.pattern;
                  "--body"; body;
                  "--head"; merged_branch;
                ]
            in
            match status with
            | Unix.WEXITED 0 -> Some (String.trim output)
            | _ ->
                Log.CodeSwarm.error "PR creation failed: %s" output;
                None
          else None
        in
        (* Cleanup worker worktrees *)
        List.iter
          (fun (worker : worker_plan) ->
            let wt_path =
              Filename.concat base_path
                (sprintf ".worktrees/%s" worker.worktree_branch)
            in
            if Sys.file_exists wt_path then
              ignore
                (Process_eio.run_argv_with_status ~timeout_sec:30.0
                   [
                     "git"; "-C"; base_path; "worktree"; "remove";
                     "--force"; wt_path;
                   ]))
          plan.workers;
        Ok
          {
            merged_branch;
            files_changed = !total_files;
            conflicts = !conflicts;
            build_ok;
            skipped_workers = skipped;
            pr_url;
          })

(* ================================================================ *)
(* JSON serialization helpers                                       *)
(* ================================================================ *)

let verdict_to_string = function
  | Pass -> "PASS"
  | Warn s -> sprintf "WARN: %s" s
  | Fail s -> sprintf "FAIL: %s" s

let plan_to_json (plan : swarm_plan) =
  `Assoc
    [
      ("plan_id", `String plan.plan_id);
      ("total_matches", `Int plan.total_matches);
      ("worker_count", `Int (List.length plan.workers));
      ("team_session_goal", `String plan.team_session_goal);
      ( "workers",
        `List
          (List.map
             (fun (w : worker_plan) ->
               `Assoc
                 [
                   ("worker_id", `String w.worker_id);
                   ("files", `List (List.map (fun f -> `String f) w.files));
                   ("match_count", `Int w.match_count);
                   ("worktree_branch", `String w.worktree_branch);
                 ])
             plan.workers) );
    ]

let verify_result_to_json (vr : verify_result) =
  `Assoc
    [
      ("all_pass", `Bool vr.all_pass);
      ("pass_count", `Int vr.pass_count);
      ("fail_count", `Int vr.fail_count);
      ( "results",
        `List
          (List.map
             (fun (r : worker_verify_result) ->
               `Assoc
                 [
                   ("worker_id", `String r.worker_id);
                   ("files_changed", `Int r.files_changed);
                   ("diff_summary", `String r.diff_summary);
                   ("verdict", `String (verdict_to_string r.verdict));
                   ("issues", `List (List.map (fun s -> `String s) r.issues));
                 ])
             vr.results) );
    ]

let merge_result_to_json (mr : merge_result) =
  `Assoc
    [
      ("merged_branch", `String mr.merged_branch);
      ("files_changed", `Int mr.files_changed);
      ("conflicts", `List (List.map (fun s -> `String s) mr.conflicts));
      ("build_ok", `Bool mr.build_ok);
      ("skipped_workers", `List (List.map (fun s -> `String s) mr.skipped_workers));
      ( "pr_url",
        match mr.pr_url with Some u -> `String u | None -> `Null );
    ]
