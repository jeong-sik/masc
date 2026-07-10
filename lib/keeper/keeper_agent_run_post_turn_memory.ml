(** Keeper_agent_run_post_turn_memory.ml — Post-turn memory write series.

    Extracted from [Keeper_agent_run.run_turn] Step 8 body (RFC-0147 PR-4). *)

let post_turn_job_payload_schema = "masc.keeper_post_turn_memory_job.v2"

type stage_name =
  | Tool_result_promotion
  | Librarian_extraction
  | Skill_candidate_projection
  | Memory_bank_compaction

type stage_status =
  | Stage_succeeded
  | Stage_skipped
  | Stage_failed

type submission_outcome =
  | Durable of Keeper_memory_job_store.job
  | Not_durable

type stage_result =
  { name : stage_name
  ; status : stage_status
  ; failure_retryability : Keeper_memory_lane.retryability option
  ; detail : Yojson.Safe.t
  ; error : string option
  }

type job_payload =
  { meta : Keeper_meta_contract.keeper_meta
  ; runtime_id : string
  ; librarian_admission : Keeper_librarian_runtime.librarian_admission_decision
  ; librarian_checkpoint : Agent_sdk.Checkpoint.t
  ; tool_results : Yojson.Safe.t list option
  }

let stage_name_to_string = function
  | Tool_result_promotion -> "tool_result_promotion"
  | Librarian_extraction -> "librarian_extraction"
  | Skill_candidate_projection -> "skill_candidate_projection"
  | Memory_bank_compaction -> "memory_bank_compaction"
;;

let stage_status_to_string = function
  | Stage_succeeded -> "succeeded"
  | Stage_skipped -> "skipped"
  | Stage_failed -> "failed"
;;

let stage_to_json stage =
  `Assoc
    [ "name", `String (stage_name_to_string stage.name)
    ; "status", `String (stage_status_to_string stage.status)
    ; ( "failure_retryability"
      , match stage.failure_retryability with
        | None -> `Null
        | Some Keeper_memory_lane.Retryable -> `String "retryable"
        | Some Keeper_memory_lane.Terminal -> `String "terminal" )
    ; "detail", stage.detail
    ; "error", Json_util.string_opt_to_json stage.error
    ]
;;

let stage_succeeded name detail =
  { name
  ; status = Stage_succeeded
  ; failure_retryability = None
  ; detail
  ; error = None
  }
;;

let stage_skipped name detail =
  { name
  ; status = Stage_skipped
  ; failure_retryability = None
  ; detail
  ; error = None
  }
;;

let stage_failed ?(retryability = Keeper_memory_lane.Terminal) name ~detail error =
  { name
  ; status = Stage_failed
  ; failure_retryability = Some retryability
  ; detail
  ; error = Some error
  }
;;

let protect_stage name f =
  try f () with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    stage_failed
      name
      ~detail:`Null
      (Printexc.to_string exn)
;;

let librarian_checkpoint_for_job (checkpoint : Agent_sdk.Checkpoint.t) =
  { checkpoint with
    messages =
      Keeper_librarian_runtime.prompt_window_messages checkpoint.messages
  ; system_prompt = None
  ; tools = []
  ; tool_choice = None
  ; context = Agent_sdk.Context.create_sync ()
  ; mcp_sessions = []
  ; working_context = None
  }
;;

let payload_to_json
      ~meta
      ~runtime_id
      ~librarian_admission
      ~librarian_checkpoint
      ~tool_results
  =
  `Assoc
    [ "schema", `String post_turn_job_payload_schema
    ; "meta", Keeper_meta_json.meta_to_json meta
    ; "runtime_id", `String runtime_id
    ; ( "librarian_admission"
      , Keeper_librarian_runtime.librarian_admission_decision_to_json
          librarian_admission )
    ; "librarian_checkpoint"
      , Agent_sdk.Checkpoint.to_json
          (librarian_checkpoint_for_job librarian_checkpoint)
    ; ( "tool_results"
      , match tool_results with
        | None -> `Null
        | Some results -> `List results )
    ]
