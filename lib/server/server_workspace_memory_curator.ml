module Context = Workspace_memory_context
module Ledger = Workspace_memory_ledger
module Request = Workspace_memory_request
module Decision = Workspace_memory_decision
module Briefing = Workspace_memory_briefing
module Log_store = Workspace_memory_log
module Pass = Server_workspace_memory_curator_pass
module Exact = Agent_core.Exact_output
module Registry = Runtime_exact_output_registry
module Slots = Exact_lane_slots
module Failure_evidence = Keeper_exact_walk_failure
open Result.Syntax

let io work = Systhread_host.run ~label:"workspace-curator-io" work
let raw_excerpt = Keeper_exact_flow_detail.raw_response_excerpt

type no_callback_error = |

let no_callback_error_to_string : no_callback_error -> string = function
  | _ -> .
;;

let iso8601_now () = Masc_domain.iso8601_of_unix_seconds (Time_compat.now ())

type resolved_lane_execution =
  { generation : string
  ; resolved : Registry.resolved_lane
  }

type lane_resolve_outcome =
  | Lane_ready of resolved_lane_execution
  | Lane_disabled of string
  | Lane_busy of string

(* The curator's own table. The Librarian's Memory lane starts no curator
   call: the two share no declaration, slot order or limit evidence. *)
let lane_id = Standalone_lane.to_id Standalone_lane.Workspace_memory_curator

let resolve_lane_execution () =
  match Registry.current () with
  | Error Registry.Publication_busy ->
    Lane_busy "exact-output registry replacement in progress"
  | Error
      (( Registry.Registry_not_published
       | Replacement_base_changed
       | Duplicate_lane_id _
       | Empty_lane _
       | Blank_lane_slot _
       | Duplicate_lane_slot _
       | Invalid_lane_slot _
       | Lane_thinking_not_encodable _
       | Required_lane_unavailable _
       | Required_lane_disabled _
       | Resolver_snapshot_rejected _
       | Targets_refused _ ) as err) ->
    Lane_disabled (Registry.publication_error_to_string err)
  | Ok registry ->
    (match Registry.resolve_lane registry ~lane_id with
     | Ok resolved ->
       let generation = Registry.catalog_generation_fingerprint registry in
       Lane_ready { generation; resolved }
     | Error err -> Lane_disabled (Registry.lane_resolution_error_to_string err))
;;

type lane_call_failure =
  { capacity_refused : bool
  ; transient : bool
  ; detail : string
  }

type slot_failure = (string, no_callback_error) Slots.failure

let flow_detail cause =
  Exact.flow_execution_error_to_string
    ~callback_error_to_string:no_callback_error_to_string
    ~raw_response_to_string:raw_excerpt
    cause
;;

(* The answer was cut at the slot's output budget, so a smaller batch, which
   asks for a shorter answer, can fit it. *)
let is_output_limit_cause = function
  | Exact.Output_limit_reached -> true
  | Completion_failed _
  | Response_body_deadline_exceeded
  | Provider_response_refused _
  | Provider_context_overflow _
  | Window_reached _
  | Incomplete_output _
  | Missing_output
  | Ambiguous_output _
  | Unexpected_output_content
  | Invalid_json_output -> false
;;

let flow_ran_out_of_output : no_callback_error Exact.flow_execution_error -> bool = function
  | Flow_exact_execution_failed { cause = error; candidate = _; evidence = _ } ->
    is_output_limit_cause error.cause
  | Flow_candidates_exhausted _
  | Flow_attempt_already_started _
  | Flow_attempt_start_failed _
  | Flow_measurement_start_failed _
  | Flow_before_measurement_dispatch_callback_failed _
  | Flow_measurement_terminal_callback_failed _
  | Flow_before_dispatch_callback_failed _
  | Flow_before_advance_callback_failed _ -> false
;;

let ran_out_of_output : (Slots.t, slot_failure) Exact_lane_walk.passed -> bool = function
  | Failed
      { slot = _
      ; failure =
          Http_failed { slot_id = _; error = Flow_execution_terminal { cause; prior_rejections = _ } }
      } -> flow_ran_out_of_output cause
  | Failed
      { slot = _; failure = Http_failed { slot_id = _; error = Flow_semantic_candidates_exhausted _ } }
  | Failed
      { slot = _
      ; failure =
          (Http_unfit _ | Cli_failed _ | Cli_rejected _ | Cli_unfit _ | Cli_seats_unpublished _)
      }
  | Held { slot = _; until = _ }
  | Seats_full _ -> false
;;

