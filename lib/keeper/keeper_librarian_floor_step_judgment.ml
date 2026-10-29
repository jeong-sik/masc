module Step = Keeper_librarian_floor_step_request
module Journal = Keeper_librarian_floor_step_gate
module Durable = Keeper_librarian_durable_request
module Owner = Lane_addon_tool_request_owner
module Progress = Lane_addon_request_progress
module Gate = Keeper_librarian_absorb_gate
module Memory_runtime = Keeper_librarian_runtime
let ( let* ) = Result.bind
let io f = Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ f
let owned result = Result.map_error Owner.error_to_string result
type result = Pending of string | Decided of Memory_runtime.memory_step
let advance ~store record event =
  match Owner.advance ~store ~expected:record ~event with
  | Ok (Owner.Stored record | Already_stored record) -> Ok record
  | Ok (Unconfirmed detail) -> Error detail
  | Error error -> Error (Owner.update_error_to_string error)
(* The record as it stands now; [previous] carries the body an earlier load
   verified, so only the record is read again. *)
let reload ~store ~previous step =
  let* () = Step.confirm_owner step in
  let* record = owned (Owner.reload ~store previous) in
  let* record = Option.to_result ~none:"Original floor step record is absent" record in
  let* () = Step.confirm_record step record in
  Ok record
type preparation = Ready of Owner.retained | Unavailable of string
(* The gate's root is the one record of this step's judgment, and it never
   changes, so it names the decision on every replay. *)
let decide ~step ~(answer : Keeper_librarian_floor_step_owner.answer) ~(root : Owner.retained) gate =
  match Memory_runtime.durable_memory_step ~run_id:root.request_id (Step.step step) answer.proposal
          ~absorb_gate:gate with
  | Ok decision -> Ok (Decided decision)
  | Error detail -> Error detail
(* The gate of a step whose journal [inventory] shows complete and successful.
   An earlier pass wrote that journal and nothing in this pass changes it, so
   the one read of the scope that built [inventory] answers for every such step.
   Reading the scope again for each step is what made a pass cost the square of
   the chain's length. A step in any other state gets [None] and takes the
   fresh-read path of [judge_by_fresh_reads], which also recovers, retries and
   dispatches. *)
let settled ~inventory ~step ~record ~absorbed =
  match Journal.Inventory.validate inventory ~capture:step ~parent:record with
  | Error _ -> None
  | Ok chain ->
    (match Journal.Inventory.validate_root_preparation chain, Journal.Inventory.root chain,
           Journal.Inventory.latest chain with
     | Ok (), Some root, Ok (Some latest) ->
       (match Journal.Inventory.restore_size_evidence chain ~gate_request_id:latest.Owner.request_id with
        | Ok gate when Option.is_none (Gate.failure_detail ~absorbed gate) -> Some (root, gate)
        | Ok _ | Error _ -> None)
     | Ok (), None, _ | Ok (), Some _, (Ok None | Error _) | Error _, _, _ -> None)
(* The gate part of [Keeper_librarian_durable_commit.publish], for a record that
   stays at its judgment: prepare the gate's root once, recover what a crash
   left half published, run or replay the journal, and retry a failed
   evaluation with a new attempt. A completed journal replays from its retained
   evaluations; nothing is asked of the model or recomputed from the Memory of
   the moment. *)
let judge_by_fresh_reads ~store ~step ~(record : Owner.retained)
    ~(answer : Keeper_librarian_floor_step_owner.answer) ~fresh_authority =
  let owner = Step.physical_owner step in
  let keeper_id = Durable.keeper_id owner in
  let raw = answer.raw in
  let absorbed = answer.proposal.proposal.accepted.selection.absorbed in
  let pending detail = Ok (Pending detail) in
  let prepare current =
    match Progress.preparation current.Owner.progress with
    | Some (Progress.Preparation_pending _ | Preparation_confirmed _) -> Ok (Ready current)
    | None ->
      (match fresh_authority () with
       | Error detail -> Ok (Unavailable detail)
       | Ok () ->
         let authority = Gate.resolve ~keeper_id in
         let* current = io (fun () ->
           let* () = Step.confirm_owner step in
           let* intended = Journal.prepare_root ~store ~owner ~capture:step ~parent:current ~proposal:raw
             ~request_id:(Random_id.uuid_v7 ()) ~authority in
           advance ~store current (Progress.Preparation_intended intended)) in
         Ok (Ready current)) in
  (* Absence of a live configured destination suspends creation, never turns an
     old intent into a new ID. Existing full intents recover locally while Off. *)
  let* prepared = prepare record in
  match prepared with
  | Unavailable detail -> pending detail
  | Ready _ ->
    let* current, root, latest = io (fun () ->
      let* _ = Journal.recover_root ~store ~owner ~capture:step in
      let* () = Journal.recover_retries ~store ~owner ~capture:step in
      let* current = reload ~store ~previous:record step in
      let* root = Journal.root ~store ~owner ~capture:step in
      let* root = Option.to_result ~none:"Original floor step gate root is absent" root in
      let* latest = Journal.latest ~store ~owner ~capture:step in
      let* latest = Option.to_result ~none:"Original floor step gate leaf is absent" latest in
      Ok (current, root, latest)) in
    let live_authority = match fresh_authority () with
      | Ok () -> Some (Gate.resolve ~keeper_id)
      | Error _ -> None in
    let* prior_complete = match Progress.phase latest.progress with
      | Progress.Judged _ | Rejected {stage=Progress.Execution;_} ->
        let* gate = io (fun () -> Journal.restore_size_evidence ~store ~owner ~parent_execution:step
          ~gate_request_id:latest.request_id) in
        Ok (Some gate)
      | Captured | Dispatch_pending _ -> Ok None
      | Admission_wait _ | Committing _ | Commit_unknown _ | Finished _ | Conflicted _
      | Rejected {stage=Progress.Before_dispatch;_} | Subdividing _ | Subdivided _ ->
        Error "Original floor step gate has an unsupported runnable phase" in
    let* next = match prior_complete, live_authority with
      | Some gate, Some authority ->
        (match Gate.failure_detail ~absorbed gate, Gate.failure_kind gate with
         | Some _, (Some Gate.Evaluation_failed | None) ->
           let* () = fresh_authority () in
           io (fun () -> Journal.retain ~store ~owner ~capture:step ~parent:current ~proposal:raw
             ~request_id:(Random_id.uuid_v7 ()) ~authority ~predecessor:(Some latest.request_id))
         | Some _, Some Input_capacity_exceeded | None, (Some Input_capacity_exceeded | Some Evaluation_failed | None) ->
           Ok latest)
      | None, (None | Some _) | Some _, None -> Ok latest in
    let* result = Journal.resume ~store ~owner ~capture:step ~record:next ~live_authority
      ~before_dispatch:fresh_authority in
    (match result with
     | Journal.Pending _ -> pending "Original floor step absorption judgment is pending"
     | Complete (gate, _) ->
       (match Gate.failure_detail ~absorbed gate with
        | Some detail -> pending detail
        | None -> decide ~step ~answer ~root gate))
let judge ~store ~step ~(record : Owner.retained) ~(answer : Keeper_librarian_floor_step_owner.answer)
    ~fresh_authority ~inventory =
  let absorbed = answer.proposal.proposal.accepted.selection.absorbed in
  match settled ~inventory ~step ~record ~absorbed with
  | Some (root, gate) -> decide ~step ~answer ~root gate
  | None -> judge_by_fresh_reads ~store ~step ~record ~answer ~fresh_authority
