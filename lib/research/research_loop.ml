(** Research_loop — Automated code improvement via LLM.

    Core loop:
    1. Gather repo context (recent commits, TODOs, file list)
    2. Ask LLM to propose a hypothesis (via OAS cascade)
    3. Create isolated worktree
    4. Apply proposed change
    5. Build + test → measure metrics
    6. Keep or discard
    7. Log result to TSV
    8. Repeat *)

type hypothesis = {
  description : string;
  target_file : string;
  rationale : string;
  patch : string;
  old_text : string;  (** search text for search-replace mode (empty = use patch mode) *)
  new_text : string;  (** replacement text for search-replace mode *)
}

type experiment_entry = {
  id : string;
  hypothesis : hypothesis;
  metric : Research_metric.t;
}

let log_best_effort_failure step exn =
  Log.Server.warn "research: %s failed: %s" step (Printexc.to_string exn)

(** Gather minimal context about the repo for the LLM. *)
let gather_context ~(config : Research_config.repo_config) : string =
  let parts = Buffer.create 2048 in
  (* Recent commits *)
  (try
    let _, stdout =
      Process_eio.run_argv_with_status ~timeout_sec:5.0
        [ "git"; "-C"; config.path; "log"; "--oneline"; "-10" ]
    in
    Buffer.add_string parts "## Recent commits\n```\n";
    Buffer.add_string parts stdout;
    Buffer.add_string parts "```\n\n"
  with exn -> log_best_effort_failure "git log context" exn);
  (* OCaml source files *)
  (try
    let _, stdout =
      Process_eio.run_argv_with_status ~timeout_sec:10.0
        [ "find"; config.path ^ "/lib"; "-name"; "*.ml"; "-type"; "f" ]
    in
    let files = String.split_on_char '\n' stdout
      |> List.filter (fun s -> String.length s > 0) in
    let count = List.length files in
    let sample = if count > 30 then List.filteri (fun i _ -> i < 30) files else files in
    Buffer.add_string parts (Printf.sprintf "## OCaml source files (%d)\n```\n" count);
    List.iter (fun f -> Buffer.add_string parts f; Buffer.add_char parts '\n') sample;
    if count > 30 then
      Buffer.add_string parts (Printf.sprintf "... and %d more\n" (count - 30));
    Buffer.add_string parts "```\n\n"
  with exn -> log_best_effort_failure "source file context" exn);
  (* API surface from .mli files — prevents LLM from hallucinating APIs *)
  (try
    let _, stdout =
      Process_eio.run_argv_with_status ~timeout_sec:10.0
        [ "grep"; "-rn"; "^val "; config.path ^ "/lib"; "--include=*.mli" ]
    in
    let sigs = String.split_on_char '\n' stdout
      |> List.filter (fun s -> String.length s > 0) in
    let count = List.length sigs in
    if count > 0 then begin
      let sample = if count > 40 then List.filteri (fun i _ -> i < 40) sigs else sigs in
      Buffer.add_string parts (Printf.sprintf "## Public API signatures (%d total, from .mli files)\n```\n" count);
      List.iter (fun s -> Buffer.add_string parts s; Buffer.add_char parts '\n') sample;
      if count > 40 then
        Buffer.add_string parts (Printf.sprintf "... and %d more\n" (count - 40));
      Buffer.add_string parts "```\n\n"
    end
  with exn -> log_best_effort_failure "signature context" exn);
  (* TODOs *)
  (try
    let _, stdout =
      Process_eio.run_argv_with_status ~timeout_sec:10.0
        [ "git"; "-C"; config.path; "grep"; "-n"; "-i"; "TODO\\|FIXME\\|HACK"; "--"; "*.ml" ]
    in
    let todos = String.split_on_char '\n' stdout
      |> List.filter (fun s -> String.length s > 0) in
    let count = List.length todos in
    if count > 0 then begin
      let sample = if count > 15 then List.filteri (fun i _ -> i < 15) todos else todos in
      Buffer.add_string parts (Printf.sprintf "## TODOs/FIXMEs (%d total)\n```\n" count);
      List.iter (fun t -> Buffer.add_string parts t; Buffer.add_char parts '\n') sample;
      Buffer.add_string parts "```\n\n"
    end;
    (* Code snippets around TODOs — gives LLM actual code context *)
    let snippets_added = ref 0 in
    let max_snippets = 3 in
    List.iter (fun todo_line ->
      if !snippets_added < max_snippets then begin
        (* Parse "file:line:content" format *)
        match String.split_on_char ':' todo_line with
        | file :: line_str :: _ ->
          (try
            let line_num = int_of_string (String.trim line_str) in
            let start_line = max 1 (line_num - 15) in
            let end_line = line_num + 15 in
            let file_path = Printf.sprintf "%s/%s" config.path file in
            if Sys.file_exists file_path then begin
              let _, snippet =
                Process_eio.run_argv_with_status ~timeout_sec:5.0
                  [ "sed"; "-n"; Printf.sprintf "%d,%dp" start_line end_line; file_path ]
              in
              if String.length snippet > 0 then begin
                Buffer.add_string parts
                  (Printf.sprintf "## Code around %s:%d\n```ocaml\n" file line_num);
                Buffer.add_string parts snippet;
                Buffer.add_string parts "```\n\n";
                incr snippets_added
              end
            end
          with exn -> log_best_effort_failure "TODO snippet context" exn)
        | _ -> ()
      end
    ) (if count > 3 then List.filteri (fun i _ -> i < 3) todos else todos)
  with exn -> log_best_effort_failure "TODO context" exn);
  Buffer.contents parts