let failure_detail : slot_failure -> string = function
  | Http_failed { slot_id; error = Flow_semantic_candidates_exhausted { rejections; evidence = _ } }
    ->
    let last = List.fold_left (fun _ rejection -> rejection) rejections.first rejections.rest in
    slot_id ^ ": invalid domain output: " ^ last.rejection
  | Http_failed { slot_id = _; error = Flow_execution_terminal { cause; prior_rejections = _ } } ->
    flow_detail cause
  | Http_unfit { slot_id; reason } -> slot_id ^ ": " ^ reason
  | Cli_failed { runtime_id = _; failure } -> Keeper_lane_cli_oneshot.failure_to_string failure
  | Cli_rejected { runtime_id; rejection } -> runtime_id ^ ": invalid domain output: " ^ rejection
  | Cli_unfit { runtime_id } -> runtime_id ^ ": the request is not one prompt"
  | Cli_seats_unpublished { runtime_id; provider_id } ->
    runtime_id ^ ": account " ^ provider_id ^ " published no seats"
;;

let pass_detail : (Slots.t, slot_failure) Exact_lane_walk.passed -> string = function
  | Held { slot; until } ->
    Slots.id slot ^ ": waits for its provider until " ^ Masc_domain.iso8601_of_unix_seconds until
  | Seats_full slot -> Slots.id slot ^ ": every seat taken"
  | Failed { slot = _; failure } -> failure_detail failure
;;

let stop_detail : (string, no_callback_error) Slots.stop -> string = function
  | Http_unstartable { slot_id; reason } -> slot_id ^ ": " ^ reason
  | Http_stopped { slot_id = _; error = Flow_execution_terminal { cause; prior_rejections = _ } } ->
    flow_detail cause
  | Http_stopped { slot_id; error = Flow_semantic_candidates_exhausted _ } ->
    slot_id ^ ": every answer was rejected"
  | Record_failed _ -> .
;;

(* The batch is narrowed when a slot refused the input's size and no slot
   answered invalid output, or, where the caller allows it, when a slot's
   answer was cut at its output budget. *)
let lane_failure ~allow_output_limit_split ~transient ~detail passed =
  { capacity_refused =
      Failure_evidence.refuses_input_capacity (Slots.failure_evidence passed)
      || (allow_output_limit_split && List.exists ran_out_of_output passed)
  ; transient
  ; detail = String.concat "; " (List.map pass_detail passed @ detail)
  }
;;

(* One walk over the lane's slots, HTTP and CLI alike
   (RFC exact-lane-walks-one-slot-list). *)
let execute_exact_prompt ~base_path ~(lane : resolved_lane_execution) ~schema ~rendered_prompt
    ~allow_output_limit_split ~validate =
  match Eio_context.get_net_opt (), Eio_context.get_clock_opt () with
  | None, _ | _, None ->
    Error
      { capacity_refused = false
      ; transient = true
      ; detail = "server Eio net/clock context unavailable"
      }
  | Some net, Some clock ->
    let proceed _ : (unit, no_callback_error) result =
      Eio.Fiber.check ();
      Ok ()
    in
    (match
       Slots.walk
         ~net
         ~clock
         ~base_dir:base_path
         ~admission_class:(Standalone_lane.admission_class Standalone_lane.Workspace_memory_curator)
         ~messages:
           [ Llm_provider.Types.make_message
               ~role:Llm_provider.Types.User
               [ Llm_provider.Types.text_block rendered_prompt ]
           ]
         ~requirement:(Exact.make_output_requirement ~schema ~minimum_guarantee:Exact.Json_syntax)
         ~cli_request:(Some { Slots.system_prompt = ""; prompt = rendered_prompt })
         ~before_measurement_dispatch:proceed
         ~on_measurement_terminal:proceed
         ~before_dispatch:proceed
         ~validate_http:(fun success ->
           match validate (Exact.flow_success_output success).output with
           | Ok accepted -> Exact.Accept accepted
           | Error rejection -> Exact.Reject_and_advance rejection)
         ~validate_cli:validate
         ~before_cli_visit:(fun ~runtime_id:_ -> proceed ())
         ~on_advance:(fun ~failed:_ ~next:_ -> proceed ())
         (Slots.of_resolved_lane lane.resolved)
     with
     | Answered { slot = _; value = Http_answered { slot_id = _; success }; passed = _ } ->
       Ok success.accepted
     | Answered { slot = _; value = Cli_answered { runtime_id = _; accepted }; passed = _ } ->
       Ok accepted
     | Exhausted { passed; standing } ->
       let transient =
         match standing with
         | Every_slot_resting -> true
         | Not_every_slot_resting -> false
       in
       Error (lane_failure ~allow_output_limit_split ~transient ~detail:[] passed)
     | Stopped { slot = _; stop; passed } ->
       Error
         (lane_failure
            ~allow_output_limit_split
            ~transient:false
            ~detail:[ stop_detail stop ]
            passed))
;;