;;

let payload_string_field name fields =
  match List.assoc_opt name fields with
  | Some (`String value) -> Ok value
  | Some _ -> Error (Printf.sprintf "field %s must be a string" name)
  | None -> Error (Printf.sprintf "missing field %s" name)
;;

let payload_json_field name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "missing field %s" name)
;;

let ( let* ) = Result.bind

let payload_of_json = function
  | `Assoc fields ->
    let* schema = payload_string_field "schema" fields in
    if not (String.equal schema post_turn_job_payload_schema)
    then Error (Printf.sprintf "unsupported post-turn memory job schema: %s" schema)
    else
      let* meta_json = payload_json_field "meta" fields in
      let* meta = Keeper_meta_json_parse.meta_of_json meta_json in
      let* runtime_id = payload_string_field "runtime_id" fields in
      let* librarian_admission_json =
        payload_json_field "librarian_admission" fields
      in
      let* librarian_admission =
        Keeper_librarian_runtime.librarian_admission_decision_of_json
          librarian_admission_json
      in
      let* checkpoint_json = payload_json_field "librarian_checkpoint" fields in
      let* librarian_checkpoint =
        Agent_sdk.Checkpoint.of_json checkpoint_json
        |> Result.map_error Agent_sdk.Error.to_string
      in
      let* tool_results_json = payload_json_field "tool_results" fields in
      let* tool_results =
        match tool_results_json with
        | `Null -> Ok None
        | `List results -> Ok (Some results)
        | _ -> Error "field tool_results must be null or a list"
      in
      Ok
        { meta
        ; runtime_id
        ; librarian_admission
        ; librarian_checkpoint
        ; tool_results
        }
  | _ -> Error "post-turn memory job payload must be an object"
;;

let compaction_error_to_string = function
  | Memory.Read_error -> "memory bank read failed"
  | Memory.Write_error detail -> "memory bank write failed: " ^ detail
  | Memory.Schema_mismatch -> "memory bank schema mismatch"
;;

let run_tool_result_stage
      (config : Workspace.config)
      (meta : Keeper_meta_contract.keeper_meta)
      turn
  = function
  | None ->
    stage_skipped
      Tool_result_promotion
      (`Assoc [ "reason", `String "tool_emission_disabled" ])
  | Some tool_results ->
    (match Memory.append_from_tool_results config meta ~turn ~results:tool_results with
     | Error error ->
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string MemoryWriteFailures)
         ~labels:[ "keeper", meta.name ]
         ();
       stage_failed
         ~retryability:Keeper_memory_lane.Retryable
         Tool_result_promotion
         ~detail:`Null
         error
     | Ok notes_written ->
       if notes_written > 0
       then
         Keeper_turn_telemetry.log_keeper_memory_write
           ~keeper_name:meta.name
           ~notes_written
           ~kinds_written:[ "long_term" ];
       stage_succeeded
         Tool_result_promotion
         (`Assoc [ "notes_written", `Int notes_written ]))
;;

let run_librarian_stage
      ~base_path
      (meta : Keeper_meta_contract.keeper_meta)
      operation_id
      generation
      runtime_id
      librarian_admission
      librarian_checkpoint
  =
  let started_at = Time_compat.now () in
  let latency_ms () =
    Keeper_timing.round1 ((Time_compat.now () -. started_at) *. 1000.0)
  in
  let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  let keepers_dir =
    Common.keepers_runtime_dir_of_base ~base_path
  in
  match
    Keeper_memory_os_io.inspect_operation_episode
      ~clock:(Eio_context.get_clock_opt ())
      ~keepers_dir
      ~keeper_id:meta.name
      ~operation_id
  with
  | Error error ->
    stage_failed
      ~retryability:Keeper_memory_lane.Retryable
      Librarian_extraction
      ~detail:
         (`Assoc
           [ "operation_id", `String operation_id
           ; "runtime_id", `String runtime_id
           ; "model_id", `Null
           ; "provider_latency_ms", `Null
           ; "latency_ms", `Float (latency_ms ())
           ; "next_due_after_turns", `Int 0
           ])
      error
  | Ok (Keeper_memory_os_io.Operation_committed staged) ->
    let episode = staged.Keeper_memory_os_io.episode in
    stage_succeeded
      Librarian_extraction
      (`Assoc
         [ "status", `String "succeeded"
         ; "runtime_id", `String runtime_id
         ; "model_id", `String staged.model_id
         ; "operation_id", `String operation_id
         ; "replayed_from_commit", `Bool true
         ; "episode_generation", `Int episode.Keeper_memory_os_types.generation
         ; "claim_count", `Int (List.length episode.claims)
         ; "provider_latency_ms", `Float staged.provider_latency_ms
         ; "latency_ms", `Float (latency_ms ())
         ; "next_due_after_turns"
           , `Int (Keeper_librarian_runtime.cadence_turns ())
         ])
  | Ok (Keeper_memory_os_io.Operation_staged staged) ->
    (match
       Keeper_librarian_runtime.commit_staged_operation
         ~keepers_dir
         ?clock:(Eio_context.get_clock_opt ())
         ~keeper_id:meta.name
         ~operation_id
         staged
     with
     | Error error ->
       stage_failed
         ~retryability:Keeper_memory_lane.Retryable
         Librarian_extraction
         ~detail:
           (`Assoc
              [ "operation_id", `String operation_id
              ; "runtime_id", `String runtime_id
              ; "model_id", `String staged.model_id
              ; "provider_latency_ms", `Float staged.provider_latency_ms
              ; "latency_ms", `Float (latency_ms ())
              ; "next_due_after_turns", `Int 0
              ])
         (Keeper_librarian_runtime.extraction_error_to_string error)
     | Ok () ->
       let episode = staged.Keeper_memory_os_io.episode in
       stage_succeeded
         Librarian_extraction
         (`Assoc
            [ "status", `String "succeeded"
            ; "runtime_id", `String runtime_id
            ; "model_id", `String staged.model_id
            ; "operation_id", `String operation_id
            ; "replayed_from_stage", `Bool true
            ; "episode_generation", `Int episode.Keeper_memory_os_types.generation
            ; "claim_count", `Int (List.length episode.claims)
            ; "provider_latency_ms", `Float staged.provider_latency_ms
            ; "latency_ms", `Float (latency_ms ())
            ; "next_due_after_turns"
              , `Int (Keeper_librarian_runtime.cadence_turns ())
            ]))
  | Ok Keeper_memory_os_io.Operation_absent ->
    let input : Keeper_librarian.input =
      { trace_id
      ; generation
      ; messages = librarian_checkpoint.Agent_sdk.Checkpoint.messages
      }
    in
    let outcome =
      Keeper_librarian_runtime.run_best_effort
        ~operation_id
        ~keepers_dir
        ~admission_decision:librarian_admission
        ~runtime_id
        ~keeper_id:meta.name
        input
    in
    let detail = Keeper_librarian_runtime.run_outcome_to_json outcome in
    (match outcome with
     | Keeper_librarian_runtime.Run_skipped _ ->
       stage_skipped Librarian_extraction detail
     | Keeper_librarian_runtime.Run_succeeded _ ->
       stage_succeeded Librarian_extraction detail
     | Keeper_librarian_runtime.Run_failed { error; _ } ->
       let retryability =
         match error with
         | Keeper_librarian_runtime.Eio_context_unavailable
         | Keeper_librarian_runtime.Runtime_resolution_failed _ ->
           Keeper_memory_lane.Retryable
         | Keeper_librarian_runtime.Provider_not_direct_completion
         | Keeper_librarian_runtime.Unexpected_failure _ ->
           Keeper_memory_lane.Terminal
         | Keeper_librarian_runtime.Extraction_failed extraction_error ->
           (match extraction_error with
            | Keeper_librarian_runtime.Provider_clock_unavailable
            | Keeper_librarian_runtime.Provider_timeout
            | Keeper_librarian_runtime.Provider_transport_failed _
            | Keeper_librarian_runtime.Memory_fact_upsert_failed _
            | Keeper_librarian_runtime.Memory_episode_persistence_failed _ ->
              Keeper_memory_lane.Retryable
            | Keeper_librarian_runtime.Prompt_render_failed _
            | Keeper_librarian_runtime.Provider_config_rejected _
            | Keeper_librarian_runtime.Provider_empty_response
            | Keeper_librarian_runtime.Provider_unparseable_response _ ->
              Keeper_memory_lane.Terminal)
       in
       stage_failed
         ~retryability
         Librarian_extraction
         ~detail
         "librarian extraction failed")
;;

let run_skill_candidate_stage
      (config : Workspace.config)
      (meta : Keeper_meta_contract.keeper_meta)
  =
  match
    Skill_candidate_store.write_all_post_turn_candidates
      ~base_path:config.base_path
      ~keeper_id:meta.name
      ~fact_tail_limit:Keeper_memory_os_io.fact_store_max
  with
  | Error error ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string DispatchEventFailures)
      ~labels:[ "keeper", meta.name; "site", "draft_skill_candidates" ]
      ();
    (* Projection is fully derivable from durable facts/procedures and runs on
       later jobs. Record this job's failure, but do not hold the Keeper's
       linear memory lane behind advisory output. *)
    stage_failed
      Skill_candidate_projection
      ~detail:`Null
      error
  | Ok stored ->
    if stored <> []
    then
      Log.Keeper.info ~keeper_name:meta.name
        "draft_skill_candidates wrote=%d dir=%s"
        (List.length stored)
        (Skill_candidate_store.drafts_dir ~base_path:config.base_path);
    stage_succeeded
      Skill_candidate_projection
      (`Assoc [ "written", `Int (List.length stored) ])
