(** Tool_autoresearch — MCP tool dispatch for the Autoresearch loop.

    Inspired by Karpathy's autoresearch pattern: autonomous experiment cycles
    that generate hypotheses, measure metrics, and keep/discard changes via git.

    Schemas are defined in {!Tool_autoresearch_schemas}.

    @since 2.80.0 *)

open Tool_args

(* ================================================================ *)
(* Tool Schemas (re-exported from Tool_autoresearch_schemas)        *)
(* ================================================================ *)

let schemas = Tool_autoresearch_schemas.schemas

(* ================================================================ *)
(* Types                                                            *)
(* ================================================================ *)

type result = bool * string

type operation_launcher =
  goal:string -> target_file:string -> (Yojson.Safe.t, string) Stdlib.result

type team_session_launcher =
  goal:string ->
  operation_id:string option ->
  loop_id:string ->
  target_file:string ->
  program_note:string option ->
  (Yojson.Safe.t, string) Stdlib.result

type context = {
  base_path : string;
  agent_name : string option;
  start_operation : operation_launcher option;
  start_team_session : team_session_launcher option;
}

(* ================================================================ *)
(* Loop Registry                                                    *)
(* ================================================================ *)

let active_loops = Autoresearch.active_loops
let latest_loop_id = Autoresearch.latest_loop_id

(** Pending hypothesis injections. *)
let pending_hypotheses : (string, string) Hashtbl.t =
  Hashtbl.create 4

(** Eio.Mutex protecting [pending_hypotheses] and [custom_generators]
    against concurrent fiber access from parallel tool handlers. *)
let hypotheses_mu = Eio.Mutex.create ()

(** Execute [f] under exclusive lock on the hypotheses/generators registry. *)
let with_hypotheses_rw f = Eio.Mutex.use_rw ~protect:true hypotheses_mu (fun () -> f ())

(** Execute [f] under shared read lock on the hypotheses/generators registry. *)
let with_hypotheses_ro f = Eio.Mutex.use_ro hypotheses_mu (fun () -> f ())

(** Code generator type for test injection.
    Returns Ok (hypothesis, new_code) or Error reason. *)
type code_generator =
  goal:string -> baseline:float ->
  history:Autoresearch.cycle_record list ->
  insights:string list ->
  target_file:string -> file_content:string ->
  (string * string, string) Stdlib.result

(** Per-loop code generator override (for tests). *)
let custom_generators : (string, code_generator) Hashtbl.t =
  Hashtbl.create 4

(** Set a custom code generator for a loop (used in tests). *)
let set_generator loop_id gen =
  with_hypotheses_rw (fun () ->
    Hashtbl.replace custom_generators loop_id gen)

(** Get the code generator for a loop. Falls back to Autoresearch.generate_code_change. *)
let get_generator loop_id =
  with_hypotheses_ro (fun () ->
    match Hashtbl.find_opt custom_generators loop_id with
    | Some gen -> gen
    | None -> Autoresearch.generate_code_change)

(* ================================================================ *)
(* SSE Broadcast                                                    *)
(* ================================================================ *)

let broadcast_cycle_result (state : Autoresearch.loop_state) (record : Autoresearch.cycle_record) =
  try Sse.broadcast_to Coordinators (`Assoc [
    ("type", `String "autoresearch_cycle");
    ("loop_id", `String state.loop_id);
    ("cycle", `Int record.cycle);
    ("hypothesis", `String record.hypothesis);
    ("decision", `String (Autoresearch.decision_to_string record.decision));
    ("score_before", `Float record.score_before);
    ("score_after", `Float record.score_after);
    ("delta", `Float record.delta);
    ("baseline", `Float state.baseline);
    ("best_score", `Float state.best_score);
  ]) with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    Log.Autoresearch.warn "broadcast_cycle_result failed: %s" (Printexc.to_string exn)

(* ================================================================ *)
(* Handlers                                                         *)
(* ================================================================ *)

type start_params = {
  goal : string;
  metric_fn : string;
  target_file : string;
  source_workdir : string;
  max_cycles : int;
  cycle_timeout_s : float;
  model_model : string;
  baseline_override : float option;
}

let normalize_string_opt = function
  | Some value ->
      let trimmed = String.trim value in
      if trimmed = "" then None else Some trimmed
  | None -> None

let persisted_summary_json (summary : Autoresearch.persisted_summary) =
  `Assoc
    [
      ("loop_id", `String summary.loop_id);
      ("goal", `String summary.goal);
      ("metric_fn", `String summary.metric_fn);
      ("model_model", `String summary.model_model);
      ("target_file", `String summary.target_file);
      ("status", `String (Autoresearch.status_to_string summary.status));
      ("current_cycle", `Int summary.current_cycle);
      ("baseline", `Float summary.baseline);
      ("best_score", `Float summary.best_score);
      ("best_cycle", `Int summary.best_cycle);
      ( "queued_hypothesis",
        match summary.queued_hypothesis with Some value -> `String value | None -> `Null );
      ("total_keeps", `Int summary.total_keeps);
      ("total_discards", `Int summary.total_discards);
      ("max_cycles", `Int summary.max_cycles);
      ("cycle_timeout_s", `Float summary.cycle_timeout_s);
      ("workdir", `String summary.workdir);
      ("source_workdir", `String summary.source_workdir);
      ("elapsed_s", `Float summary.elapsed_s);
      ("recent_cycles", `List []);
      ( "program_note",
        match summary.program_note with Some value -> `String value | None -> `Null );
      ("warnings", `List (List.map (fun value -> `String value) summary.warnings));
      ("error", match summary.error_message with Some e -> `String e | None -> `Null);
    ]