let commit_two_phase_log_dynamic ~base_path ~author ~expected_changes ~apply_and_entries =
  if expected_changes <= 0 then
    Result.map fst (apply_and_entries ())
  else
    let log_path = Log_store.log_path ~base_path in
    let batch_id = Random_id.uuid_v7 () in
    let now_iso = iso8601_now () in
    let header : Log_store.batch_header =
      { batch_id
      ; author
      ; started_at = now_iso
      ; expected_changes
      }
    in
    let* base_seq =
      Log_store.prepare_batch ~path:log_path ~header
      |> Result.map_error Log_store.error_to_string
    in
    let try_abort reason =
      match
        Log_store.abort_prepared_batch
          ~path:log_path
          ~batch_id
          ~aborted_at:(iso8601_now ())
          ~reason
      with
      | Ok () -> ()
      | Error abort_err ->
        Log.Server.warn "workspace curator abort batch %s failed: %s" batch_id
          (Log_store.error_to_string abort_err)
    in
    match apply_and_entries () with
    | Error detail ->
      try_abort detail;
      Error detail
    | Ok (value, entries) ->
      let changes =
        List.mapi
          (fun idx (fact_id, summary, payload) : Log_store.change_entry ->
             { seq = base_seq + 1 + idx
             ; batch_id
             ; fact_id
             ; summary
             ; payload
             ; recorded_at = now_iso
             })
          entries
      in
      (match
         Log_store.commit_prepared_batch
           ~path:log_path
           ~batch_id
           ~changes
           ~committed_at:(iso8601_now ())
       with
       | Ok (_final_seq : int) -> Ok value
       | Error commit_err ->
         let detail = Log_store.error_to_string commit_err in
         try_abort ("commit failed after state save: " ^ detail);
         Log.Server.warn
           "workspace curator log commit failed after ledger save (batch %s; ledger ahead of log): %s"
           batch_id
           detail;
         Error detail)
;;

let commit_two_phase_log ~base_path ~author ~entries ~apply_state =
  commit_two_phase_log_dynamic
    ~base_path
    ~author
    ~expected_changes:(List.length entries)
    ~apply_and_entries:(fun () ->
      let* value = apply_state () in
      Ok (value, entries))
;;