(** Parse a JSON hypothesis from LLM response. *)
let parse_hypothesis (response : string) : hypothesis option =
  (* Strip markdown code fences if present *)
  let stripped =
    let s = String.trim response in
    if String.length s > 6 && String.sub s 0 3 = "```" then
      let lines = String.split_on_char '\n' s in
      let inner = List.filter (fun l ->
        not (String.length l >= 3 && String.sub l 0 3 = "```")
      ) lines in
      String.concat "\n" inner
    else s
  in
  try
    let json = Yojson.Safe.from_string stripped in
    let open Yojson.Safe.Util in
    let str_or_empty key = match member key json with `String s -> s | _ -> "" in
    Some {
      description = json |> member "description" |> to_string;
      target_file = json |> member "target_file" |> to_string;
      rationale = json |> member "rationale" |> to_string;
      patch = str_or_empty "patch";
      old_text = str_or_empty "old_text";
      new_text = str_or_empty "new_text";
    }
  with exn ->
    log_best_effort_failure "hypothesis parse" exn;
    None

(** Detect no-op hypotheses that would not change any code. *)
let is_noop_hypothesis (h : hypothesis) : bool =
  (* old_text == new_text → search-replace with no change *)
  (h.old_text <> "" && h.old_text = h.new_text)
  (* both patch and old_text empty → nothing to apply *)
  || (h.patch = "" && h.old_text = "")
  (* target_file empty *)
  || h.target_file = ""

(** Format experiment history for context. *)
let history_context (history : experiment_entry list) : string =
  if history = [] then ""
  else begin
    let buf = Buffer.create 512 in
    Buffer.add_string buf "\n## Previous experiments\n";
    let recent = if List.length history > 5
      then List.filteri (fun i _ -> i >= List.length history - 5) history
      else history in
    List.iter (fun (e : experiment_entry) ->
      Buffer.add_string buf (Printf.sprintf "- %s: %s (test_pass=%.2f)\n"
        e.hypothesis.description
        (Research_metric.status_to_string e.metric.status)
        e.metric.test_pass_rate)
    ) recent;
    Buffer.contents buf
  end

(** Call LLM via OAS cascade with retry on empty content.
    GLM reasoning mode can consume all tokens on reasoning, returning empty content.
    Retry up to 2 times before giving up. *)
let generate_hypothesis ~sw ~net ~clock ~(config : Research_config.t)
    ~context ~history : hypothesis option =
  let max_attempts = 3 in
  let rec try_generate attempt =
    if attempt >= max_attempts then begin
      Log.Server.warn "research: LLM returned empty content after %d attempts, giving up" max_attempts;
      None
    end else
  let history_text = history_context history in
  let user_msg = Printf.sprintf
    "Here is the repository context:\n\n%s%s\n\n\
     Propose a code improvement experiment. Focus on code that has TODOs, FIXMEs, \
     or obvious simplification opportunities. Respond with a JSON object."
    context history_text
  in
  let messages : Llm_provider.Types.message list = [
    { role = User; content = [Text user_msg]; name = None; tool_call_id = None };
  ] in
  Log.Server.info "research: calling LLM via OAS cascade '%s' (timeout=%ds)"
    config.cascade_name config.timeout_sec;
  match
    Llm_provider.Cascade_config.complete_named ~sw ~net ~clock
      ~name:config.cascade_name
      ~defaults:config.cascade_defaults
      ~messages
      ~system_prompt:config.system_prompt
      ~temperature:config.temperature
      ~max_tokens:config.max_tokens
      ~timeout_sec:config.timeout_sec
      ~priority:Llm_provider.Request_priority.Background
      ()
  with
  | Ok resp ->
    let content = Llm_provider.Cascade_config.text_of_response resp in
    if String.length (String.trim content) = 0 then begin
      Log.Server.warn "research: LLM returned empty content (attempt %d/%d)" (attempt + 1) max_attempts;
      try_generate (attempt + 1)
    end else
      parse_hypothesis content
  | Error err ->
    let msg = match err with
      | Llm_provider.Http_client.HttpError { code; _ } ->
        Printf.sprintf "HTTP %d" code
      | Llm_provider.Http_client.NetworkError { message } -> message
    in
    Log.Server.warn "research: LLM cascade failed (attempt %d/%d): %s" (attempt + 1) max_attempts msg;
    try_generate (attempt + 1)
  in
  try_generate 0

(** Create an isolated worktree for the experiment. *)
let create_worktree ~(repo_path : string) ~(experiment_id : string) : string option =
  let worktree_path = Printf.sprintf "%s/.worktrees/research-%s" repo_path experiment_id in
  let branch = Printf.sprintf "research/exp-%s" experiment_id in
  try
    let _ = Process_eio.run_argv_with_status ~timeout_sec:30.0
      [ "git"; "-C"; repo_path; "worktree"; "add"; worktree_path; "-b"; branch; "HEAD" ]
    in
    Some worktree_path
  with exn ->
    log_best_effort_failure "worktree creation" exn;
    None

(** Remove experiment worktree. *)
let cleanup_worktree ~(repo_path : string) ~(worktree_path : string) : unit =
  (try
    let _ = Process_eio.run_argv_with_status ~timeout_sec:30.0
      [ "git"; "-C"; repo_path; "worktree"; "remove"; worktree_path ]
    in ()
  with exn -> log_best_effort_failure "worktree cleanup" exn)

(** Apply a patch to the target file in the worktree.
    Supports (in priority order):
    1. Search-replace: old_text + new_text fields → string substitution
    2. Unified diff: patch starts with "---" or "diff" → git apply
    3. Full file content: patch is complete file → write to target *)
let apply_patch ~(worktree_path : string) ~(hypothesis : hypothesis) : bool =
  let has_search_replace = hypothesis.old_text <> "" && hypothesis.new_text <> "" in
  if hypothesis.target_file = "" || (hypothesis.patch = "" && not has_search_replace) then false
  else begin
    let target = Printf.sprintf "%s/%s" worktree_path hypothesis.target_file in
    try
      if not (Sys.file_exists target) then false
      else if has_search_replace then begin
        (* Search-replace mode: read file, substitute old_text -> new_text *)
        let content = Fs_compat.load_file target in
        let re = Re.str hypothesis.old_text |> Re.compile in
        if String.length content > 0 && Re.execp re content
        then begin
          let replaced = Re.replace_string re ~by:hypothesis.new_text content in
          Fs_compat.save_file target replaced;
          true
        end else begin
          Log.Server.warn "research: old_text not found in %s" hypothesis.target_file;
          false
        end
      end
      else
        let patch = hypothesis.patch in
        let is_diff = String.length patch > 4 &&
          (String.sub patch 0 3 = "---" || String.sub patch 0 4 = "diff") in
        if is_diff then begin
          (* Unified diff — write to temp file, git apply *)
          let patch_file = Printf.sprintf "%s/.research_patch.diff" worktree_path in
          Fs_compat.save_file patch_file patch;
          let status, _ = Process_eio.run_argv_with_status ~timeout_sec:10.0
            [ "git"; "-C"; worktree_path; "apply"; "--check"; patch_file ] in
          let ok = match status with Unix.WEXITED 0 -> true | _ -> false in
          if ok then begin
            let _ = Process_eio.run_argv_with_status ~timeout_sec:10.0
              [ "git"; "-C"; worktree_path; "apply"; patch_file ] in
            (try Sys.remove patch_file with Sys_error _ -> ());
            true
          end else begin
            (try Sys.remove patch_file with Sys_error _ -> ());
            (* Fallback: treat as full file replacement *)
            Fs_compat.save_file target patch;
            true
          end
        end else begin
          (* Full file content replacement *)
          Fs_compat.save_file target patch;
          true
        end
    with exn ->
      log_best_effort_failure "patch application" exn;
      false
  end

(** Log a result to the TSV file. *)
let log_result ~(results_file : string) ~(entry : experiment_entry) : unit =
  let header = "experiment\tbuild_ok\ttest_pass_rate\tloc_delta\tfiles_changed\tstatus\tdescription\n" in
  let needs_header = not (Sys.file_exists results_file) ||
    (try (Unix.stat results_file).Unix.st_size = 0 with _ -> true) in
  let line = Printf.sprintf "%s\t%d\t%.4f\t%d\t%d\t%s\t%s\n"
    entry.id
    (if entry.metric.build_ok then 1 else 0)
    entry.metric.test_pass_rate
    entry.metric.loc_delta
    entry.metric.files_changed
    (Research_metric.status_to_string entry.metric.status)
    entry.hypothesis.description in
  try
    if needs_header then Fs_compat.append_file results_file header;
    Fs_compat.append_file results_file line
  with exn ->
    log_best_effort_failure "log_result" exn

(** Run a single experiment iteration. *)
let run_experiment ~sw ~net ~clock ~(config : Research_config.t)
    ~context ~history ~experiment_id : experiment_entry option =
  Log.Server.info "research: experiment %s — generating hypothesis" experiment_id;

  (* 1. Generate hypothesis *)
  match generate_hypothesis ~sw ~net ~clock ~config ~context ~history with
  | None ->
    Log.Server.warn "research: no hypothesis generated, skipping";
    None
  | Some hypothesis ->
    if is_noop_hypothesis hypothesis then begin
      Log.Server.warn "research: no-op hypothesis detected (old_text=new_text or empty), skipping";
      None
    end else begin
    Log.Server.info "research: hypothesis — %s (target: %s)"
      hypothesis.description hypothesis.target_file;

    (* 2. Create worktree *)
    (match create_worktree ~repo_path:config.repo.path ~experiment_id with
     | None ->
       Log.Server.warn "research: worktree creation failed";
       Some { id = experiment_id; hypothesis;
              metric = Research_metric.crash_result ~error_message:"worktree failed" }
     | Some worktree_path ->
       (* 3. Apply patch *)
       let applied = apply_patch ~worktree_path ~hypothesis in
       let entry =
         if not applied then begin
           Log.Server.warn "research: patch application failed";
           { id = experiment_id; hypothesis;
             metric = Research_metric.crash_result ~error_message:"patch failed" }
         end else begin
           (* 4. Measure *)
           Log.Server.info "research: measuring (build + test)...";
           let repo_config = { config.repo with path = worktree_path } in
           let metric = Research_metric.collect ~config:repo_config in
           Log.Server.info "research: build=%b test=%.1f%% loc=%+d status=%s"
             metric.build_ok (metric.test_pass_rate *. 100.0)
             metric.loc_delta (Research_metric.status_to_string metric.status);
           { id = experiment_id; hypothesis; metric }
         end
       in
       (* 5. Auto-PR for kept experiments *)
       (if entry.metric.status = Research_metric.Keep then begin
         Log.Server.info "research: creating PR for kept experiment %s" experiment_id;
         let branch = Printf.sprintf "research/exp-%s" experiment_id in
         (* Commit in the worktree *)
         (try
           let _ = Process_eio.run_argv_with_status ~timeout_sec:10.0
             [ "git"; "-C"; worktree_path; "add"; "-A" ] in
           let msg = Printf.sprintf "research(%s): %s" experiment_id
             entry.hypothesis.description in
           let _ = Process_eio.run_argv_with_status ~timeout_sec:10.0
             [ "git"; "-C"; worktree_path; "commit"; "-m"; msg ] in
           (* Push branch *)
           let _ = Process_eio.run_argv_with_status ~timeout_sec:30.0
             [ "git"; "-C"; worktree_path; "push"; "-u"; "origin"; branch ] in
           (* Create draft PR via gh *)
           let pr_body = Printf.sprintf
             "Automated code improvement via research loop.\n\n\
              - **Experiment**: %s\n\
              - **Description**: %s\n\
              - **Rationale**: %s\n\
              - **Test pass rate**: %.0f%%\n\
              - **LOC delta**: %+d\n\n\
              Generated by `masc_research_start`."
             experiment_id entry.hypothesis.description
             entry.hypothesis.rationale
             (entry.metric.test_pass_rate *. 100.0)
             entry.metric.loc_delta
           in
           let _ = Process_eio.run_argv_with_status ~timeout_sec:30.0
             [ "gh"; "pr"; "create"; "--draft";
               "--title"; Printf.sprintf "research: %s" entry.hypothesis.description;
               "--body"; pr_body;
               "--head"; branch;
               "--repo"; "jeong-sik/masc-mcp" ] in
           Log.Server.info "research: PR created for %s" experiment_id
         with exn ->
           Log.Server.warn "research: auto-PR failed: %s" (Printexc.to_string exn))
       end);
       (* 6. Cleanup worktree (branch stays for PR) *)
       cleanup_worktree ~repo_path:config.repo.path ~worktree_path;
       (* 7. Log *)
       log_result ~results_file:config.results_file ~entry;
       Some entry)
    end

(** Run the full research loop for N iterations. *)
let run ~sw ~net ~clock ~(config : Research_config.t) : experiment_entry list =
  Log.Server.info "research: starting loop (target=%s, max_iter=%d)"
    config.repo.path config.max_iterations;

  let context = gather_context ~config:config.repo in
  let history = ref [] in

  for i = 0 to config.max_iterations - 1 do
    let experiment_id = Printf.sprintf "%d-%03d" (int_of_float (Unix.gettimeofday ())) i in
    match run_experiment ~sw ~net ~clock ~config ~context ~history:!history ~experiment_id with
    | None -> ()
    | Some entry ->
      history := !history @ [ entry ];
      (* Broadcast to MASC room *)
      (try
        let msg = Printf.sprintf "[research] exp %s: %s → %s (test=%.0f%%)"
          entry.id entry.hypothesis.description
          (Research_metric.status_to_string entry.metric.status)
          (entry.metric.test_pass_rate *. 100.0) in
        Log.Server.info "%s" msg
      with exn -> log_best_effort_failure "research status broadcast" exn)
  done;

  let kept = List.filter (fun e -> e.metric.status = Research_metric.Keep) !history in
  Log.Server.info "research: complete. %d experiments, %d kept."
    (List.length !history) (List.length kept);
  !history
