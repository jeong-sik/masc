module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Tool_autoresearch_cycle — core handle_cycle ratchet logic for autoresearch. *)

open Tool_args
open Tool_autoresearch_registry
open Tool_autoresearch_broadcast

let clip text max_len =
  String_util.utf8_safe ~max_bytes:(max_len + 3) ~suffix:"..." text |> String_util.to_string

let resolve_loop_id args =
  match get_string_opt args "loop_id" with
  | Some id -> Some id
  | None -> Autoresearch.with_loops_ro (fun () -> !latest_loop_id)

let lesson_pattern (state : Autoresearch.loop_state) =
  Printf.sprintf "autoresearch %s %s" state.target_file state.goal

(* Cache Memory.t per loop_id so that lessons recorded in one cycle are
   visible to subsequent cycles within the same loop.  Without this,
   each call to [Memory_oas_bridge.create_memory] returns a fresh
   in-memory Context and procedural data written by [persist_failure_feedback]
   is invisible to [build_goal_with_feedback].  #6831 *)
let loop_memory_cache : (string, Agent_sdk.Memory.t) Hashtbl.t =
  Hashtbl.create 8

let make_loop_memory (ctx : Tool_autoresearch_context.t)
    (state : Autoresearch.loop_state) =
  match Hashtbl.find_opt loop_memory_cache state.loop_id with
  | Some mem -> mem
  | None ->
    let mem =
      Memory_oas_bridge.create_memory
        ~agent_name:Autoresearch_lineage.lesson_reviewer_actor_name
        ~base_dir:(Common.masc_dir_from_base_path ~base_path:ctx.base_path)
        ~session_id:("autoresearch-" ^ state.loop_id)
        ()
    in
    Hashtbl.replace loop_memory_cache state.loop_id mem;
    mem

let flush_loop_memory memory =
  ignore
    (Memory_oas_bridge.flush_incremental
       ~memory
       ~agent_name:Autoresearch_lineage.lesson_reviewer_actor_name)

let render_recent_findings findings =
  match findings with
  | [] -> None
  | _ ->
    let lines =
      findings
      |> List.mapi (fun idx (finding : Autoresearch_knowledge.finding) ->
           Printf.sprintf "%d. %s => %s"
             (idx + 1)
             (clip finding.hypothesis 120)
             (clip finding.conclusion 180))
    in
    Some ("Recent autoresearch findings:\n" ^ String.concat "\n" lines)

let build_goal_with_feedback
    (ctx : Tool_autoresearch_context.t)
    (state : Autoresearch.loop_state) =
  let pattern = lesson_pattern state in
  let memory = make_loop_memory ctx state in
  let lesson_text =
    Memory_oas_bridge.render_lesson_prompt_context
      ~memory ~pattern ~limit:3
  in
  let finding_text =
    Autoresearch_knowledge.search_findings ~base_path:ctx.base_path
      ~query:pattern ~limit:3 ()
    |> render_recent_findings
  in
  [
    Some state.goal;
    lesson_text;
    finding_text;
  ]
  |> List.filter_map (fun section -> section)
  |> String.concat "\n\n"

let persist_failure_feedback
    (ctx : Tool_autoresearch_context.t)
    (state : Autoresearch.loop_state)
    ~hypothesis ~summary ?action ?stdout ?stderr ?diff_summary ?trace_summary
    ?metric_error ?(tags = []) ?conclusion () =
  let memory = make_loop_memory ctx state in
  let evidence =
    [ Some summary;
      diff_summary;
      metric_error;
      Option.map (fun text -> "stderr: " ^ clip text 240) stderr;
      Option.map (fun text -> "stdout: " ^ clip text 240) stdout; ]
    |> List.filter_map (fun value -> value)
    |> String.concat " | "
  in
  let metadata =
    [
      ("loop_id", `String state.loop_id);
      ("target_file", `String state.target_file);
      ("cycle", `Int state.current_cycle);
      ("goal", `String state.goal);
    ]
  in
  Memory_oas_bridge.record_failure_lesson
    ~memory
    ~pattern:(lesson_pattern state)
    ~summary
    ?action ?stdout ?stderr ?diff_summary ?trace_summary
    ?metric_name:
      (Option.map
         (fun _ -> Autoresearch_metric.default_metric_name)
         metric_error)
    ?metric_error
    ~participants:Autoresearch_lineage.cycle_failure_participants
    ~metadata
    ();
  flush_loop_memory memory;
  let finding : Autoresearch_knowledge.finding =
    {
      id = Autoresearch_knowledge.generate_finding_id ();
      loop_id = state.loop_id;
      keeper_name = Autoresearch_lineage.lesson_reviewer_actor_name;
      goal = state.goal;
      hypothesis;
      evidence = if String.equal evidence "" then summary else evidence;
      conclusion =
        Option.value ~default:(clip summary 240) conclusion;
      confidence = Autoresearch_knowledge.Medium;
      tags =
        Autoresearch_lineage.finding_tags ~target_file:state.target_file
          ~extra:tags;
      related_findings = [];
      cycle_range = Some (state.current_cycle, state.current_cycle);
      timestamp = Unix.gettimeofday ();
    }
  in
  ignore (Autoresearch_knowledge.record_finding ~base_path:ctx.base_path
            ~finding)

let check_patience_limit (state : Autoresearch.loop_state) =
  if state.consecutive_discards >= state.patience then
    let state = { state with status = Autoresearch.Completed } in
    Autoresearch.add_insight state
      (Printf.sprintf "Early stopped: %d consecutive discards without improvement"
         state.patience)
  else state

let forced_discard_record
    (state : Autoresearch.loop_state)
    ~hypothesis ~score_before ?score_after ?commit_hash
    ~elapsed_ms ~reason () =
  let score_after = Option.value ~default:score_before score_after in
  let now = Time_compat.now () in
  let record : Autoresearch.cycle_record =
    {
      cycle = state.current_cycle;
      hypothesis;
      score_before;
      score_after;
      delta = score_after -. score_before;
      decision = Autoresearch.Discard;
      commit_hash;
      elapsed_ms;
      model_used = state.model_model;
      timestamp = now;
    }
  in
  let state = { state with
    history = record :: state.history;
    total_discards = state.total_discards + 1;
    consecutive_discards = state.consecutive_discards + 1;
    updated_at = now } in
  let state =
    Autoresearch.add_insight state
      (Printf.sprintf "Cycle %d: %s discarded (%s)"
         state.current_cycle hypothesis reason)
  in
  let state = check_patience_limit state in
  (state, record)

let persist_discard_record
    (ctx : Tool_autoresearch_context.t)
    (state : Autoresearch.loop_state)
    ~loop_id ~hypothesis ~reason record =
  Autoresearch.append_cycle ~base_path:ctx.base_path state.loop_id record;
  let state = { state with current_cycle = state.current_cycle + 1 } in
  Autoresearch.with_loops_rw (fun () ->
    Hashtbl.replace Autoresearch.active_loops loop_id state);
  Autoresearch.save_state ~base_path:ctx.base_path state;
  broadcast_cycle_result state record;
  `Assoc
    [
      ("loop_id", `String loop_id);
      ("cycle", `Int record.cycle);
      ("hypothesis", `String hypothesis);
      ("decision", `String "discard");
      ("reason", `String reason);
      ("baseline", `Float state.baseline);
    ]

let git_diff_patch ~workdir =
  let argv =
    [ "git"; "-C"; workdir; "diff"; "--no-ext-diff"; "--binary"; "--relative" ]
  in
  let status, output =
    Masc_exec.Exec_gate.run_argv_with_status
      ~actor:(Masc_exec.Agent_id.of_string "tool/autoresearch_cycle")
      ~raw_source:(String.concat " " (List.map Filename.quote argv))
      ~summary:"autoresearch cycle git diff"
      ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:(Unknown "misc") ())
      argv
  in
  match status with
  | Unix.WEXITED 0 -> Ok output
  | Unix.WEXITED code ->
    Error (Printf.sprintf "git diff exited with code %d" code)
  | Unix.WSIGNALED signal
  | Unix.WSTOPPED signal ->
    Error (Printf.sprintf "git diff terminated with signal %d" signal)

let sync_target_file_to_index ~workdir ~target_file =
  let argv = [ "git"; "-C"; workdir; "add"; "--"; target_file ] in
  let status, output =
    Masc_exec.Exec_gate.run_argv_with_status
      ~actor:(Masc_exec.Agent_id.of_string "tool/autoresearch_cycle")
      ~raw_source:(String.concat " " (List.map Filename.quote argv))
      ~summary:"autoresearch cycle git add"
      ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:(Unknown "misc") ())
      argv
  in
  match status with
  | Unix.WEXITED 0 -> ()
  | _ ->
    Log.Autoresearch.warn "failed to sync %s back into git index: %s"
      target_file (clip (String.trim output) 200)

let restore_original_content ~workdir ~target_file ~original_content ~sync_index =
  match
    Autoresearch.apply_code_change
      ~workdir ~target_file ~new_content:original_content
  with
  | Ok _ when sync_index -> sync_target_file_to_index ~workdir ~target_file
  | Ok _ -> ()
  | Error err ->
    Log.Autoresearch.warn "failed to restore %s: %s" target_file err

let diff_guard_summary report =
  report.Masc_mcp_cdal_runtime.Autonomy_diff_guard.issues
  |> List.map Masc_mcp_cdal_runtime.Autonomy_diff_guard.show_issue
  |> String.concat "; "

(** Run one experiment cycle: the real Karpathy loop turn.
    Steps: read file -> generate code change -> fresh metric before ->
    apply change -> diff guard -> git commit -> metric after -> keep/discard -> persist.

    Acquires [loops_mu] for short critical sections around Hashtbl access.
    Long-running operations (metric measurement, code generation, git) run
    outside the lock. *)
let handle_cycle (ctx : Tool_autoresearch_context.t) args =
  match resolve_loop_id args with
  | None -> `Assoc [("error", `String "No autoresearch loop running")]
  | Some id ->
    let state_or_error =
      Autoresearch.with_loops_rw (fun () ->
          match Hashtbl.find_opt active_loops id with
          | None -> Error (Printf.sprintf "Loop %s not found" id)
          | Some state ->
            if not ((=) state.status Autoresearch.Running) then
              Error "Loop is not running"
            else if not (Autoresearch.should_continue state) then begin
              let reason =
                Option.value ~default:"completed" (Autoresearch.completion_reason state)
              in
              let state = Autoresearch.complete_if_finished ~base_path:ctx.base_path state in
              Hashtbl.replace active_loops id state;
              Autoresearch.save_state ~base_path:ctx.base_path state;
              Error ("completed:" ^ reason)
            end else
              Ok state)
    in
    match state_or_error with
    | Error completed when String.starts_with ~prefix:"completed:" completed ->
      let reason =
        String.sub completed 10 (String.length completed - 10)
      in
      let best_score, best_cycle =
        Autoresearch.with_loops_ro (fun () ->
            match Hashtbl.find_opt active_loops id with
            | Some s -> (s.best_score, s.best_cycle)
            | None -> (0.0, 0))
      in
      `Assoc
        [
          ("loop_id", `String id);
          ("status", `String "completed");
          ("reason", `String reason);
          ("best_score", `Float best_score);
          ("best_cycle", `Int best_cycle);
        ]
    | Error msg -> `Assoc [("error", `String msg)]
    | Ok state ->
      let workdir = state.workdir in
      let timeout_s = state.cycle_timeout_s in
      let target_file = state.target_file in
      match Autoresearch.validate_target_file ~workdir target_file with
      | Error e ->
        `Assoc
          [
            ("error", `String (Printf.sprintf "target_file invalid: %s" e));
            ("loop_id", `String id);
          ]
      | Ok abs_path ->
        let file_content = Autoresearch.read_file abs_path in
        let goal_with_feedback = build_goal_with_feedback ctx state in
        let code_result =
          let forced_hypothesis =
            Autoresearch.with_loops_rw (fun () ->
                match Hashtbl.find_opt pending_hypotheses id with
                | Some h ->
                  Hashtbl.remove pending_hypotheses id;
                  let state = { state with queued_hypothesis = None } in
                  Hashtbl.replace active_loops id state;
                  Autoresearch.save_state ~base_path:ctx.base_path state;
                  Some h
                | None -> get_string_opt args "hypothesis")
          in
          let generate = get_generator id in
          match forced_hypothesis with
          | Some h ->
            generate
              ~goal:(Printf.sprintf "%s\n\nApply this hypothesis: %s" goal_with_feedback h)
              ~baseline:state.baseline
              ~lower_is_better:state.lower_is_better
              ~history:state.history
              ~insights:state.insights
              ~target_file
              ~file_content
            |> Result.map (fun (_generated_hyp, code) -> (h, code))
          | None ->
            generate
              ~goal:goal_with_feedback
              ~baseline:state.baseline
              ~lower_is_better:state.lower_is_better
              ~history:state.history
              ~insights:state.insights
              ~target_file
              ~file_content
        in
        match code_result with
        | Error e ->
          persist_failure_feedback ctx state
            ~hypothesis:"<generation_failed>"
            ~summary:(Printf.sprintf "Code generation failed: %s" e)
            ~action:"Use prior lessons, keep the patch small, and regenerate only the target file."
            ~stderr:e
            ~tags:["codegen-failure"]
            ();
          `Assoc
            [
              ("error", `String (Printf.sprintf "Code generation failed: %s" e));
              ("loop_id", `String id);
              ("cycle", `Int state.current_cycle);
            ]
        | Ok (hypothesis, new_code) ->
          let before_result =
            Autoresearch.measure_metric_with_retry ~workdir ~timeout_s state.metric_fn
          in
          match before_result with
          | Error e ->
            persist_failure_feedback ctx state
              ~hypothesis
              ~summary:(Printf.sprintf "Pre-metric failed: %s" e)
              ~action:
                ("Ensure the metric command exits 0 and emits either a final metric tag or "
               ^ "a last-line float.")
              ~metric_error:e
              ~stderr:e
              ~tags:["pre-metric-failure"]
              ();
            `Assoc
              [
                ("error", `String (Printf.sprintf "Pre-metric failed: %s" e));
                ("loop_id", `String id);
                ("cycle", `Int state.current_cycle);
              ]
          | Ok (score_before, _) ->
            match
              Autoresearch.apply_code_change ~workdir ~target_file ~new_content:new_code
            with
            | Error e ->
              `Assoc
                [
                  ( "error",
                    `String (Printf.sprintf "apply_code_change failed: %s" e) );
                  ("loop_id", `String id);
                  ("cycle", `Int state.current_cycle);
                ]
            | Ok original_content ->
              (match git_diff_patch ~workdir with
               | Error diff_err ->
                 restore_original_content
                   ~workdir ~target_file ~original_content ~sync_index:false;
                 persist_failure_feedback ctx state
                   ~hypothesis
                   ~summary:(Printf.sprintf "Unable to inspect git diff: %s" diff_err)
                   ~action:"Keep the working tree inspectable and retry the cycle."
                   ~stderr:diff_err
                   ~tags:["diff-inspection-failure"]
                   ();
                 `Assoc
                   [
                     ("error", `String (Printf.sprintf "git diff failed: %s" diff_err));
                     ("loop_id", `String id);
                     ("cycle", `Int state.current_cycle);
                   ]
               | Ok patch ->
                 let report =
                   Masc_mcp_cdal_runtime.Autonomy_diff_guard.validate_patch
                     ~allowed_paths:[ target_file ]
                     patch
                 in
                 if List.exists
                      (function
                        | Masc_mcp_cdal_runtime.Autonomy_diff_guard.Empty_patch -> true
                        | _ -> false)
                      report.issues
                 then (
                   restore_original_content
                     ~workdir ~target_file ~original_content ~sync_index:false;
                   let (state, record) =
                     forced_discard_record state
                       ~hypothesis ~score_before ~elapsed_ms:0
                       ~reason:"no diff produced"
                       ()
                   in
                   persist_discard_record ctx state
                     ~loop_id:id ~hypothesis ~reason:"no diff produced" record)
                 else if not report.accepted then (
                   let summary = diff_guard_summary report in
                   restore_original_content
                     ~workdir ~target_file ~original_content ~sync_index:false;
                   persist_failure_feedback ctx state
                     ~hypothesis
                     ~summary:(Printf.sprintf "Diff guard rejected patch: %s" summary)
                     ~action:
                       "Restrict edits to the declared target_file and avoid risky system-level additions."
                     ~diff_summary:summary
                     ~tags:["diff-guard"]
                     ();
                   let (state, record) =
                     forced_discard_record state
                       ~hypothesis ~score_before ~elapsed_ms:0
                       ~reason:("diff guard rejected patch: " ^ summary)
                       ()
                   in
                   persist_discard_record ctx state
                     ~loop_id:id ~hypothesis
                     ~reason:("diff guard rejected patch: " ^ summary)
                     record)
                 else
                   let commit_result =
                     Autoresearch.git_commit_cycle
                       ~workdir
                       ~cycle:state.current_cycle
                       ~hypothesis
                       ~baseline:score_before
                   in
                   match commit_result with
                   | Error git_err ->
                     restore_original_content
                       ~workdir ~target_file ~original_content ~sync_index:true;
                     persist_failure_feedback ctx state
                       ~hypothesis
                       ~summary:(Printf.sprintf "git commit failed: %s" git_err)
                       ~action:
                         "Keep git identity/hooks valid and retry after the target file is restored."
                       ~stderr:git_err
                       ~tags:["git-commit-failure"]
                       ();
                     `Assoc
                       [
                         ("error", `String (Printf.sprintf "git commit failed: %s" git_err));
                         ("loop_id", `String id);
                         ("cycle", `Int state.current_cycle);
                       ]
                   | Ok None ->
                     restore_original_content
                       ~workdir ~target_file ~original_content ~sync_index:false;
                     let (state, record) =
                       forced_discard_record state
                         ~hypothesis ~score_before ~elapsed_ms:0
                         ~reason:"no diff produced"
                         ()
                     in
                     persist_discard_record ctx state
                       ~loop_id:id ~hypothesis ~reason:"no diff produced" record
                   | Ok (Some commit_hash) ->
                     let after_result =
                       Autoresearch.measure_metric_with_retry
                         ~workdir ~timeout_s state.metric_fn
                     in
                     match after_result with
                     | Error e ->
                       Autoresearch.git_reset_last ~workdir;
                       persist_failure_feedback ctx state
                         ~hypothesis
                         ~summary:(Printf.sprintf "Post-metric failed: %s" e)
                         ~action:
                           ("Make the metric harness deterministic and emit "
                          ^ Autoresearch_metric.prompt_snippet ())
                         ~metric_error:e
                         ~stderr:e
                         ~tags:["post-metric-failure"]
                         ();
                       let (state, record) =
                         forced_discard_record state
                           ~hypothesis ~score_before ~commit_hash:commit_hash
                           ~elapsed_ms:0
                           ~reason:("metric_fn failed: " ^ e)
                           ()
                       in
                       persist_discard_record ctx state
                         ~loop_id:id ~hypothesis
                         ~reason:(Printf.sprintf "metric_fn failed: %s" e)
                         record
                     | Ok (score_after, elapsed_ms) ->
                       (* Snapshot before record_cycle — needed if
                          build gate later downgrades Keep to Discard *)
                       let prev_best_score = state.best_score in
                       let prev_best_cycle = state.best_cycle in
                       let (state, record) =
                         Autoresearch.record_cycle state
                           ~hypothesis ~score_before ~score_after
                           ~commit_hash:(Some commit_hash)
                           ~elapsed_ms ~model_used:state.model_model
                       in
                       let build_gate_override =
                         match record.decision with
                         | Autoresearch.Keep -> (
                           match state.build_verify_fn with
                           | None -> false
                           | Some cmd ->
                             match Autoresearch_metric.split_metric_fn_argv cmd with
                             | Error e ->
                               Log.Autoresearch.warn "build_verify_fn validation failed: %s" e;
                               true
                             | Ok argv ->
                               match Autoresearch_metric.run_metric_argv ~workdir ~timeout_s argv with
                               | Ok _ -> false
                               | Error reason ->
                                 Log.Autoresearch.info "build verification failed: %s" reason;
                                 persist_failure_feedback ctx state
                                   ~hypothesis
                                   ~summary:(Printf.sprintf "Build verification failed: %s" reason)
                                   ~action:"Fix the build before the metric can improve."
                                   ~stderr:reason
                                   ~tags:["build-verify-failure"]
                                   ();
                                 true)
                         | Autoresearch.Discard -> false
                       in
                       let (effective_decision, state) =
                         if build_gate_override then
                           let state = { state with
                             total_keeps = state.total_keeps - 1;
                             total_discards = state.total_discards + 1;
                             baseline = score_before } in
                           let state =
                             if state.best_cycle = state.current_cycle then
                               { state with best_score = prev_best_score; best_cycle = prev_best_cycle }
                             else state
                           in
                           let state =
                             Autoresearch.add_insight state
                               (Printf.sprintf "Cycle %d: %s build verification failed, downgraded to discard"
                                  state.current_cycle hypothesis)
                           in
                           (Autoresearch.Discard, state)
                         else
                           (record.decision, state)
                       in
                       let state =
                         match effective_decision with
                         | Autoresearch.Discard ->
                           Autoresearch.git_reset_last ~workdir;
                           let state = { state with
                             consecutive_discards = state.consecutive_discards + 1 } in
                           check_patience_limit state
                         | Autoresearch.Keep ->
                           let state = { state with consecutive_discards = 0 } in
                           let is_tag_worthy =
                             if state.lower_is_better then Stdlib.( <= ) score_after state.best_score
                             else Stdlib.( >= ) score_after state.best_score
                           in
                           if is_tag_worthy then
                             Autoresearch.git_tag_best ~workdir
                               ~cycle:state.current_cycle ~score:score_after;
                           state
                       in
                       let effective_record =
                         if build_gate_override then
                           { record with decision = Autoresearch.Discard }
                         else record
                       in
                       let state =
                         if build_gate_override then
                           match state.history with
                           | _ :: rest -> { state with history = effective_record :: rest }
                           | [] -> { state with history = [ effective_record ] }
                         else state
                       in
                       Autoresearch.append_cycle ~base_path:ctx.base_path state.loop_id effective_record;
                       let state =
                         Autoresearch.complete_if_finished
                           ~base_path:ctx.base_path
                           { state with current_cycle = state.current_cycle + 1 }
                       in
                       Autoresearch.with_loops_rw (fun () ->
                         Hashtbl.replace Autoresearch.active_loops id state);
                       Autoresearch.save_state ~base_path:ctx.base_path state;
                       let _config = Coord.default_config ctx.base_path in
                       (match
                          Autoresearch.load_execution_link_by_loop
                            ~base_path:ctx.base_path id
                        with
                       | Some _link ->
                         (* Team_session_store removed — skip event append *)
                         ()
                       | None -> ());
                       broadcast_cycle_result state effective_record;
                       `Assoc
                         [
                           ("loop_id", `String id);
                           ("cycle", `Int effective_record.cycle);
                           ("hypothesis", `String hypothesis);
                           ("score_before", `Float score_before);
                           ("score_after", `Float score_after);
                           ("delta", `Float effective_record.delta);
                           ( "decision",
                             `String
                               (Autoresearch.decision_to_string effective_record.decision) );
                           ("commit_hash", `String commit_hash);
                           ("status", `String (Autoresearch.status_to_string state.status));
                           ("target_reached", `Bool (Autoresearch.target_reached state));
                           ("baseline", `Float state.baseline);
                           ("best_score", `Float state.best_score);
                           ( "cycles_remaining",
                             `Int (state.max_cycles - state.current_cycle) );
                         ])