;;

let run_compaction_stage
      (config : Workspace.config)
      (meta : Keeper_meta_contract.keeper_meta)
      runtime_id
  =
  let memory_summarizer =
    Keeper_memory_llm_summary.make ~runtime_id ~keeper_name:meta.name ()
  in
  let compaction =
    Memory.compact_if_needed ?summarizer:memory_summarizer config meta
  in
  if compaction.performed
  then
    Log.Keeper.info ~keeper_name:meta.name
      "memory_compacted before=%d after=%d dropped=%d"
      compaction.before_notes
      compaction.after_notes
      compaction.dropped_notes;
  let detail = Memory.compaction_to_json compaction in
  match compaction.error with
  | None -> stage_succeeded Memory_bank_compaction detail
  | Some error ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string DispatchEventFailures)
      ~labels:[ "keeper", meta.name; "site", "memory_bank_compaction" ]
      ();
    (* Compaction is hygiene over the durable bank, not unique turn input. A
       later job retries it from source state; blocking the lane here would
       prevent non-derivable tool/librarian work from advancing. *)
    stage_failed
      Memory_bank_compaction
      ~detail
      (compaction_error_to_string error)
;;

let validate_payload_identity
      (job : Keeper_memory_job_store.job)
      (payload : job_payload)
  =
  let trace_id =
    Keeper_id.Trace_id.to_string payload.meta.Keeper_meta_contract.runtime.trace_id
  in
  if not (String.equal payload.meta.name job.keeper_name)
  then Error "payload keeper name does not match durable job identity"
  else if not (String.equal trace_id job.trace_id)
  then Error "payload trace id does not match durable job identity"
  else if payload.meta.runtime.generation <> job.generation
  then Error "payload generation does not match durable job identity"
  else if
    not
      (String.equal
         payload.librarian_checkpoint.Agent_sdk.Checkpoint.session_id
         job.trace_id)
  then Error "librarian checkpoint session id does not match durable job identity"
  else if
    not
      (String.equal
         payload.librarian_checkpoint.Agent_sdk.Checkpoint.agent_name
         payload.meta.agent_name)
  then Error "librarian checkpoint agent name does not match keeper metadata"
  else if
    payload.librarian_checkpoint.Agent_sdk.Checkpoint.turn_count
    <> job.oas_turn_count
  then Error "librarian checkpoint turn count does not match durable job identity"
  else if String.equal (String.trim payload.runtime_id) ""
  then Error "payload runtime id must be non-empty"
  else Ok ()