let resolve_loop_id args =
  match get_string_opt args "loop_id" with
  | Some id -> Some id
  | None -> Autoresearch.with_loops_ro (fun () -> !latest_loop_id)

let prepare_start_params ctx args =
  let goal = get_string args "goal" "" in
  let metric_fn = get_string args "metric_fn" "" in
  let target_file = get_string args "target_file" "" in
  let source_workdir = get_string args "workdir" ctx.base_path in
  let max_cycles = get_int args "max_cycles" 100 in
  let cycle_timeout_s = get_float args "cycle_timeout_s" 300.0 in
  let model_model = get_string args "model_model" "glm" in
  if goal = "" then
    Error "goal is required"
  else if metric_fn = "" then
    Error "metric_fn is required"
  else if target_file = "" then
    Error "target_file is required"
  else
    (* Validate metric_fn early to reject shell injection before any state is created *)
    match Autoresearch_metric.validate_metric_fn metric_fn with
    | Error e -> Error e
    | Ok metric_fn ->
    Ok
      {
        goal;
        metric_fn;
        target_file;
        source_workdir;
        max_cycles;
        cycle_timeout_s;
        model_model;
        baseline_override = get_float_opt args "baseline";
      }

let register_loop ctx state =
  Autoresearch.save_state ~base_path:ctx.base_path state;
  Autoresearch.with_loops_rw (fun () ->
    Hashtbl.replace active_loops state.loop_id state;
    latest_loop_id := Some state.loop_id);
  state

let setup_running_loop ctx (params : start_params) =
  let state =
    Autoresearch.create_state ~goal:params.goal ~metric_fn:params.metric_fn
      ~model_model:params.model_model ~target_file:params.target_file
      ~cycle_timeout_s:params.cycle_timeout_s ~max_cycles:params.max_cycles
      ~workdir:params.source_workdir ()
  in
  match
    Autoresearch.prepare_managed_worktree ~base_path:ctx.base_path
      ~source_workdir:params.source_workdir ~loop_id:state.loop_id
  with
  | Error message -> Error message
  | Ok (managed_workdir, source_workdir, warnings) -> (
      state.workdir <- managed_workdir;
      state.warnings <- warnings;
      let baseline_result =
        match Autoresearch.validate_target_file ~workdir:managed_workdir params.target_file with
        | Error e ->
            Error (Printf.sprintf "Invalid target_file: %s" e)
        | Ok _ -> (
            match params.baseline_override with
            | Some baseline -> Ok baseline
            | None -> (
                match
                  Autoresearch.measure_metric ~workdir:managed_workdir
                    ~timeout_s:params.cycle_timeout_s params.metric_fn
                with
                | Ok (baseline, _ms) -> Ok baseline
                | Error e ->
                    Error
                      (Printf.sprintf "Failed to measure baseline: %s" e)))
      in
      match baseline_result with
      | Error message -> Error message
      | Ok baseline ->
          state.baseline <- baseline;
          state.best_score <- baseline;
          let state =
            { state with source_workdir }
          in
          Ok (register_loop ctx state))