let log_entries_of_reconciliation (detailed : Ledger.detailed_reconciliation) =
  let retracted =
    List.map
      (fun claim_id ->
         ( "claim:" ^ claim_id
         , Printf.sprintf "Claim %s retracted after losing all supporting Keepers" claim_id
         , `Assoc [ "kind", `String "claim_retracted"; "claim_id", `String claim_id ] ))
      detailed.retracted_claims
  in
  let shrank =
    List.map
      (fun (c : Ledger.provenance_change) ->
         ( "claim:" ^ c.provenance.claim_id
         , Printf.sprintf
             "Claim %s support shrank (%d -> %d; stage %s -> %s)"
             c.provenance.claim_id
             c.prior_support_count
             c.provenance.support_count
             (Ledger.corroboration_stage_to_string c.prior_stage)
             (Ledger.corroboration_stage_to_string c.provenance.stage)
         , `Assoc
             [ "kind", `String "claim_shrank"
             ; "claim_id", `String c.provenance.claim_id
             ; "prior_support_count", `Int c.prior_support_count
             ; "support_count", `Int c.provenance.support_count
             ; "prior_stage", `String (Ledger.corroboration_stage_to_string c.prior_stage)
             ; "stage", `String (Ledger.corroboration_stage_to_string c.provenance.stage)
             ; "vanished_keepers", `List (List.map (fun k -> `String k) c.vanished_keepers)
             ] ))
      detailed.shrank_claims
  in
  let dissolved =
    List.map
      (fun conflict_id ->
         ( "conflict:" ^ conflict_id
         , Printf.sprintf "Conflict %s dissolved below two members" conflict_id
         , `Assoc [ "kind", `String "conflict_dissolved"; "conflict_id", `String conflict_id ] ))
      detailed.dissolved_conflicts
  in
  retracted @ shrank @ dissolved
;;

let log_entries_of_assignments ~ledger (assignments : Ledger.assignment list) =
  let find_claim_id fact =
    match
      Ledger.dispositions ledger
      |> List.find_opt (fun (f, _) -> Ledger.compare_fact_ref f fact = 0)
    with
    | Some (_, Ledger.Claim_member id) -> Some id
    | Some (_, (Ledger.Conflict_member _ | Ledger.Excluded _)) | None -> None
  in
  let find_conflict_id fact =
    match
      Ledger.dispositions ledger
      |> List.find_opt (fun (f, _) -> Ledger.compare_fact_ref f fact = 0)
    with
    | Some (_, Ledger.Conflict_member id) -> Some id
    | Some (_, (Ledger.Claim_member _ | Ledger.Excluded _)) | None -> None
  in
  let claim_entry ~kind_label ~summary_fn ~extra_fields (a : Ledger.assignment) =
    let fact_json = Ledger.fact_ref_to_json a.fact in
    let claim_id_opt = find_claim_id a.fact in
    let target_id = Option.value ~default:"claim" claim_id_opt in
    let stage_fields =
      match Option.bind claim_id_opt (fun id -> Ledger.claim_provenance ledger ~claim_id:id) with
      | Some (p : Ledger.claim_provenance) ->
        [ "stage", `String (Ledger.corroboration_stage_to_string p.stage) ]
      | None -> []
    in
    ( "claim:" ^ target_id
    , summary_fn target_id
    , `Assoc
        ([ "kind", `String kind_label
         ; "claim_id", `String target_id
         ; "fact", fact_json
         ]
         @ stage_fields
         @ extra_fields) )
  in
  let conflict_entry ~kind_label ~summary_fn ~extra_fields (a : Ledger.assignment) =
    let fact_json = Ledger.fact_ref_to_json a.fact in
    let target_id = Option.value ~default:"conflict" (find_conflict_id a.fact) in
    ( "conflict:" ^ target_id
    , summary_fn target_id
    , `Assoc
        ([ "kind", `String kind_label
         ; "conflict_id", `String target_id
         ; "fact", fact_json
         ]
         @ extra_fields) )
  in
  List.map
    (fun (a : Ledger.assignment) ->
       match a.decision with
       | Ledger.Create_claim text ->
         claim_entry
           ~kind_label:"claim_created"
           ~summary_fn:(fun id -> Printf.sprintf "Created claim %s: %s" id text)
           ~extra_fields:[ "claim", `String text ]
           a
       | Ledger.Join_claim id ->
         claim_entry
           ~kind_label:"claim_joined"
           ~summary_fn:(fun _ -> Printf.sprintf "Joined claim %s" id)
           ~extra_fields:[]
           a
       | Ledger.Create_conflict desc ->
         conflict_entry
           ~kind_label:"conflict_created"
           ~summary_fn:(fun id -> Printf.sprintf "Created conflict %s: %s" id desc)
           ~extra_fields:[ "description", `String desc ]
           a
       | Ledger.Join_conflict id ->
         conflict_entry
           ~kind_label:"conflict_joined"
           ~summary_fn:(fun _ -> Printf.sprintf "Joined conflict %s" id)
           ~extra_fields:[]
           a
       | Ledger.Exclude reason ->
         ( "excluded"
         , Printf.sprintf "Excluded fact (%s)" reason
         , `Assoc
             [ "kind", `String "fact_excluded"
             ; "reason", `String reason
             ; "fact", Ledger.fact_ref_to_json a.fact
             ] ))
    assignments
;;

type idle_checkpoint = unit ref
type idle_result = Owner_idle of idle_checkpoint | Owner_stopped | Owner_missing

type owner =
  { mutex : Stdlib.Mutex.t
  ; mutable pending : bool
  ; mutable in_flight : bool
  ; mutable stopped : bool
  ; mutable observation_retry : bool
  ; mutable wake : unit Eio.Promise.u option
  ; mutable idle_checkpoint : idle_checkpoint
  ; mutable idle_waiters : idle_result Eio.Promise.u list
  ; mutable indivisible_generation : string
  ; mutable indivisible_facts : Ledger.fact_ref list
  ; mutable classification_size : Request.size
  ; in_flight_revisions : (string * Keeper_memory_commit_notifications.store, int) Hashtbl.t
  }

type domain_step_outcome =
  | Progressed
  | Idle
  | Transient_retry
  | Failed of string

let run_reconciliation ~base_path =
  let* context, initial_ledger =
    io (fun () ->
      let* context = Context.collect ~base_path in
      let* ledger = Ledger.load ~base_path in
      Ok (context, ledger))
  in
  let keepers = Context.keepers context in
  let initial_detailed = Ledger.reconcile_detailed initial_ledger keepers in
  if initial_detailed.reconciliation.vanished = [] then
    Ok (context, initial_detailed.reconciliation, false)
  else
    let latest_detailed = ref initial_detailed in
    let* updated_ledger =
      io (fun () ->
        let* updated =
          Ledger.update ~base_path (fun latest ->
            let d = Ledger.reconcile_detailed latest keepers in
            latest_detailed := d;
            Ok d.reconciliation.ledger)
        in
        let detailed = !latest_detailed in
        let entries = log_entries_of_reconciliation detailed in
        let* () =
          if entries = [] then Ok ()
          else
            commit_two_phase_log
              ~base_path
              ~author:"workspace-memory-curator"
              ~entries
              ~apply_state:(fun () -> Ok ())
        in
        Ok updated)
    in
    let detailed = !latest_detailed in
    let ledger_changed = detailed.reconciliation.vanished <> [] in
    if ledger_changed then Mcp_server_eio_resource.notify_world_memory_updated ();
    Ok (context, { detailed.reconciliation with ledger = updated_ledger }, ledger_changed)
;;

let run_classification ~base_path ~(owner : owner) =
  Pass.with_domain Pass.Classification (fun () ->
    match run_reconciliation ~base_path with
    | Error detail -> Failed detail
    | Ok (context, reconciliation, reconciled_changed) ->
      let blocked_indivisible =
        Stdlib.Mutex.protect owner.mutex (fun () -> owner.indivisible_facts)
      in
      let pending =
        List.filter
          (fun (f : Ledger.pending_fact) -> not (List.mem f.fact blocked_indivisible))
          reconciliation.new_facts
      in
      if pending = [] then
        if reconciled_changed then Progressed else Idle
      else
        match resolve_lane_execution () with
        | Lane_busy detail ->
          Log.Server.debug "workspace curator classification deferred: %s" detail;
          Transient_retry
        | Lane_disabled detail ->
          Log.Server.debug "workspace curator classification lane unavailable: %s" detail;
          Idle
        | Lane_ready lane ->
          Stdlib.Mutex.protect owner.mutex (fun () ->
            if not (String.equal owner.indivisible_generation lane.generation) then (
              owner.indivisible_generation <- lane.generation;
              owner.indivisible_facts <- [];
              owner.classification_size <- Request.Fill_frame));
          let size = Stdlib.Mutex.protect owner.mutex (fun () -> owner.classification_size) in
          let resolution = Prompt_registry.resolve_prompt Prompt_names.workspace_memory_curator in
          let render input =
            Prompt_registry.render_resolved_prompt_template
              Prompt_names.workspace_memory_curator
              resolution
              [ "workspace_memory_changes", Yojson.Safe.to_string input ]
          in
          let neighbor_limit = max 0 (List.length (Context.keepers context) - 1) in
          (match
             Request.prepare
               ~neighbor_limit
               ~render
               ~ledger:reconciliation.ledger
               ~current:reconciliation.current_facts
               ~pending
               ~size
               ~frame:max_int
               ~measure:(fun batch -> Ok (String.length batch.rendered_prompt))
           with
           | Error err -> Failed (Request.error_to_string err)
           | Ok None -> if reconciled_changed then Progressed else Idle
           | Ok (Some initial_batch) ->
             let rec attempt_batch batch ~narrowed =
               let validate json = Decision.decode ~batch json in
               match
                 execute_exact_prompt
                   ~base_path
                   ~lane
                   ~schema:Decision.output_schema
                   ~rendered_prompt:batch.rendered_prompt
                   ~allow_output_limit_split:true
                   ~validate
               with
               | Ok assignments ->
                 if narrowed then
                   Stdlib.Mutex.protect owner.mutex (fun () ->
                     owner.classification_size <- Request.Up_to (List.length batch.selected));
                 let commit_res =
                   io (fun () ->
                     commit_two_phase_log_dynamic
                       ~base_path
                       ~author:"workspace-memory-curator"
                       ~expected_changes:(List.length assignments)
                       ~apply_and_entries:(fun () ->
                         let* applied_ledger =
                           Ledger.update ~base_path (fun latest ->
                             Ledger.apply latest ~selected:batch.selected assignments
                             |> Result.map_error Ledger.apply_error_to_string)
                         in
                         let entries =
                           log_entries_of_assignments ~ledger:applied_ledger assignments
                         in
                         Ok ((), entries)))
                 in
                 (match commit_res with
                  | Ok () ->
                    Mcp_server_eio_resource.notify_world_memory_updated ();
                    Progressed
                  | Error detail -> Failed detail)
               | Error failure when failure.capacity_refused ->
                 (match Request.narrow ~ledger:reconciliation.ledger ~render batch with
                  | Error err -> Failed (Request.error_to_string err)
                  | Ok (Some smaller) -> attempt_batch smaller ~narrowed:true
                  | Ok None ->
                    (match batch.selected with
                     | single :: _ ->
                       Stdlib.Mutex.protect owner.mutex (fun () ->
                         if not (List.mem single.fact owner.indivisible_facts) then
                           owner.indivisible_facts <- single.fact :: owner.indivisible_facts);
                       Log.Server.error
                         "workspace curator indivisible fact refused for capacity: %s"
                         failure.detail
                     | [] -> ());
                    if reconciled_changed then Progressed else Idle)
               | Error failure ->
                 if failure.transient then (
                   Log.Server.warn
                     "workspace curator classification transient refusal: %s"
                     failure.detail;
                   Transient_retry)
                 else Failed failure.detail
             in
             attempt_batch initial_batch ~narrowed:false))
;;

let run_briefing ~base_path =
  Pass.with_domain Pass.Briefing (fun () ->
    let directory = Ledger.directory ~base_path in
    match
      io (fun () ->
        let* ledger = Ledger.load ~base_path in
        let* state = Briefing.load ~directory in
        Ok (ledger, state))
    with
    | Error detail -> Failed detail
    | Ok (ledger, state) ->
      let sources = Ledger.briefing_sources ledger in
      let resolution = Prompt_registry.resolve_prompt Prompt_names.workspace_memory_briefing in
      let contract = Briefing.contract ~template:resolution.effective in
      let render input =
        Prompt_registry.render_resolved_prompt_template
          Prompt_names.workspace_memory_briefing
          resolution
          [ "workspace_memory_briefing", Yojson.Safe.to_string input ]
      in
      match Briefing.prepare ~sources ~contract ~render state with
      | Error detail -> Failed detail
      | Ok Briefing.Unchanged -> Idle
      | Ok (Briefing.Cleanup _ | Briefing.Prepared _) ->
        let step = ref None in
        (match
           io (fun () ->
             Briefing.update ~directory (fun current ->
               let* prep = Briefing.prepare ~sources ~contract ~render current in
               step := Some prep;
               match prep with
               | Briefing.Unchanged -> Ok current
               | Briefing.Cleanup cleaned -> Ok cleaned
               | Briefing.Prepared batch -> Ok (Briefing.prepared_state batch)))
         with
         | Error detail -> Failed detail
         | Ok _ ->
           (match !step with
            | None | Some Briefing.Unchanged -> Idle
            | Some (Briefing.Cleanup _) ->
              Mcp_server_eio_resource.notify_world_memory_updated ();
              Progressed
            | Some (Briefing.Prepared initial_batch) ->
              (match resolve_lane_execution () with
            | Lane_busy detail ->
              Log.Server.debug "workspace curator briefing deferred: %s" detail;
              Transient_retry
            | Lane_disabled detail ->
              Log.Server.debug "workspace curator briefing lane unavailable: %s" detail;
              Idle
            | Lane_ready lane ->
              let rec attempt_batch batch =
                let prompt = Briefing.rendered_prompt batch in
                let validate json = Briefing.decode_output json in
                match
                  execute_exact_prompt
                    ~base_path
                    ~lane
                    ~schema:Briefing.output_schema
                    ~rendered_prompt:prompt
                    ~allow_output_limit_split:false
                    ~validate
                with
                | Ok text ->
                  (match Briefing.accept batch ~text with
                   | Error detail -> Failed detail
                   | Ok next_state ->
                     let remaining = Briefing.remaining_count batch in
                     let entries =
                       [ ( "briefing"
                         , Printf.sprintf
                             "Workspace briefing updated (selected=%d, remaining=%d)"
                             (Briefing.selected_count batch)
                             remaining
                         , `Assoc
                             [ "kind", `String "briefing_updated"
                             ; "selected_count", `Int (Briefing.selected_count batch)
                             ; "remaining_count", `Int remaining
                             ; "complete", `Bool (remaining = 0)
                             ] )
                       ]
                     in
                     (match
                        io (fun () ->
                          commit_two_phase_log
                            ~base_path
                            ~author:"workspace-memory-curator"
                            ~entries
                            ~apply_state:(fun () -> Briefing.save ~directory next_state))
                      with
                      | Ok () ->
                        Mcp_server_eio_resource.notify_world_memory_updated ();
                        Progressed
                      | Error detail -> Failed detail))
                | Error failure when failure.capacity_refused ->
                  (match Briefing.narrow ~render batch with
                   | Error detail -> Failed detail
                   | Ok (Some smaller) -> attempt_batch smaller
                   | Ok None -> Failed ("indivisible briefing chunk refused: " ^ failure.detail))
                | Error failure ->
                  if failure.transient then (
                    Log.Server.warn
                      "workspace curator briefing transient refusal: %s"
                      failure.detail;
                    Transient_retry)
                  else Failed failure.detail
              in
              attempt_batch initial_batch))))
