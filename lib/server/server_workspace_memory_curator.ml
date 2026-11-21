module Context = Workspace_memory_context
module Ledger = Workspace_memory_ledger
module Request = Workspace_memory_request
module Decision = Workspace_memory_decision
module Briefing = Workspace_memory_briefing
module Log_store = Workspace_memory_log
module Exact = Agent_core.Exact_output
module Registry = Runtime_exact_output_registry
module Slots = Exact_lane_slots
module Narrowing = Workspace_memory_narrowing
module Briefing_narrowing = Workspace_memory_briefing_narrowing
module Outcome = Exact_lane_slot_outcome
module Visit = Exact_lane_slot_visit
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

type lane_standing =
  | Not_published of Registry.publication_error
  | Not_resolved of Registry.lane_resolution_error
  | Replacement_in_progress

let lane_standing_to_string = function
  | Not_published err -> Registry.publication_error_to_string err
  | Not_resolved err -> Registry.lane_resolution_error_to_string err
  | Replacement_in_progress -> "exact-output registry replacement in progress"
;;

type lane_resolve_outcome =
  | Lane_ready of resolved_lane_execution
  | Lane_unready of lane_standing

(* The curator's own table. The Librarian's Memory lane starts no curator
   call: the two share no declaration, slot order or limit evidence. *)
let lane_id = Standalone_lane.to_id Standalone_lane.Workspace_memory_curator

let resolve_lane_execution () =
  match Registry.current () with
  | Error Registry.Publication_busy -> Lane_unready Replacement_in_progress
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
       | Targets_refused _ ) as err) -> Lane_unready (Not_published err)
  | Ok registry ->
    (match Registry.resolve_lane registry ~lane_id with
     | Ok resolved ->
       let generation = Registry.catalog_generation_fingerprint registry in
       Lane_ready { generation; resolved }
     | Error err -> Lane_unready (Not_resolved err))
;;

let flow_detail cause =
  Exact.flow_execution_error_to_string
    ~callback_error_to_string:no_callback_error_to_string
    ~raw_response_to_string:raw_excerpt
    cause
;;