let status_json ctx ~loop_id json_fields =
  let strip_keys keys fields =
    List.filter (fun (key, _value) -> not (List.mem key keys)) fields
  in
  let base_fields =
    match json_fields with
    | `Assoc fields ->
        strip_keys [ "session_id"; "operation_id"; "program_note"; "queued_hypothesis" ] fields
    | _ -> [ ("error", `String "invalid status payload") ]
  in
  let link =
    Autoresearch.load_swarm_link_by_loop ~base_path:ctx.base_path loop_id
  in
  let queued_hypothesis = with_hypotheses_ro (fun () ->
    Hashtbl.find_opt pending_hypotheses loop_id) in
  let link_fields =
    match link with
    | Some link ->
        [
          ("session_id", `String link.session_id);
          ( "operation_id",
            match link.operation_id with Some value -> `String value | None -> `Null );
        ]
    | None ->
        [ ("session_id", `Null); ("operation_id", `Null) ]
  in
  `Assoc
    (base_fields
    @ link_fields
    @ [
        ( "queued_hypothesis",
          match queued_hypothesis with Some value -> `String value | None -> `Null );
      ])

let build_swarm_goal ~goal ~target_file ~program_note =
  match program_note with
  | Some note ->
      Printf.sprintf
        "Autoresearch swarm goal: %s\nTarget file: %s\nProgram note:\n%s"
        goal target_file note
  | None ->
      Printf.sprintf "Autoresearch swarm goal: %s\nTarget file: %s" goal
        target_file

let parse_operation_id json =
  match Yojson.Safe.Util.member "operation_id" json with
  | `String value when String.trim value <> "" -> Some (String.trim value)
  | _ -> None

let parse_session_launch ctx json =
  let open Yojson.Safe.Util in
  let session_id = json |> member "session_id" |> to_string_option in
  match normalize_string_opt session_id with
  | None -> Error "team session launcher returned no session_id"
  | Some session_id ->
      let artifacts_dir =
        json |> member "artifacts_dir" |> to_string_option
        |> normalize_string_opt
        |> Option.value
             ~default:
               (Filename.concat ctx.base_path
                  (Filename.concat ".masc/team-sessions" session_id))
      in
      Ok (session_id, artifacts_dir)

let handle_start ctx args =
  match prepare_start_params ctx args with
  | Error message -> `Assoc [ ("error", `String message) ]
  | Ok params -> (
      match setup_running_loop ctx params with
      | Error message -> `Assoc [ ("error", `String message) ]
      | Ok state ->
      `Assoc [
        ("loop_id", `String state.loop_id);
        ("status", `String "running");
        ("goal", `String params.goal);
        ("metric_fn", `String params.metric_fn);
        ("target_file", `String params.target_file);
        ("model_model", `String params.model_model);
        ("baseline", `Float state.baseline);
        ("max_cycles", `Int params.max_cycles);
        ("cycle_timeout_s", `Float params.cycle_timeout_s);
        ("workdir", `String state.workdir);
        ("source_workdir", `String state.source_workdir);
        ("queued_hypothesis", `Null);
        ("warnings", `List (List.map (fun value -> `String value) state.warnings));
      ])

let handle_swarm_start ctx args =
  match ctx.start_team_session, ctx.agent_name with
  | None, _ ->
      `Assoc
        [
          ( "error",
            `String
              "masc_autoresearch_swarm_start requires local team-session runtime context" );
        ]
  | _, None ->
      `Assoc
        [
          ("error", `String "masc_autoresearch_swarm_start requires agent identity");
        ]
  | Some start_team_session, Some _agent_name -> (
      match prepare_start_params ctx args with
      | Error message -> `Assoc [ ("error", `String message) ]
      | Ok params ->
          let program_note = normalize_string_opt (get_string_opt args "program_note") in
          (match setup_running_loop ctx params with
          | Error message -> `Assoc [ ("error", `String message) ]
          | Ok state ->
          state.program_note <- program_note;
          let warnings = ref state.warnings in
          let operation_id =
            match ctx.start_operation with
            | None -> None
            | Some start_operation -> (
                match
                  start_operation ~goal:params.goal ~target_file:params.target_file
                with
                | Ok json -> parse_operation_id json
                | Error message ->
                    warnings := message :: !warnings;
                    None)
          in
          state.warnings <- List.rev !warnings;
          Autoresearch.save_state ~base_path:ctx.base_path state;
          let session_goal =
            build_swarm_goal ~goal:params.goal ~target_file:params.target_file
              ~program_note
          in
          match
            start_team_session ~goal:session_goal ~operation_id
              ~loop_id:state.loop_id ~target_file:params.target_file ~program_note
          with
          | Error message ->
              state.status <- Autoresearch.Error;
              state.error_message <- Some message;
              Autoresearch.save_state ~base_path:ctx.base_path state;
              `Assoc
                [
                  ("error", `String message);
                  ("loop_id", `String state.loop_id);
                ]
          | Ok session_json -> (
              match parse_session_launch ctx session_json with
              | Error message ->
                  state.status <- Autoresearch.Error;
                  state.error_message <- Some message;
                  Autoresearch.save_state ~base_path:ctx.base_path state;
                  `Assoc
                    [
                      ("error", `String message);
                      ("loop_id", `String state.loop_id);
                    ]
              | Ok (session_id, artifacts_dir) ->
                  let link : Autoresearch.swarm_link =
                    {
                      loop_id = state.loop_id;
                      session_id;
                      operation_id;
                      target_file = params.target_file;
                      program_note;
                      created_by = ctx.agent_name;
                      linked_at = Time_compat.now ();
                    }
                  in
                  Autoresearch.save_swarm_link ~base_path:ctx.base_path link;
                  `Assoc
                    [
                      ("loop_id", `String state.loop_id);
                      ("session_id", `String session_id);
                      ( "operation_id",
                        match operation_id with
                        | Some value -> `String value
                        | None -> `Null );
                      ("artifacts_dir", `String artifacts_dir);
                      ("linked_status", Autoresearch.linked_status_json ~base_path:ctx.base_path link);
                      ( "warnings",
                        `List (List.rev_map (fun message -> `String message) !warnings) );
                      ("goal", `String params.goal);
                      ( "program_note",
                        match program_note with
                        | Some value -> `String value
                        | None -> `Null );
                    ]))
          )

let handle_status ctx args =
  match resolve_loop_id args with
  | None -> `Assoc [("error", `String "No autoresearch loop running")]
  | Some id ->
    let in_memory = Autoresearch.with_loops_ro (fun () ->
      match Hashtbl.find_opt active_loops id with
      | Some state -> Some (Autoresearch.summary state)
      | None -> None)
    in
    match in_memory with
    | Some json -> status_json ctx ~loop_id:id json
    | None -> (
        match Autoresearch.load_state ~base_path:ctx.base_path id with
        | Some summary -> status_json ctx ~loop_id:id (persisted_summary_json summary)
        | None ->
            `Assoc [("error", `String (Printf.sprintf "Loop %s not found" id))])

let handle_stop ctx args =
  let reason = get_string args "reason" "manual stop" in
  match resolve_loop_id args with
  | None -> `Assoc [("error", `String "No autoresearch loop running")]
  | Some id ->
    match Autoresearch.stop_loop ~base_path:ctx.base_path ~reason id with
    | None -> `Assoc [("error", `String (Printf.sprintf "Loop %s not found" id))]
    | Some state ->
        let config = Room.default_config ctx.base_path |> Room.config_with_resolved_scope in
        (match Autoresearch.load_swarm_link_by_loop ~base_path:ctx.base_path id with
        | Some link ->
            (try
               Team_session_store.append_event config link.session_id
                 ~event_type:"linked_autoresearch_stopped"
                 ~detail:
                   (`Assoc
                     [
                       ("loop_id", `String id);
                       ("reason", `String reason);
                       ("status", `String (Autoresearch.status_to_string state.status));
                     ])
             with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
               Log.Autoresearch.warn "stop event append failed: %s" (Printexc.to_string exn))
        | None -> ());
        `Assoc [
          ("loop_id", `String id);
          ("status", `String "stopped");
          ("reason", `String reason);
          ("final_cycle", `Int state.current_cycle);
          ("best_score", `Float state.best_score);
          ("best_cycle", `Int state.best_cycle);
          ("total_keeps", `Int state.total_keeps);
          ("total_discards", `Int state.total_discards);
        ]

let handle_inject _ctx args =
  let hypothesis = get_string args "hypothesis" "" in
  if hypothesis = "" then
    `Assoc [("error", `String "hypothesis is required")]
  else
    match resolve_loop_id args with
    | None -> `Assoc [("error", `String "No autoresearch loop running")]
    | Some id ->
      Autoresearch.with_loops_rw (fun () ->
        match Hashtbl.find_opt active_loops id with
        | None -> `Assoc [("error", `String (Printf.sprintf "Loop %s not found" id))]
        | Some state ->
          if state.status <> Autoresearch.Running then
            `Assoc [("error", `String "Loop is not running")]
          else begin
            state.queued_hypothesis <- Some hypothesis;
            Autoresearch.save_state ~base_path:_ctx.base_path state;
            with_hypotheses_rw (fun () ->
              Hashtbl.replace pending_hypotheses id hypothesis);
            `Assoc [
              ("loop_id", `String id);
              ("status", `String "hypothesis_queued");
              ("hypothesis", `String hypothesis);
              ("will_test_at_cycle", `Int (state.current_cycle + 1));
            ]
          end)

(** Run one experiment cycle: the real Karpathy loop turn.
    Steps: read file -> generate code change -> fresh metric before ->
    apply change -> git commit -> metric after -> keep/discard -> persist.

    Acquires [loops_mu] for short critical sections around Hashtbl access.
    Long-running operations (metric measurement, code generation, git) run
    outside the lock. *)
let handle_cycle ctx args =
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


(* ================================================================ *)
(* Dispatch                                                         *)
(* ================================================================ *)

(** Wrap a Yojson.Safe.t result into (success, json_string).
    Returns (false, ...) if the JSON contains an "error" key. *)
let wrap_result json =
  let s = Yojson.Safe.to_string json in
  let is_error = match json with
    | `Assoc fields -> List.mem_assoc "error" fields
    | _ -> false
  in
  (not is_error, s)

(** Handle record_finding — persist a structured research finding. *)
let handle_record_finding ctx args =
  let keeper_name = match ctx.agent_name with Some n -> n | None -> "unknown" in
  let goal = Safe_ops.json_string ~default:"" "goal" args in
  let hypothesis = Safe_ops.json_string ~default:"" "hypothesis" args in
  let evidence = Safe_ops.json_string ~default:"" "evidence" args in
  let conclusion = Safe_ops.json_string ~default:"" "conclusion" args in
  if goal = "" || hypothesis = "" || evidence = "" || conclusion = "" then
    `Assoc [("error", `String "goal, hypothesis, evidence, conclusion are required")]
  else
    let loop_id = Safe_ops.json_string ~default:"" "loop_id" args in
    let confidence = Safe_ops.json_string ~default:"medium" "confidence" args in
    let tags = match Yojson.Safe.Util.member "tags" args with
      | `List items -> List.filter_map Yojson.Safe.Util.to_string_option items
      | _ -> []
    in
    let cycle_start = Safe_ops.json_int_opt "cycle_start" args in
    let cycle_end = Safe_ops.json_int_opt "cycle_end" args in
    let cycle_range = match cycle_start, cycle_end with
      | Some a, Some b -> Some (a, b)
      | Some a, None -> Some (a, a)  (* single cycle *)
      | None, Some b -> Some (b, b)
      | None, None -> None
    in
    let finding : Autoresearch_knowledge.finding = {
      id = Autoresearch_knowledge.generate_finding_id ();
      loop_id;
      keeper_name;
      goal;
      hypothesis;
      evidence;
      conclusion;
      confidence = Autoresearch_knowledge.confidence_of_string confidence;
      tags;
      related_findings = [];
      cycle_range;
      timestamp = Unix.gettimeofday ();
    } in
    Autoresearch_knowledge.record_finding ~finding

(** Handle search_findings — search previous research findings by keyword. *)
let handle_search_findings _ctx args =
  let query = Safe_ops.json_string ~default:"" "query" args in
  if query = "" then
    `Assoc [("error", `String "query is required")]
  else
    let limit = Safe_ops.json_int ~default:10 "limit" args in
    let findings = Autoresearch_knowledge.search_findings ~query ~limit () in
    `Assoc [
      ("ok", `Bool true);
      ("count", `Int (List.length findings));
      ("findings", `List (List.map Autoresearch_knowledge.finding_to_yojson findings));
    ]

(** Dispatch an autoresearch tool call (standard MCP pattern). *)
let dispatch ctx ~name ~args : result option =
  match name with
  | "masc_autoresearch_start" -> Some (wrap_result (handle_start ctx args))
  | "masc_autoresearch_swarm_start" ->
      Some (wrap_result (handle_swarm_start ctx args))
  | "masc_autoresearch_status" -> Some (wrap_result (handle_status ctx args))
  | "masc_autoresearch_stop" -> Some (wrap_result (handle_stop ctx args))
  | "masc_autoresearch_inject" -> Some (wrap_result (handle_inject ctx args))
  | "masc_autoresearch_cycle" -> Some (wrap_result (handle_cycle ctx args))
  | "masc_autoresearch_record_finding" ->
      Some (wrap_result (handle_record_finding ctx args))
  | "masc_autoresearch_search_findings" ->
      Some (wrap_result (handle_search_findings ctx args))
  | _ -> None