;;

let run_pass ~base_path ~(owner : owner) ~on_observation_failure =
  Pass.with_pass ~base_path (fun () ->
    let c = run_classification ~base_path ~owner in
    let b = run_briefing ~base_path in
    let interpret label = function
      | Progressed -> true
      | Idle -> false
      | Transient_retry ->
        on_observation_failure ();
        false
      | Failed detail ->
        on_observation_failure ();
        Log.Server.error "workspace curator %s: %s" label detail;
        false
    in
    let cp = interpret "classification" c in
    let bp = interpret "briefing" b in
    cp || bp)
;;

(* The caller holds [owner.mutex]. Resolving promises happens after releasing
   it: an idle observation is not a lease against a subsequent wake. *)
let take_idle_waiters owner =
  if owner.stopped || (not owner.pending && not owner.in_flight) then (
    let result = if owner.stopped then Owner_stopped else Owner_idle owner.idle_checkpoint in
    let waiters = owner.idle_waiters in
    owner.idle_waiters <- [];
    List.map (fun waiter -> waiter, result) waiters)
  else []
;;

let resolve_idle_waiters waiters =
  List.iter (fun (waiter, result) -> ignore (Eio.Promise.try_resolve waiter result)) waiters
;;

let owners_mutex = Stdlib.Mutex.create ()
let owners : (string, owner) Hashtbl.t = Hashtbl.create 4

