(** Tool_autoresearch_cycle — core handle_cycle ratchet logic for autoresearch. *)

open Tool_args
open Tool_autoresearch_registry
open Tool_autoresearch_broadcast

(** Run one experiment cycle: the real Karpathy loop turn.
    Steps: read file -> generate code change -> fresh metric before ->
    apply change -> git commit -> metric after -> keep/discard -> persist.

    Acquires [loops_mu] for short critical sections around Hashtbl access.
    Long-running operations (metric measurement, code generation, git) run
    outside the lock. *)
let resolve_loop_id args =
  match get_string_opt args "loop_id" with
  | Some id -> Some id
  | None -> Autoresearch.with_loops_ro (fun () -> !latest_loop_id)

let handle_cycle (ctx : Tool_autoresearch_repo_synthesis.context) args =
  match resolve_loop_id args with
  | None -> `Assoc [("error", `String "No autoresearch loop running")]
  | Some id ->
    (* Short critical section: look up state and check preconditions *)
    let state_or_error = Autoresearch.with_loops_rw (fun () ->
      match Hashtbl.find_opt active_loops id with
      | None -> Error (Printf.sprintf "Loop %s not found" id)
      | Some state ->
        if state.status <> Autoresearch.Running then
          Error "Loop is not running"
        else if not (Autoresearch.should_continue state) then begin
          state.status <- Autoresearch.Completed;
          Autoresearch.save_state ~base_path:ctx.base_path state;
          Error "completed"
        end else
          Ok state)
    in
    (match state_or_error with
    | Error "completed" ->
        (* Reconstruct completion JSON: re-read state under lock *)
        let best_score, best_cycle = Autoresearch.with_loops_ro (fun () ->
          match Hashtbl.find_opt active_loops id with
          | Some s -> (s.best_score, s.best_cycle)
          | None -> (0.0, 0))
        in
        `Assoc [
          ("loop_id", `String id);
          ("status", `String "completed");
          ("reason", `String "max_cycles reached");
          ("best_score", `Float best_score);
          ("best_cycle", `Int best_cycle);
        ]
    | Error msg -> `Assoc [("error", `String msg)]
    | Ok state ->
      let workdir = state.workdir in
      let timeout_s = state.cycle_timeout_s in
      let target_file = state.target_file in
      (* 1. Read target file *)
      match Autoresearch.validate_target_file ~workdir target_file with
      | Error e ->
        `Assoc [
          ("error", `String (Printf.sprintf "target_file invalid: %s" e));
          ("loop_id", `String id);
        ]
      | Ok abs_path ->
      let file_content = Autoresearch.read_file abs_path in
      (* 2. Generate code change: injected hypothesis > arg > MODEL *)
      let code_result =
        let forced_hypothesis =
          Autoresearch.with_loops_rw (fun () ->
            with_hypotheses_rw (fun () ->
              match Hashtbl.find_opt pending_hypotheses id with
              | Some h ->
                  Hashtbl.remove pending_hypotheses id;
                  state.queued_hypothesis <- None;
                  Autoresearch.save_state ~base_path:ctx.base_path state;
                  Some h
              | None -> get_string_opt args "hypothesis"))
        in
          let generate = get_generator id in
          (match forced_hypothesis with
           | Some h ->
             (* Injected/explicit hypothesis: pass it to generator
                so MODEL produces actual code changes for this hypothesis *)
             generate ~goal:(Printf.sprintf "%s\n\nApply this hypothesis: %s" state.goal h)
               ~baseline:state.baseline
               ~history:state.history ~insights:state.insights
               ~target_file ~file_content
             |> Result.map (fun (_generated_hyp, code) -> (h, code))
           | None ->
             generate ~goal:state.goal ~baseline:state.baseline
               ~history:state.history ~insights:state.insights
               ~target_file ~file_content)
        in
        match code_result with
        | Error e ->
          `Assoc [
            ("error", `String (Printf.sprintf "Code generation failed: %s" e));
            ("loop_id", `String id);
            ("cycle", `Int state.current_cycle);
          ]
        | Ok (hypothesis, new_code) ->
          (* 3. Measure FRESH score_before *)
          let before_result = Autoresearch.measure_metric_with_retry
            ~workdir ~timeout_s state.metric_fn in
          match before_result with
          | Error e ->
            `Assoc [
              ("error", `String (Printf.sprintf "Pre-metric failed: %s" e));
              ("loop_id", `String id);
              ("cycle", `Int state.current_cycle);
            ]
          | Ok (score_before, _) ->
            (* 4. Apply code change to disk *)
            (match Autoresearch.apply_code_change ~workdir ~target_file ~new_content:new_code with
             | Error e ->
               `Assoc [
                 ("error", `String (Printf.sprintf "apply_code_change failed: %s" e));
                 ("loop_id", `String id);
                 ("cycle", `Int state.current_cycle);
               ]
             | Ok _original ->
               (* 5. Git commit (real changes, no --allow-empty) *)
               let commit_result = Autoresearch.git_commit_cycle
                 ~workdir ~cycle:state.current_cycle ~hypothesis ~baseline:score_before in
               (match commit_result with
               | Error git_err ->
                  (* Git commit failed (e.g. missing identity, hooks).
                     Revert file change to keep working tree clean. *)
                  Autoresearch.git_restore_head ~workdir;
                  `Assoc [
                    ("error", `String (Printf.sprintf "git commit failed: %s" git_err));
                    ("loop_id", `String id);
                    ("cycle", `Int state.current_cycle);
                  ]
                | Ok None ->
                  (* No diff: MODEL produced identical code. Discard. *)
                  let record = Autoresearch.record_cycle state
                    ~hypothesis ~score_before ~score_after:score_before
                    ~commit_hash:None ~elapsed_ms:0 ~model_used:state.model_model in
                  Autoresearch.append_cycle ~base_path:ctx.base_path state.loop_id record;
                  state.current_cycle <- state.current_cycle + 1;
                  Autoresearch.save_state ~base_path:ctx.base_path state;
                  broadcast_cycle_result state record;
                  `Assoc [
                    ("loop_id", `String id);
                    ("cycle", `Int record.cycle);
                    ("hypothesis", `String hypothesis);
                    ("decision", `String "discard");
                    ("reason", `String "no diff produced");
                    ("baseline", `Float state.baseline);
                  ]
                | Ok (Some _) ->
                  let commit_hash = (match commit_result with Ok h -> h | _ -> None) in
                  (* 6. Measure score_after *)
                  let after_result = Autoresearch.measure_metric_with_retry
                    ~workdir ~timeout_s state.metric_fn in
                  match after_result with
                  | Error e ->
                    (* Metric failed: git reset to undo *)
                    Autoresearch.git_reset_last ~workdir;
                    let record = Autoresearch.record_cycle state
                      ~hypothesis ~score_before ~score_after:score_before
                      ~commit_hash ~elapsed_ms:0 ~model_used:state.model_model in
                    Autoresearch.append_cycle ~base_path:ctx.base_path state.loop_id record;
                    state.current_cycle <- state.current_cycle + 1;
                    Autoresearch.save_state ~base_path:ctx.base_path state;
                    broadcast_cycle_result state record;
                    `Assoc [
                      ("loop_id", `String id);
                      ("cycle", `Int record.cycle);
                      ("hypothesis", `String hypothesis);
                      ("decision", `String "discard");
                      ("reason", `String (Printf.sprintf "metric_fn failed: %s" e));
                      ("baseline", `Float state.baseline);
                    ]
                  | Ok (score_after, elapsed_ms) ->
                    (* 7. Compare and decide *)
                    let record = Autoresearch.record_cycle state
                      ~hypothesis ~score_before ~score_after
                      ~commit_hash ~elapsed_ms ~model_used:state.model_model in
                    (* 8. Keep or discard *)
                    (match record.decision with
                     | Autoresearch.Discard ->
                       (* Karpathy ratchet: git reset --hard HEAD~1 reverts commit + files *)
                       Autoresearch.git_reset_last ~workdir
                     | Autoresearch.Keep ->
                       if score_after >= state.best_score then
                         Autoresearch.git_tag_best ~workdir
                           ~cycle:state.current_cycle ~score:score_after);
                    (* 9. Persist cycle record first, then update in-memory state.
                       Baseline mutation after append_cycle ensures disk has the
                       decision record even if save_state fails. *)
                    Autoresearch.append_cycle ~base_path:ctx.base_path state.loop_id record;
                    (if record.decision = Autoresearch.Keep then
                       state.baseline <- score_after);
                    state.current_cycle <- state.current_cycle + 1;
                    Autoresearch.save_state ~base_path:ctx.base_path state;
                    let config = Room.default_config ctx.base_path |> Room.config_with_resolved_scope in
                    (match Autoresearch.load_swarm_link_by_loop ~base_path:ctx.base_path id with
                    | Some link ->
                        (try
                           Team_session_store.append_event config link.session_id
                             ~event_type:"linked_autoresearch_cycle"
                             ~detail:
                               (`Assoc
                                 [
                                   ("loop_id", `String id);
                                   ("cycle", `Int record.cycle);
                                   ("hypothesis", `String hypothesis);
                                   ("decision", `String (Autoresearch.decision_to_string record.decision));
                                   ("delta", `Float record.delta);
                                   ("baseline", `Float state.baseline);
                                   ("best_score", `Float state.best_score);
                                 ])
                         with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
                           Log.Autoresearch.warn "cycle event append failed: %s" (Printexc.to_string exn))
                    | None -> ());
                    (* 10. SSE broadcast *)
                    broadcast_cycle_result state record;
                    (* 11. Return result *)
                    `Assoc [
                      ("loop_id", `String id);
                      ("cycle", `Int record.cycle);
                      ("hypothesis", `String hypothesis);
                      ("score_before", `Float score_before);
                      ("score_after", `Float score_after);
                      ("delta", `Float record.delta);
                      ("decision", `String (Autoresearch.decision_to_string record.decision));
                      ("commit_hash", match record.commit_hash with
                        | Some h -> `String h | None -> `Null);
                      ("baseline", `Float state.baseline);
                      ("best_score", `Float state.best_score);
                      ("cycles_remaining", `Int (state.max_cycles - state.current_cycle));
                    ])))