;;

let execute_job ~base_path (job : Keeper_memory_job_store.job) =
  match payload_of_json job.payload with
  | Error message ->
    Error
      Keeper_memory_lane.
        { retryability = Keeper_memory_lane.Terminal
        ; kind = "job_payload_decode_failed"
        ; message
        ; detail = `Null
        }
  | Ok payload ->
    (match validate_payload_identity job payload with
     | Error message ->
       Error
         Keeper_memory_lane.
           { retryability = Keeper_memory_lane.Terminal
           ; kind = "job_identity_mismatch"
           ; message
           ; detail = `Null
           }
     | Ok () ->
       let config = Workspace.default_config base_path in
       (* OCaml does not specify constructor-argument evaluation order. Bind
          every stage explicitly so the required deterministic sequence cannot
          be reversed by list-literal evaluation. *)
       let tool_result_stage =
         protect_stage Tool_result_promotion (fun () ->
           run_tool_result_stage
             config
             payload.meta
             job.turn
             payload.tool_results)
       in
       let librarian_stage =
         protect_stage Librarian_extraction (fun () ->
           run_librarian_stage
             ~base_path:config.base_path
             payload.meta
             job.id
             job.generation
             payload.runtime_id
             payload.librarian_admission
             payload.librarian_checkpoint)
       in
       let skill_candidate_stage =
         protect_stage Skill_candidate_projection (fun () ->
           run_skill_candidate_stage config payload.meta)
       in
       let compaction_stage =
         protect_stage Memory_bank_compaction (fun () ->
           run_compaction_stage config payload.meta payload.runtime_id)
       in
       let stages =
         [ tool_result_stage
         ; librarian_stage
         ; skill_candidate_stage
         ; compaction_stage
         ]
       in
       let detail =
         `Assoc
           [ "schema", `String "masc.keeper_post_turn_memory_receipt.v1"
           ; "job_id", `String job.id
           ; "keeper_name", `String job.keeper_name
           ; "trace_id", `String job.trace_id
           ; "generation", `Int job.generation
           ; "turn", `Int job.turn
           ; "oas_turn_count", `Int job.oas_turn_count
           ; "runtime_id", `String payload.runtime_id
           ; "stages", `List (List.map stage_to_json stages)
           ]
       in
       let failed =
         List.filter
           (fun stage -> stage.status = Stage_failed)
           stages
       in
       match failed with
       | [] -> Ok detail
       | _ ->
         (* A terminal failure in one weakly-coupled stage must not acknowledge
            another stage's retryable persistence failure. Keep the job
            inflight until every retryable stage succeeds; a remaining
            terminal-only failure can then commit its failed receipt and let
            the next Keeper memory job proceed. *)
         let names =
           List.map (fun stage -> stage_name_to_string stage.name) failed
         in
         Error
           Keeper_memory_lane.
             { retryability =
                 (if
                    List.exists
                      (fun stage ->
                         stage.failure_retryability
                         = Some Keeper_memory_lane.Retryable)
                      failed
                  then Keeper_memory_lane.Retryable
                  else Keeper_memory_lane.Terminal)
             ; kind = "post_turn_stage_failure"
             ; message = String.concat "," names
             ; detail
             })