type refresh = Queued | No_owner | Unavailable of string

let wake owner =
  let queued, resolver =
    Stdlib.Mutex.protect owner.mutex (fun () ->
      if owner.stopped then false, None
      else (
        owner.pending <- true;
        let resolver = owner.wake in
        owner.wake <- None;
        true, resolver))
  in
  Option.iter (fun resolver -> Eio.Promise.resolve resolver ()) resolver;
  if queued then Queued else No_owner
;;

(* Keeper_memory_commit_notifications.Current.replace increments snapshot.revision
   monotonically per (keepers_dir, keeper_id, store), while recovery may
   re-dispatch the same revision. Suppress only duplicate wakes for a revision
   that is already in-flight; once in_flight clears at the end of a drain pass,
   in_flight_revisions is cleared so any subsequent commit wakes a fresh pass. *)
let wake_for_commit owner (event : Keeper_memory_commit_notifications.event) =
  let key = event.keeper_id, event.store in
  let should_wake, resolver =
    Stdlib.Mutex.protect owner.mutex (fun () ->
      if owner.stopped then false, None
      else if owner.in_flight
              && Hashtbl.find_opt owner.in_flight_revisions key = Some event.revision
      then false, None
      else (
        Hashtbl.replace owner.in_flight_revisions key event.revision;
        owner.pending <- true;
        let resolver = owner.wake in
        owner.wake <- None;
        true, resolver))
  in
  Option.iter (fun resolver -> Eio.Promise.resolve resolver ()) resolver;
  if should_wake then Queued else No_owner
