(** Research_loop — Automated code improvement via local LLM.

    Core loop:
    1. Gather repo context (recent commits, TODOs, file list)
    2. Ask LLM to propose a hypothesis (via llama-server HTTP)
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
}

type experiment_entry = {
  id : string;
  hypothesis : hypothesis;
  metric : Research_metric.t;
}

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
  with _ -> ());
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
  with _ -> ());
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
  with _ -> ());
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
          with _ -> ())
        | _ -> ()
      end
    ) (if count > 3 then List.filteri (fun i _ -> i < 3) todos else todos)
  with _ -> ());
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
    Some {
      description = json |> member "description" |> to_string;
      target_file = json |> member "target_file" |> to_string;
      rationale = json |> member "rationale" |> to_string;
      patch = json |> member "patch" |> to_string;
    }
  with _ -> None

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

(** Call LLM via direct HTTP to llama-server (OpenAI-compatible). *)
let generate_hypothesis ~(config : Research_config.t)
    ~context ~history : hypothesis option =
  let history_text = history_context history in
  let user_msg = Printf.sprintf
    "Here is the repository context:\n\n%s%s\n\n\
     Propose a code improvement experiment. Focus on code that has TODOs, FIXMEs, \
     or obvious simplification opportunities. Respond with a JSON object."
    context history_text
  in
  let payload = `Assoc [
    ("model", `String config.cascade_name);
    ("messages", `List [
      `Assoc [("role", `String "system"); ("content", `String config.system_prompt)];
      `Assoc [("role", `String "user"); ("content", `String user_msg)];
    ]);
    ("temperature", `Float 0.7);
    ("max_tokens", `Int 4096);
  ] in
  let body = Yojson.Safe.to_string payload in
  let url = config.llm_url in
  let timeout_str = Printf.sprintf "%.0f" config.llm_timeout_sec in
  Log.Server.info "research: calling LLM at %s (timeout=%ss)" url timeout_str;
  try
    let auth_headers =
      if config.llm_api_key <> "" then
        [ "-H"; Printf.sprintf "Authorization: Bearer %s" config.llm_api_key ]
      else []
    in
    let argv =
      [ "curl"; "-s"; "-X"; "POST"; url;
        "-H"; "Content-Type: application/json" ]
      @ auth_headers
      @ [ "-d"; body; "--max-time"; timeout_str ]
    in
    let status, stdout =
      Process_eio.run_argv_with_status ~timeout_sec:(config.llm_timeout_sec +. 10.0) argv
    in
    let exit_code = match status with Unix.WEXITED c -> c | _ -> 1 in
    if String.length (String.trim stdout) = 0 then begin
      Log.Server.warn "research: LLM returned empty response (exit=%d, slots likely busy)" exit_code;
      None
    end else begin
      let json = Yojson.Safe.from_string stdout in
      let open Yojson.Safe.Util in
      (* Check for API error response *)
      match member "error" json with
      | `Null ->
        let content = json |> member "choices" |> index 0
          |> member "message" |> member "content" |> to_string in
        parse_hypothesis content
      | err ->
        Log.Server.warn "research: LLM API error: %s" (Yojson.Safe.to_string err);
        None
    end
  with exn ->
    Log.Server.warn "research: LLM call failed: %s" (Printexc.to_string exn);
    None

(** Create an isolated worktree for the experiment. *)
let create_worktree ~(repo_path : string) ~(experiment_id : string) : string option =
  let worktree_path = Printf.sprintf "%s/.worktrees/research-%s" repo_path experiment_id in
  let branch = Printf.sprintf "research/exp-%s" experiment_id in
  try
    let _ = Process_eio.run_argv_with_status ~timeout_sec:30.0
      [ "git"; "-C"; repo_path; "worktree"; "add"; worktree_path; "-b"; branch; "HEAD" ]
    in
    Some worktree_path
  with _ -> None

(** Remove experiment worktree. *)
let cleanup_worktree ~(repo_path : string) ~(worktree_path : string) : unit =
  (try
    let _ = Process_eio.run_argv_with_status ~timeout_sec:30.0
      [ "git"; "-C"; repo_path; "worktree"; "remove"; worktree_path ]
    in ()
  with _ -> ())

(** Apply a patch to the target file in the worktree.
    Supports:
    - Unified diff (starts with "---" or "diff") → git apply
    - Full file content (default) → write to target *)
let apply_patch ~(worktree_path : string) ~(hypothesis : hypothesis) : bool =
  if hypothesis.target_file = "" || hypothesis.patch = "" then false
  else begin
    let target = Printf.sprintf "%s/%s" worktree_path hypothesis.target_file in
    try
      if not (Sys.file_exists target) then false
      else
        let patch = hypothesis.patch in
        let is_diff = String.length patch > 4 &&
          (String.sub patch 0 3 = "---" || String.sub patch 0 4 = "diff") in
        if is_diff then begin
          (* Unified diff — write to temp file, git apply *)
          let patch_file = Printf.sprintf "%s/.research_patch.diff" worktree_path in
          let oc = open_out patch_file in
          output_string oc patch; close_out oc;
          let status, _ = Process_eio.run_argv_with_status ~timeout_sec:10.0
            [ "git"; "-C"; worktree_path; "apply"; "--check"; patch_file ] in
          let ok = match status with Unix.WEXITED 0 -> true | _ -> false in
          if ok then begin
            let _ = Process_eio.run_argv_with_status ~timeout_sec:10.0
              [ "git"; "-C"; worktree_path; "apply"; patch_file ] in
            (try Sys.remove patch_file with _ -> ());
            true
          end else begin
            (try Sys.remove patch_file with _ -> ());
            (* Fallback: treat as full file replacement *)
            let oc = open_out target in
            output_string oc patch; close_out oc;
            true
          end
        end else begin
          (* Full file content replacement *)
          let oc = open_out target in
          output_string oc patch; close_out oc;
          true
        end
    with _ -> false
  end

(** Log a result to the TSV file. *)
let log_result ~(results_file : string) ~(entry : experiment_entry) : unit =
  let header = "experiment\tbuild_ok\ttest_pass_rate\tloc_delta\tfiles_changed\tstatus\tdescription\n" in
  let needs_header = not (Sys.file_exists results_file) in
  let oc = open_out_gen [ Open_append; Open_creat ] 0o644 results_file in
  (try
    if needs_header then output_string oc header;
    Printf.fprintf oc "%s\t%d\t%.4f\t%d\t%d\t%s\t%s\n"
      entry.id
      (if entry.metric.build_ok then 1 else 0)
      entry.metric.test_pass_rate
      entry.metric.loc_delta
      entry.metric.files_changed
      (Research_metric.status_to_string entry.metric.status)
      entry.hypothesis.description;
    close_out oc
  with exn -> close_out_noerr oc; raise exn)

(** Run a single experiment iteration. *)
let run_experiment ~(config : Research_config.t)
    ~context ~history ~experiment_id : experiment_entry option =
  Log.Server.info "research: experiment %s — generating hypothesis" experiment_id;

  (* 1. Generate hypothesis *)
  match generate_hypothesis ~config ~context ~history with
  | None ->
    Log.Server.warn "research: no hypothesis generated, skipping";
    None
  | Some hypothesis ->
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

(** Run the full research loop for N iterations. *)
let run ~(config : Research_config.t) : experiment_entry list =
  Log.Server.info "research: starting loop (target=%s, max_iter=%d)"
    config.repo.path config.max_iterations;

  let context = gather_context ~config:config.repo in
  let history = ref [] in

  for i = 0 to config.max_iterations - 1 do
    let experiment_id = Printf.sprintf "%d-%03d" (int_of_float (Unix.gettimeofday ())) i in
    match run_experiment ~config ~context ~history:!history ~experiment_id with
    | None -> ()
    | Some entry ->
      history := !history @ [ entry ];
      (* Broadcast to MASC room *)
      (try
        let msg = Printf.sprintf "[research] exp %s: %s → %s (test=%.0f%%)"
          entry.id entry.hypothesis.description
          (Research_metric.status_to_string entry.metric.status)
          (entry.metric.test_pass_rate *. 100.0) in
        ignore msg  (* TODO: integrate with Room.broadcast when wired up *)
      with _ -> ())
  done;

  let kept = List.filter (fun e -> e.metric.status = Research_metric.Keep) !history in
  Log.Server.info "research: complete. %d experiments, %d kept."
    (List.length !history) (List.length kept);
  !history