let stop_detail : ('rejection, no_callback_error) Slots.stop -> string = function
  | Http_unstartable { slot_id; reason } -> slot_id ^ ": " ^ reason
  | Http_stopped { slot_id = _; error = Flow_execution_terminal { cause; prior_rejections = _ } } ->
    flow_detail cause
  | Http_stopped { slot_id; error = Flow_semantic_candidates_exhausted _ } ->
    slot_id ^ ": every answer was rejected"
  | Record_failed _ -> .
;;

(* One walk over [slots], HTTP and CLI alike
   (RFC exact-lane-walks-one-slot-list). *)
let walk_slots ~base_path ~schema ~rendered_prompt ~validate slots =
  match Eio_context.get_net_opt (), Eio_context.get_clock_opt () with
  | None, _ | _, None -> Error "server Eio net/clock context unavailable"
  | Some net, Some clock ->
    let proceed _ : (unit, no_callback_error) result =
      Eio.Fiber.check ();
      Ok ()
    in
    Ok
      (Slots.walk
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
         slots)
;;

(* Why the curator could not use the body a slot sent. The decoder's reason
   is shown only. *)
type rejection =
  | Decision_refused of string  (* the classification's decoder *)
  | Briefing_refused of string  (* the briefing's decoder *)
  | Empty_or_partial
  | Not_json

let bodies : rejection Visit.bodies =
  { Visit.empty_or_partial = Empty_or_partial; not_json = Not_json }
;;

(* What one slot said to a classification request, as the curator reads the
   slot outcome table (RFC curator-narrows-a-refused-batch-and-sets-a-refused-
   fact-aside §4.1). *)
let word : rejection Outcome.unanswered -> Narrowing.word = function
  | Outcome.Refused
      (Outcome.Sized (Outcome.Input_too_large | Outcome.Output_over_reserve | Outcome.Window_reached))
    -> Narrowing.Sized
  | Outcome.Refused Outcome.Unsized -> Narrowing.Unsized
  | Outcome.Silent (Outcome.Unusable (_ : rejection)) -> Narrowing.Unusable
  | Outcome.Silent Outcome.Overdue -> Narrowing.Overdue
  | Outcome.Silent (Outcome.Not_called | Outcome.Unavailable | Outcome.Busy | Outcome.Lost) ->
    Narrowing.Quiet
;;

(* What one slot said to a briefing request (RFC curator §4.5). The table is
   read as for a classification request, except that the output limit does
   not narrow: a request of fewer entries is not known to give a shorter
   briefing. *)
let briefing_word : rejection Outcome.unanswered -> Briefing_narrowing.word = function
  | Outcome.Refused (Outcome.Sized Outcome.Output_over_reserve) -> Briefing_narrowing.Output_limit
  | Outcome.Refused
      (Outcome.Sized (Outcome.Input_too_large | Outcome.Window_reached) | Outcome.Unsized) ->
    Briefing_narrowing.Refused
  | Outcome.Silent (Outcome.Unusable (_ : rejection)) -> Briefing_narrowing.Unusable
  | Outcome.Silent Outcome.Overdue -> Briefing_narrowing.Overdue
  | Outcome.Silent (Outcome.Not_called | Outcome.Unavailable | Outcome.Busy | Outcome.Lost) ->
    Briefing_narrowing.Quiet
;;

(* What each slot a walk passed said, by the id the lane declares it by, in
   the stage's [word]. [Error] is a flow that ended on masc's own failure
   ({!Visit.of_passed}). *)
let heard ~word passed =
  let rec read said = function
    | [] -> Ok (List.rev said)
    | one :: rest ->
      (match Visit.of_passed one with
       | Error stopped -> Error stopped
       | Ok (Visit.Http_visit (slot, http)) ->
         read ((slot, word (Visit.classify_unanswered bodies (Visit.Http http))) :: said) rest
       | Ok (Visit.Cli_visit (slot, cli)) ->
         read ((slot, word (Visit.classify_unanswered bodies (Visit.Cli cli))) :: said) rest)
  in
  read [] passed
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

(* The step of a classification pass at which masc itself failed. *)
type host_step =
  | Reading
  | Preparing
  | Walking
  | Recording
  | Deciding

let host_step_to_string = function
  | Reading -> "reading the Keepers' stores and the ledger"
  | Preparing -> "preparing the request"
  | Walking -> "walking the lane"
  | Recording -> "recording the answer"
  | Deciding -> "deciding the next request"
;;

(* How a classification pass ended (RFC curator §4.6). *)
type step_end =
  | Nothing_pending
  | Not_asked of lane_standing
  | Drained
  | Lane_silent
  | Host_failed of host_step * string

(* Whether the maintenance tick wakes the owner after the pass (RFC curator
   §4.4). A lane with no table, or one turned off, waits for its lane
   change. *)
let awaits_tick = function
  | Nothing_pending | Drained | Not_asked (Not_published _ | Not_resolved _) -> false
  | Lane_silent | Not_asked Replacement_in_progress | Host_failed _ -> true
;;

(* [pending] is why the next pass runs; two wakes before one pass combine.
   [memory] is the classification's narrowing memory: what it narrowed, which
   slots refused a fact alone, which facts wait for the tick, and the kept
   size. [briefing] is the request the briefing waits at and the slots that
   refused it. [requests] counts the asks to start over the owner took. *)
type owner =
  { mutex : Stdlib.Mutex.t
  ; mutable pending : Narrowing.wake option
  ; mutable in_flight : bool
  ; mutable stopped : bool
  ; mutable observation_retry : bool
  ; mutable wake : unit Eio.Promise.u option
  ; mutable idle_checkpoint : idle_checkpoint
  ; mutable idle_waiters : idle_result Eio.Promise.u list
  ; mutable memory : Narrowing.memory
  ; mutable briefing : Briefing_narrowing.memory
  ; mutable requests : int
  ; mutable classification : step_end option
  ; in_flight_revisions : (string * Keeper_memory_commit_notifications.store, int) Hashtbl.t
  }

(* How a briefing pass ended (RFC curator §4.5). *)
type briefing_end =
  | Briefing_moved
  (* A chunk was published or the state cleaned up: the owner runs again for
     the next chunk. *)
  | Briefing_idle
  (* Nothing to brief, no table for the lane or the lane off, or a new
     generation started during the pass. *)
  | Briefing_stands  (* Every slot refused the request the briefing waits at. *)
  | Briefing_waits
  (* A slot that has not refused the request is asked on the tick, or the
     registry is being replaced. *)
  | Briefing_failed of string  (* masc's own failure. The text is shown only. *)

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
    Ok (context, initial_detailed.reconciliation)
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
    if detailed.reconciliation.vanished <> [] then
      Mcp_server_eio_resource.notify_world_memory_updated ();
    Ok (context, { detailed.reconciliation with ledger = updated_ledger })
;;

(* Write a classification answer into the ledger and its log. Gives the
   ledger the answer went into, which the pass's next request is made from. *)
let record_answer ~base_path ~(batch : Request.batch) assignments =
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
        Ok (applied_ledger, log_entries_of_assignments ~ledger:applied_ledger assignments)))
;;

(* One classification pass (RFC curator §4.1 to §4.4). The owner's memory
   names each request and reads what the slots said; the pass asks until the
   memory names none. A failure of masc's own ends the pass: what the memory
   took so far stays, and the requests the pass had not asked are made again
   by the next pass. *)
let classify ~base_path ~(owner : owner) ~woken_by ~context
    ~(reconciliation : Ledger.reconciliation) (lane : resolved_lane_execution) =
  let slots = Slots.of_resolved_lane lane.resolved in
  let pending_of =
    List.fold_left
      (fun map (fact : Ledger.pending_fact) -> Ledger.Fact_map.add fact.fact fact map)
      Ledger.Fact_map.empty
      reconciliation.new_facts
  in
  let pass =
    Stdlib.Mutex.protect owner.mutex (fun () ->
      let memory, pass =
        Narrowing.start
          owner.memory
          ~generation:{ Narrowing.lane = lane.generation; requests = owner.requests }
          ~slots:(List.map Slots.id slots)
          ~wake:woken_by
          ~pending:
            (List.map (fun (fact : Ledger.pending_fact) -> fact.fact) reconciliation.new_facts)
      in
      owner.memory <- memory;
      pass)
  in
  let resolution = Prompt_registry.resolve_prompt Prompt_names.workspace_memory_curator in
  let render input =
    Prompt_registry.render_resolved_prompt_template
      Prompt_names.workspace_memory_curator
      resolution
      [ "workspace_memory_changes", Yojson.Safe.to_string input ]
  in
  let neighbor_limit = max 0 (List.length (Context.keepers context) - 1) in
  let decide step =
    Stdlib.Mutex.protect owner.mutex (fun () ->
      match step owner.memory with
      | Ok (memory, pass) ->
        owner.memory <- memory;
        Ok pass
      | Error err -> Error (Deciding, Narrowing.error_to_string err))
  in
  let rec ask ledger pass =
    match Stdlib.Mutex.protect owner.mutex (fun () -> Narrowing.next owner.memory pass) with
    | None -> Ok ()
    | Some (request : Narrowing.request) ->
      let pending =
        List.filter_map (fun fact -> Ledger.Fact_map.find_opt fact pending_of) request.facts
      in
      (match
         Request.prepare
           ~neighbor_limit
           ~render
           ~ledger
           ~current:reconciliation.current_facts
           ~pending
           ~size:request.size
           ~frame:max_int
           ~measure:(fun batch -> Ok (String.length batch.rendered_prompt))
       with
       | Error err -> Error (Preparing, Request.error_to_string err)
       | Ok None -> Error (Preparing, "the request named no pending fact")
       | Ok (Some batch) ->
         let sent = List.map (fun (fact : Ledger.pending_fact) -> fact.fact) batch.selected in
         (match
            walk_slots
              ~base_path
              ~schema:Decision.output_schema
              ~rendered_prompt:batch.rendered_prompt
              ~validate:(fun json ->
                Decision.decode ~batch json
                |> Result.map_error (fun reason -> Decision_refused reason))
              (List.filter (fun slot -> List.mem (Slots.id slot) request.slots) slots)
          with
          | Error detail -> Error (Walking, detail)
          | Ok (Answered { slot = _; value; passed = _ }) ->
            let assignments =
              match value with
              | Http_answered { slot_id = _; success } -> success.accepted
              | Cli_answered { runtime_id = _; accepted } -> accepted
            in
            (match record_answer ~base_path ~batch assignments with
             | Error detail -> Error (Recording, detail)
             | Ok ledger ->
               Mcp_server_eio_resource.notify_world_memory_updated ();
               let* pass = decide (fun memory -> Narrowing.answered memory pass ~sent) in
               ask ledger pass)
          | Ok (Exhausted { passed; standing = _ }) ->
            (match heard ~word passed with
             | Error stopped -> Error (Walking, flow_detail stopped)
             | Ok said ->
               let* pass =
                 decide (fun memory -> Narrowing.unanswered memory pass ~sent ~heard:said)
               in
               ask ledger pass)
          | Ok (Stopped { slot = _; stop; passed = _ }) -> Error (Walking, stop_detail stop)))
  in
  match ask reconciliation.ledger pass with
  | Error (step, detail) -> Host_failed (step, detail)
  | Ok () ->
    if Stdlib.Mutex.protect owner.mutex (fun () -> Narrowing.waiting owner.memory)
    then Lane_silent
    else Drained
;;

let run_classification ~base_path ~(owner : owner) ~woken_by =
  match run_reconciliation ~base_path with
  | Error detail -> Host_failed (Reading, detail)
  | Ok (context, reconciliation) ->
    (match reconciliation.new_facts with
     | [] -> Nothing_pending
     | _ :: _ ->
       (match resolve_lane_execution () with
        | Lane_unready standing -> Not_asked standing
        | Lane_ready lane -> classify ~base_path ~owner ~woken_by ~context ~reconciliation lane))
;;

(* Accept a slot's briefing for [batch] and write it with its log entry. *)
let publish ~base_path ~directory batch ~text =
  match Briefing.accept batch ~text with
  | Error detail -> Briefing_failed detail
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
       Briefing_moved
     | Error detail -> Briefing_failed detail)
;;

(* Ask the request the briefing memory names for the prepared batch, and
   narrow it as the slots say, until a slot answers or the briefing waits
   (RFC curator §4.5). A failure of masc's own ends the pass and writes
   nothing into the memory. *)
let brief ~base_path ~(owner : owner) ~woken_by ~directory ~render
    (lane : resolved_lane_execution) prepared =
  let slots = Slots.of_resolved_lane lane.resolved in
  let ids = List.map Slots.id slots in
  let generation, first =
    Stdlib.Mutex.protect owner.mutex (fun () ->
      let generation = { Narrowing.lane = lane.generation; requests = owner.requests } in
      let memory, first =
        Briefing_narrowing.start
          owner.briefing
          ~generation
          ~slots:ids
          ~wake:woken_by
          ~keys:(Briefing.selected_keys prepared)
      in
      owner.briefing <- memory;
      generation, first)
  in
  let validate json =
    Briefing.decode_output json |> Result.map_error (fun reason -> Briefing_refused reason)
  in
  let decide sent said =
    Stdlib.Mutex.protect owner.mutex (fun () ->
      match Briefing_narrowing.unanswered owner.briefing ~generation ~sent ~heard:said with
      | Error err -> Error err
      | Ok (memory, decided) ->
        owner.briefing <- memory;
        Ok decided)
  in
  let rec ask batch asked =
    match
      walk_slots
        ~base_path
        ~schema:Briefing.output_schema
        ~rendered_prompt:(Briefing.rendered_prompt batch)
        ~validate
        (List.filter (fun slot -> List.mem (Slots.id slot) asked) slots)
    with
    | Error detail -> Briefing_failed detail
    | Ok (Answered { slot = _; value; passed = _ }) ->
      let text =
        match value with
        | Http_answered { slot_id = _; success } -> success.accepted
        | Cli_answered { runtime_id = _; accepted } -> accepted
      in
      Stdlib.Mutex.protect owner.mutex (fun () ->
        owner.briefing <- Briefing_narrowing.answered owner.briefing ~generation);
      publish ~base_path ~directory batch ~text
    | Ok (Exhausted { passed; standing = _ }) ->
      (match heard ~word:briefing_word passed with
       | Error stopped -> Briefing_failed (flow_detail stopped)
       | Ok said ->
         (match decide (Briefing.selected_keys batch) said with
          | Error err -> Briefing_failed (Briefing_narrowing.error_to_string err)
          | Ok Briefing_narrowing.Narrow ->
            (match Briefing.narrow ~render batch with
             | Error detail -> Briefing_failed detail
             | Ok (Some half) -> ask half ids
             | Ok None -> Briefing_failed "the briefing narrowed a request of one entry")
          | Ok Briefing_narrowing.Waits -> Briefing_waits
          | Ok Briefing_narrowing.Stands ->
            Log.Server.warn
              "workspace curator briefing waits at %d entries every slot refused"
              (Briefing.selected_count batch);
            Briefing_stands
          | Ok Briefing_narrowing.Moved -> Briefing_idle))
    | Ok (Stopped { slot = _; stop; passed = _ }) -> Briefing_failed (stop_detail stop)
  in
  match first with
  | Briefing_narrowing.Stand -> Briefing_stands
  | Briefing_narrowing.Wait -> Briefing_waits
  | Briefing_narrowing.Ask { count; slots = asked } ->
    (match Briefing.select ~render prepared ~count with
     | Error detail -> Briefing_failed detail
     | Ok batch -> ask batch asked)
;;

let run_briefing ~base_path ~owner ~woken_by =
  let directory = Ledger.directory ~base_path in
  match
    io (fun () ->
      let* ledger = Ledger.load ~base_path in
      let* state = Briefing.load ~directory in
      Ok (ledger, state))
  with
  | Error detail -> Briefing_failed detail
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
    (match Briefing.prepare ~sources ~contract ~render state with
     | Error detail -> Briefing_failed detail
     | Ok Briefing.Unchanged -> Briefing_idle
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
        | Error detail -> Briefing_failed detail
        | Ok _ ->
          (match !step with
           | None | Some Briefing.Unchanged -> Briefing_idle
           | Some (Briefing.Cleanup _) ->
             Mcp_server_eio_resource.notify_world_memory_updated ();
             Briefing_moved
           | Some (Briefing.Prepared batch) ->
             (match resolve_lane_execution () with
              | Lane_unready (Replacement_in_progress as standing) ->
                Log.Server.debug
                  "workspace curator briefing deferred: %s"
                  (lane_standing_to_string standing);
                Briefing_waits
              | Lane_unready ((Not_published _ | Not_resolved _) as standing) ->
                Log.Server.debug
                  "workspace curator briefing lane unavailable: %s"
                  (lane_standing_to_string standing);
                Briefing_idle
              | Lane_ready lane -> brief ~base_path ~owner ~woken_by ~directory ~render lane batch))))
;;

(* One pass: classification, then the briefing. Gives whether the briefing
   moved, so the owner runs again for its next chunk, and whether the
   maintenance tick is to wake the owner. A classification pass asks every
   request it has, so it does not run the owner again. A briefing that every
   slot refused waits for a new generation or a change of its entries, not
   for the tick. *)
let run_pass ~base_path ~(owner : owner) ~woken_by =
  let classified = run_classification ~base_path ~owner ~woken_by in
  (match classified with
   | Host_failed (step, detail) ->
     Log.Server.error
       "workspace curator classification failed %s: %s"
       (host_step_to_string step)
       detail
   | Not_asked standing ->
     Log.Server.debug
       "workspace curator classification not asked: %s"
       (lane_standing_to_string standing)
   | Nothing_pending | Drained | Lane_silent -> ());
  Stdlib.Mutex.protect owner.mutex (fun () -> owner.classification <- Some classified);
  let briefed, briefing_retry =
    match run_briefing ~base_path ~owner ~woken_by with
    | Briefing_moved -> true, false
    | Briefing_idle | Briefing_stands -> false, false
    | Briefing_waits -> false, true
    | Briefing_failed detail ->
      Log.Server.error "workspace curator briefing: %s" detail;
      false, true
  in
  briefed, awaits_tick classified || briefing_retry
;;

(* The caller holds [owner.mutex]. Resolving promises happens after releasing
   it: an idle observation is not a lease against a subsequent wake. *)
let take_idle_waiters owner =
  if owner.stopped || (Option.is_none owner.pending && not owner.in_flight) then (
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

(* The caller holds [owner.mutex]. A wake queued before the pass runs combines
   with this one (RFC curator §4.4). *)
let queue owner (reason : Narrowing.wake) =
  owner.pending
  <- Some
       (match owner.pending with
        | None -> reason
        | Some queued -> Narrowing.combine_wake queued reason)
;;

(* Five paths wake the owner: a Keeper Memory commit, a change of its lane, an
   ask to start over, the maintenance tick, and a briefing that moved. Only the
   tick is [Tick]. *)
let wake owner reason =
  let queued, resolver =
    Stdlib.Mutex.protect owner.mutex (fun () ->
      if owner.stopped then false, None
      else (
        queue owner reason;
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
        queue owner Narrowing.Commit;
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
       (* A new generation (RFC curator §4.3): both memories start empty, and
          a pass in flight writes nothing more. *)
       Stdlib.Mutex.protect owner.mutex (fun () ->
         owner.requests <- owner.requests + 1;
         owner.memory <- Narrowing.restart owner.memory ~requests:owner.requests;
         owner.briefing <- Briefing_narrowing.restart owner.briefing ~requests:owner.requests);
       wake owner Narrowing.Commit)
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
       if pending then ignore (wake owner Narrowing.Tick))
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
    ; pending = Some Narrowing.Commit
    ; in_flight = false
    ; stopped = false
    ; observation_retry = false
    ; wake = None
    ; idle_checkpoint = ref ()
    ; idle_waiters = []
      (* No lane is read yet: the first pass's lane generation differs and
         starts the memory over. *)
    ; memory = Narrowing.empty { Narrowing.lane = ""; requests = 0 } ~slots:[]
    ; briefing = Briefing_narrowing.empty { Narrowing.lane = ""; requests = 0 } ~slots:[]
    ; requests = 0
    ; classification = None
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
        ignore (wake owner Narrowing.Commit))
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
            else
              match owner.pending with
              | Some woken_by ->
                owner.pending <- None;
                owner.in_flight <- true;
                `Run woken_by
              | None ->
                let promise, resolver = Eio.Promise.create () in
                owner.wake <- Some resolver;
                `Wait promise)
        in
        match next with
        | `Stop -> ()
        | `Wait promise ->
          Eio.Promise.await promise;
          drain ()
        | `Run woken_by ->
          (try
             let progressed, retry = run_pass ~base_path ~owner ~woken_by in
             Stdlib.Mutex.protect owner.mutex (fun () -> owner.observation_retry <- retry);
             if progressed then ignore (wake owner Narrowing.Commit)
           with
           | Eio.Cancel.Cancelled _ as error -> raise error
           | exn ->
             Stdlib.Mutex.protect owner.mutex (fun () -> owner.observation_retry <- true);
             Log.Server.error "workspace curator owner %s: %s" base_path (Printexc.to_string exn));
          let waiters =
            Stdlib.Mutex.protect owner.mutex (fun () ->
              owner.in_flight <- false;
              Hashtbl.clear owner.in_flight_revisions;
              if Option.is_none owner.pending then owner.idle_checkpoint <- ref ();
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
    ; classification : step_end option
    ; set_aside : Ledger.fact_ref list
    }

  let find ~base_path =
    let base_path = realpath_offloaded base_path in
    Stdlib.Mutex.protect owners_mutex (fun () -> Hashtbl.find_opt owners base_path)
  ;;

  let is_idle ~base_path =
    match find ~base_path with
    | None -> true
    | Some (owner : owner) ->
      Stdlib.Mutex.protect owner.mutex (fun () ->
        Option.is_none owner.pending && not owner.in_flight)
  ;;

  let snapshot ~base_path =
    Option.map
      (fun (owner : owner) ->
         Stdlib.Mutex.protect owner.mutex (fun () ->
           { pending = Option.is_some owner.pending
           ; in_flight = owner.in_flight
           ; observation_retry = owner.observation_retry
           ; stopped = owner.stopped
           ; idle_waiters = List.length owner.idle_waiters
           ; classification = owner.classification
           ; set_aside = Narrowing.set_aside owner.memory
           }))
      (find ~base_path)
  ;;

  let await_idle ?after ~base_path () =
    Eio.Fiber.check ();
    match find ~base_path with
    | None -> Owner_missing
    | Some (owner : owner) ->
      let promise, resolver = Eio.Promise.create () in
      let ready =
        Stdlib.Mutex.protect owner.mutex (fun () ->
          if owner.stopped then Some Owner_stopped
          else if
            Option.is_none owner.pending
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