;;

let realpath_offloaded path = io (fun () -> Unix.realpath path)

let request ~base_path =
  match realpath_offloaded base_path with
  | base_path ->
    let owner =
      Stdlib.Mutex.protect owners_mutex (fun () -> Hashtbl.find_opt owners base_path)
    in
    (match owner with
     | None -> No_owner
     | Some owner ->
       Stdlib.Mutex.protect owner.mutex (fun () ->
         owner.indivisible_facts <- [];
         owner.classification_size <- Request.Fill_frame);
       wake owner)
  | exception Unix.Unix_error (error, operation, _) ->
    Unavailable (operation ^ ": " ^ Unix.error_message error)
;;

let retry_pending_observations ~base_path =
  match realpath_offloaded base_path with
  | base_path ->
    let owner =
      Stdlib.Mutex.protect owners_mutex (fun () -> Hashtbl.find_opt owners base_path)
    in
    (match owner with
     | None -> ()
     | Some owner ->
       let pending =
         Stdlib.Mutex.protect owner.mutex (fun () ->
           owner.observation_retry && not owner.stopped)
       in
       if pending then ignore (wake owner))
  | exception Unix.Unix_error (error, operation, _) ->
    Log.Server.warn
      "workspace curator retry identity %s: %s: %s"
      base_path
      operation
      (Unix.error_message error)
;;

let recover_startup_log ~base_path =
  let log_path = Log_store.log_path ~base_path in
  if Sys.file_exists log_path then
    match Log_store.recover_file ~path:log_path with
    | Error err ->
      Log.Server.warn
        "workspace curator startup log recovery read %s: %s"
        log_path
        (Log_store.error_to_string err)
    | Ok report when report.incomplete_batches = [] -> ()
    | Ok report ->
      (match
         Log_store.abort_incomplete_batches
           ~path:log_path
           ~aborted_at:(iso8601_now ())
           ~reason:"aborted incomplete batch on curator startup recovery"
           report
       with
       | Ok _ -> ()
       | Error err ->
         Log.Server.warn
           "workspace curator startup log abort %s: %s"
           log_path
           (Log_store.error_to_string err))
;;