;;

let run
  ~(config : Workspace.config)
  ~(meta : Keeper_meta_contract.keeper_meta)
  ~generation
  ~turn
  ~oas_turn_count
  ~response_text
  ~actual_tools
  ~librarian_checkpoint
  ~tool_results_snapshot
  ~post_turn_t0
  ~runtime_id
  ~inference_telemetry
  ()
  =
  let payload =
    let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
    let librarian_admission =
      Keeper_librarian_runtime.decide_librarian_admission
        ~keeper_turn:turn
    in
    payload_to_json
      ~meta
      ~runtime_id
      ~librarian_admission
      ~librarian_checkpoint
      ~tool_results:tool_results_snapshot
  in
  let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  let submission_outcome =
    match
     Keeper_memory_job_store.make_job
       ~keeper_name:meta.name
       ~trace_id
       ~generation
       ~turn
       ~oas_turn_count
       ~enqueued_at:(Time_compat.now ())
       ~payload
   with
   | Error error ->
     Otel_metric_store.inc_counter
       Keeper_metrics.(to_string MemoryWriteFailures)
       ~labels:[ "keeper", meta.name ]
       ();
     Log.Keeper.error ~keeper_name:meta.name
       "memory lane job construction failed: %s"
       (Keeper_memory_job_store.error_to_string error);
     Not_durable
   | Ok job ->
     (match Keeper_memory_lane.stage ~base_path:config.base_path job with
      | Keeper_memory_lane.Stage_rejected _ -> Not_durable
      | Keeper_memory_lane.Staged _ -> Durable job)
  in
  (* Post-turn memory recall evidence is logged to decisions.jsonl. *)
  (try
     let used_search =
       List.exists
         (fun name ->
            match Keeper_tool_name.of_string name with
            | Some Keeper_tool_name.Memory_search -> true
            | Some _ | None -> false)
         actual_tools
     in
     let recall_eval =
       if used_search
       then (
         (* Use session history (role+content), not the decision memory bank
            (kind+text+priority).  The bank format caused 60 Type_error
            WARN/cycle — every line skipped because [load_history_user_messages]
            expects [role] and [content] fields. *)
         let history_path =
           Keeper_types_support.keeper_history_path config
             (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
         in
         let candidates =
           match
             Keeper_memory_recall.load_history_user_messages_result
               ~path:history_path
               ~max_n:50
           with
           | Ok msgs -> msgs
           | Error exn_class ->
             let exn_label =
               Keeper_memory_recall_exn_class.to_label exn_class
             in
             Otel_metric_store.inc_counter
               Keeper_metrics.(to_string DispatchEventFailures)
               ~labels:
                 [ "keeper", meta.name; "site", "memory_recall" ]
               ();
             Log.Keeper.warn ~keeper_name:meta.name
               "memory recall history load failed: <error class=%s>"
               exn_label;
             []
         in
         Some
           (Keeper_memory_recall.evaluate_memory_recall
              ~user_message:""
              ~assistant_reply:response_text
              ~candidates))
       else None
     in
     let post_turn_ms =
       Keeper_timing.round1
         ((Time_compat.now () -. post_turn_t0) *. 1000.0)
     in
     let eval_json =
       `Assoc
         ([ "ts_unix", `Float (Time_compat.now ())
          ; "event", `String "post_turn_eval"
          ; "keeper_name", `String meta.name
          ; "turn", `Int turn
          ; "oas_turn_count", `Int oas_turn_count
          ; "used_memory_search", `Bool used_search
          ; "post_turn_ms", `Float post_turn_ms
          ]
          @ (match inference_telemetry with
             | Some t ->
               [ ( "inference_telemetry"
                 , Keeper_hooks_oas.inference_telemetry_to_runtime_json t )
               ]
             | None -> [])
          @ (match recall_eval with
             | Some e ->
               [ "memory_recall_performed", `Bool e.performed
               ; "memory_recall_passed", `Bool e.passed
               ; "memory_recall_score", `Float e.final_score
               ; "memory_recall_candidates", `Int e.candidate_count
               ]
             | None -> []))
     in
     Keeper_types_support.append_jsonl_line
       (Keeper_types_support.keeper_decision_log_path
          config
          meta.name)
       eval_json
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
     Otel_metric_store.inc_counter
       Keeper_metrics.(to_string DispatchEventFailures)
       ~labels:[ "keeper", meta.name; "site", "post_turn_eval" ]
       ();
     Log.Keeper.warn ~keeper_name:meta.name
       "post_turn_eval jsonl append failed: %s"
       (Printexc.to_string exn));
  submission_outcome
;;