let start ~sw ~config =
  Eio.Switch.check sw;
  let base_path, keepers_dir =
    io (fun () ->
      let base = Unix.realpath config.Workspace.base_path in
      let raw_keepers = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
      (* A missing directory is an inventory failure, not an empty workspace.
         Creating it here could reconcile every durable ledger member away. *)
      let keepers =
        try Unix.realpath raw_keepers with
        | Unix.Unix_error (Unix.ENOENT, _, _) -> raw_keepers
      in
      recover_startup_log ~base_path:base;
      base, keepers)
  in
  let owner =
    { mutex = Stdlib.Mutex.create ()
    ; pending = true
    ; in_flight = false
    ; stopped = false
    ; observation_retry = false
    ; wake = None
    ; idle_checkpoint = ref ()
    ; idle_waiters = []
    ; indivisible_generation = ""
    ; indivisible_facts = []
    ; classification_size = Request.Fill_frame
    ; in_flight_revisions = Hashtbl.create 8
    }
  in
  let admitted =
    Stdlib.Mutex.protect owners_mutex (fun () ->
      if Hashtbl.mem owners base_path then false
      else (
        Hashtbl.add owners base_path owner;
        true))
  in
  if admitted then (
    let unsubscribe_commits =
      Keeper_memory_commit_notifications.subscribe (fun event ->
        if String.equal event.keepers_dir keepers_dir then ignore (wake_for_commit owner event))
    in
    let unsubscribe_lane =
      Registry.subscribe_lane_changes ~lane_id (fun () ->
        ignore (wake owner))
    in
    Eio.Switch.on_release sw (fun () ->
      let waiters =
        Stdlib.Mutex.protect owner.mutex (fun () ->
          owner.stopped <- true;
          owner.wake <- None;
          take_idle_waiters owner)
      in
      resolve_idle_waiters waiters;
      unsubscribe_commits ();
      unsubscribe_lane ();
      Stdlib.Mutex.protect owners_mutex (fun () -> Hashtbl.remove owners base_path));
    Eio.Fiber.fork_daemon ~sw (fun () ->
      let rec drain () =
        let next =
          Stdlib.Mutex.protect owner.mutex (fun () ->
            if owner.stopped then `Stop
            else if owner.pending then (
              owner.pending <- false;
              owner.in_flight <- true;
              `Run)
            else
              let promise, resolver = Eio.Promise.create () in
              owner.wake <- Some resolver;
              `Wait promise)
        in
        match next with
        | `Stop -> ()
        | `Wait promise ->
          Eio.Promise.await promise;
          drain ()
        | `Run ->
          (try
             let retry = ref false in
             let progressed =
               run_pass ~base_path ~owner ~on_observation_failure:(fun () -> retry := true)
             in
             Stdlib.Mutex.protect owner.mutex (fun () -> owner.observation_retry <- !retry);
             if progressed then ignore (wake owner)
           with
           | Eio.Cancel.Cancelled _ as error -> raise error
           | exn ->
             Stdlib.Mutex.protect owner.mutex (fun () -> owner.observation_retry <- true);
             Log.Server.error "workspace curator owner %s: %s" base_path (Printexc.to_string exn));
          let waiters =
            Stdlib.Mutex.protect owner.mutex (fun () ->
              owner.in_flight <- false;
              Hashtbl.clear owner.in_flight_revisions;
              if not owner.pending then owner.idle_checkpoint <- ref ();
              take_idle_waiters owner)
          in
          resolve_idle_waiters waiters;
          drain ()
      in
      drain ();
      `Stop_daemon))
;;

module For_testing = struct
  type nonrec idle_checkpoint = idle_checkpoint
  type nonrec idle_result = idle_result =
    | Owner_idle of idle_checkpoint
    | Owner_stopped
    | Owner_missing
  type snapshot =
    { pending : bool
    ; in_flight : bool
    ; observation_retry : bool
    ; stopped : bool
    ; idle_waiters : int
    }

  let find ~base_path =
    let base_path = realpath_offloaded base_path in
    Stdlib.Mutex.protect owners_mutex (fun () -> Hashtbl.find_opt owners base_path)
  ;;

  let is_idle ~base_path =
    match find ~base_path with
    | None -> true
    | Some owner ->
      Stdlib.Mutex.protect owner.mutex (fun () -> not owner.pending && not owner.in_flight)
  ;;

  let snapshot ~base_path =
    Option.map
      (fun (owner : owner) ->
         Stdlib.Mutex.protect owner.mutex (fun () ->
           { pending = owner.pending
           ; in_flight = owner.in_flight
           ; observation_retry = owner.observation_retry
           ; stopped = owner.stopped
           ; idle_waiters = List.length owner.idle_waiters
           }))
      (find ~base_path)
  ;;

  let await_idle ?after ~base_path () =
    Eio.Fiber.check ();
    match find ~base_path with
    | None -> Owner_missing
    | Some owner ->
      let promise, resolver = Eio.Promise.create () in
      let ready =
        Stdlib.Mutex.protect owner.mutex (fun () ->
          if owner.stopped then Some Owner_stopped
          else if
            not owner.pending
            && not owner.in_flight
            && match after with None -> true | Some previous -> previous != owner.idle_checkpoint
          then Some (Owner_idle owner.idle_checkpoint)
          else (
            owner.idle_waiters <- resolver :: owner.idle_waiters;
            None))
      in
      (match ready with
       | Some result -> result
       | None ->
         Fun.protect
           ~finally:(fun () ->
             Stdlib.Mutex.protect owner.mutex (fun () ->
               owner.idle_waiters <-
                 List.filter (fun waiter -> waiter != resolver) owner.idle_waiters))
           (fun () -> Eio.Promise.await promise))
  ;;

  let stop ~base_path =
    Option.iter
      (fun owner ->
         let resolver, waiters =
           Stdlib.Mutex.protect owner.mutex (fun () ->
             owner.stopped <- true;
             let resolver = owner.wake in
             owner.wake <- None;
             resolver, take_idle_waiters owner)
         in
         resolve_idle_waiters waiters;
         Option.iter (fun resolver -> Eio.Promise.resolve resolver ()) resolver)
      (find ~base_path)
  ;;
end
