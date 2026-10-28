module Capture = Keeper_librarian_admission_capture
module Owner = Lane_addon_tool_request_owner
module Progress = Lane_addon_request_progress
module Gate = Keeper_librarian_absorb_gate
module Gate_journal = Keeper_librarian_admission_gate
module Current = Keeper_memory_os_current
module Queue = Keeper_memory_admission_queue
module Exact = Lane_addon_exact
open Result.Syntax
let io f = Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ f
let owned result = Result.map_error Owner.error_to_string result
let require value detail = if value then Ok () else Error detail
let canonical = Lane_addon_action.canonical
let same left right =
  let* left=canonical left in let* right=canonical right in
  require (Yojson.Safe.equal left right) "Original admission commit identity differs"
type result = Committed of Owner.retained | Pending of string
let advance ~store record event =
  match Owner.advance ~store ~expected:record ~event with
  | Ok (Owner.Stored next) -> Ok (true,next)
  | Ok (Owner.Already_stored next) -> Ok (false,next)
  | Ok (Owner.Unconfirmed detail) -> Error detail
  | Error error -> Error (Owner.update_error_to_string error)
let receipt_json (id : Current.explicit_candidate_id) = `Assoc [
  "queue_generation",`String id.queue_generation;"request_id",`String id.request_id;
  "sequence",`Int id.sequence;"input_sha256",`String id.input_sha256]
let receipt_state ~keepers_dir ~keeper_id expected =
  let* first=match expected with [] -> Error "Accepted admission has no settled candidates"
    | first::_ -> Ok first in
  let* actual=Current.committed_explicit_candidates ~keepers_dir ~keeper_id
    ~queue_generation:first.Current.queue_generation in
  let* settled=List.fold_left (fun result (id : Current.explicit_candidate_id) ->
    let* count=result in
    let same_identity (other : Current.explicit_candidate_id) =
      other.request_id=id.request_id || other.sequence=id.sequence in
    match List.filter same_identity actual with
    | [] -> Ok count
    | [other] when other=id -> Ok (count+1)
    | _::_ -> Error "Committed candidate identity conflicts with the original admission") (Ok 0) expected in
  if settled=0 then Ok false
  else if settled=List.length expected then Ok true
  else Error "Original admission has a partial committed candidate receipt set"
let judgment record = match Progress.phase record.Owner.progress with
  | Progress.Judged judgment -> Ok judgment
  | Committing commit | Commit_unknown (commit,_) | Finished commit -> Ok commit.judgment
  | Captured | Admission_wait _ | Dispatch_pending _ | Conflicted _ | Rejected _
  | Subdividing _ | Subdivided _ -> Error "Original admission has no commit-capable answered judgment"
let live_owner owner =
  let* actual=Capture.observe_owner ~base_path:(Capture.base_path owner)
    ~keepers_dir:(Capture.keepers_dir owner) ~keeper_id:(Capture.keeper_id owner) in
  Capture.owner_matches_json actual (Capture.owner_to_json owner)
let receipt_marker (record : Owner.retained) ~gate_request_id accepted committed =
  canonical (`Assoc ["version",`Int 1;"kind",`String "librarian-admission-candidate-receipts";
    "execution_id",`String record.request_id;"execution_digest",`String record.request_digest;
    "gate_root_id",`String gate_request_id;"committed",`Bool committed;
    "candidates",`List (List.map receipt_json accepted.Keeper_librarian_runtime.explicit_candidate_ids)])
let validate ~store ~owner ~capture ~(record : Owner.retained) =
  let* ()=same record.request (Capture.to_json capture) in
  let* exact=Capture.request capture in
  let* schema=Option.to_result ~none:"Original admission has no output schema" exact.schema in
  let accepted judgment =
    let* final=Exact.final_of_json ~schema judgment in
    let* ()=Capture.confirm_final ~store capture final in
    match final with
    | Exact.Call_final (Answered {output;_}) -> Capture.validate_proposal capture (Exact.checked_json output)
    | Call_final (Invalid_output _ | Input_refused _ | Output_limit_reached _)
    | Outcome_unknown | Not_allowed _ | Request_id_reused -> Error "Original answered judgment contains a refusal" in
  match Progress.phase record.progress with
  | Progress.Captured | Admission_wait _ | Dispatch_pending _ -> Ok ()
  | Judged judgment ->
    let* _=accepted judgment in
    (match Progress.preparation record.progress with
     | Some (Preparation_pending _ | Preparation_confirmed _) ->
       Gate_journal.validate_root_preparation ~store ~owner ~capture
     | None ->
       let* root=Gate_journal.root ~store ~owner ~capture in
       require (Option.is_none root) "Original gate exists without its full parent preparation intent")
  | Committing commit | Commit_unknown (commit,_) | Finished commit ->
    let* ()=match Progress.preparation record.progress with
      | Some (Preparation_confirmed _) -> Gate_journal.validate_root_preparation ~store ~owner ~capture
      | None | Some (Preparation_pending _) -> Error "Memory disposition precedes original gate publication acknowledgement" in
    let* proposal=accepted commit.judgment in
    let* proposal=match proposal with
      | Keeper_librarian_runtime.Accepted accepted -> Ok accepted
      | Deferred -> Error "Semantic Deferred cannot retain a Memory commit intent" in
    let* gate_request_id=match commit.change.before with
      | `Assoc fields -> (match List.assoc_opt "gate_root_id" fields with
        | Some (`String id) when String.trim id<>"" -> Ok id
        | Some _ | None -> Error "Original commit marker lacks its original gate identity")
      | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
        Error "Original commit marker is not an object" in
    let* before=receipt_marker record ~gate_request_id proposal false in
    let* after=receipt_marker record ~gate_request_id proposal true in
    let* ()=same before commit.change.before in
    let* ()=same after commit.change.after in
    let* root=Gate_journal.root ~store ~owner ~capture in
    let* root=Option.to_result ~none:"Original commit gate root is absent" root in
    let* ()=require (root.Owner.request_id=gate_request_id) "Original commit gate root differs from its retained intent" in
    (match Progress.phase record.progress with
     | Progress.Finished _ ->
       let* latest=Gate_journal.latest ~store ~owner ~capture in
       let* latest=Option.to_result ~none:"Finished original gate chain is absent" latest in
       let* gate=Gate_journal.restore_size_evidence ~store ~owner ~parent_execution:capture
         ~gate_request_id:latest.request_id in
       let* ()=match Gate.failure_detail ~absorbed:proposal.selection.absorbed gate with
         | None -> Ok () | Some detail -> Error detail in
       let* settled=receipt_state ~keepers_dir:(Capture.keepers_dir owner)
         ~keeper_id:(Capture.keeper_id owner) proposal.explicit_candidate_ids in
       require settled "Finished original admission lacks actual committed candidate receipts"
     | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
     | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ -> Ok ())
  | Rejected {stage=Progress.Execution;evidence} ->
    let* retained=Exact.retained_final_of_json ~schema evidence in
    let final=Exact.delivered retained in
    let* ()=Capture.confirm_final ~store capture final in
    (match final with
     | Exact.Call_final (Answered _) -> Error "Original refusal contains an answered proposal"
     | Call_final (Invalid_output _ | Input_refused _ | Output_limit_reached _)
     | Outcome_unknown | Not_allowed _ | Request_id_reused -> Ok ())
  | Conflicted _ | Rejected {stage=Progress.Before_dispatch;_} | Subdividing _ | Subdivided _ ->
    Error "Original Librarian execution has an unsupported domain phase"
type preparation = Prepared of Owner.retained | Reload_original
let begin_gate ~store ~owner ~capture ~(record : Owner.retained) ~gate_root_id ~authority =
  io (fun () ->
    let* ()=live_owner owner in
    let* ()=same record.request (Capture.to_json capture) in
    let* ()=require (String.trim gate_root_id<>"") "Original gate root ID is blank" in
    let* original_judgment=judgment record in
    let* exact=Capture.request capture in
    let* schema=Option.to_result ~none:"Original admission has no schema" exact.schema in
    let* final=Exact.final_of_json ~schema original_judgment in
    let* ()=Capture.confirm_final ~store capture final in
    let* proposal=match final with
      | Exact.Call_final (Answered {output;_}) ->
        (match Capture.validate_proposal capture (Exact.checked_json output) with
         | Ok (Keeper_librarian_runtime.Accepted _) -> Ok (Exact.checked_json output)
         | Ok Deferred -> Error "Deferred admission cannot prepare an absorption disposition"
         | Error detail -> Error detail)
      | Call_final (Invalid_output _ | Input_refused _ | Output_limit_reached _)
      | Outcome_unknown | Not_allowed _ | Request_id_reused -> Error "Gate intent requires the original answered proposal" in
    let* intended=Gate_journal.prepare_root ~store ~owner ~capture ~parent:record ~proposal
      ~request_id:gate_root_id ~authority in
    let* fresh,record=advance ~store record (Progress.Preparation_intended intended) in
    Ok (if fresh then Prepared record else Reload_original))
let settle ~store ~owner ~capture ~(record : Owner.retained) ~gate_request_id =
  let keepers_dir=Capture.keepers_dir owner and keeper_id=Capture.keeper_id owner in
  let* current=io (fun () ->
    let* ()=live_owner owner in
    let* current=owned (Owner.load ~store ~scope:(Capture.scope owner) ~request_id:record.request_id) in
    let* current=Option.to_result ~none:"Original admission commit record is absent" current in
    let* ()=same (Capture.to_json capture) current.request in
    let* ()=same (Progress.to_json record.progress) (Progress.to_json current.progress) in
    let* ()=validate ~store ~owner ~capture ~record:current in
    Ok current) in
  let* original_judgment=judgment current in
  let* ()=match Progress.phase current.progress with
    | Progress.Judged _ | Committing _ | Commit_unknown _ | Finished _ -> Ok ()
    | Captured | Admission_wait _ | Dispatch_pending _ | Conflicted _ | Rejected _
    | Subdividing _ | Subdivided _ -> Error "Original gate has no retained disposition intent" in
  let* exact=Capture.request capture in
  let* schema=Option.to_result ~none:"Original admission has no output schema" exact.schema in
  let* final=Exact.final_of_json ~schema original_judgment in
  let* proposal=match final with
    | Exact.Call_final (Answered {output;_}) -> Ok (Exact.checked_json output)
    | Call_final (Invalid_output _ | Input_refused _ | Output_limit_reached _)
    | Outcome_unknown | Not_allowed _ | Request_id_reused -> Error "Commit requires an original answered proposal" in
  let* accepted=match Capture.validate_proposal capture proposal with
    | Ok (Keeper_librarian_runtime.Accepted accepted) -> Ok accepted
    | Ok Deferred -> Error "A semantic deferred admission cannot commit"
    | Error detail -> Error detail in
  let* gate=io (fun () -> Gate_journal.restore_size_evidence ~store ~owner
    ~parent_execution:capture ~gate_request_id) in
  let* ()=match Gate.failure_detail ~absorbed:accepted.selection.absorbed gate with
    | Some detail -> Error detail | None -> Ok () in
  let* root=io (fun () -> Gate_journal.root ~store ~owner ~capture) in
  let* root=Option.to_result ~none:"Original commit gate root is absent" root in
  let* before=receipt_marker current ~gate_request_id:root.Owner.request_id accepted false in
  let* after=receipt_marker current ~gate_request_id:root.Owner.request_id accepted true in
  let* ()=match Progress.phase current.progress with
    | Progress.Committing commit | Commit_unknown (commit,_) | Finished commit ->
      let* ()=same before commit.change.before in same after commit.change.after
    | Judged _ -> Ok ()
    | Captured | Admission_wait _ | Dispatch_pending _ | Conflicted _ | Rejected _
    | Subdividing _ | Subdivided _ -> Error "Invalid original commit phase" in
  let read_receipts ()=io (fun () -> let* ()=live_owner owner in
    receipt_state ~keepers_dir ~keeper_id accepted.explicit_candidate_ids) in
  let publish record event=io (fun () -> let* ()=live_owner owner in advance ~store record event) in
  let acknowledge record =
    let* ()=io (fun () ->
      let* ()=live_owner owner in
      let* committed=receipt_state ~keepers_dir ~keeper_id accepted.explicit_candidate_ids in
      let* ()=require committed "Original admission lacks its matching committed candidate receipts" in
      let* ()=Queue.acknowledge_committed ~keepers_dir ~keeper_id in
      let* pending=Queue.read_pending ~keepers_dir ~keeper_id in
      let remaining=Option.fold ~none:[] ~some:Queue.candidate_ids pending in
      require (not (List.exists (fun id -> List.mem id remaining) accepted.explicit_candidate_ids))
        "Original committed candidate ACK remains pending") in
    Ok (Committed record) in
  let confirm record =
    match Progress.phase record.Owner.progress with
    | Progress.Finished _ -> acknowledge record
    | Committing _ | Commit_unknown _ ->
      let* _new,record=publish record (Progress.Commit_observed after) in acknowledge record
    | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Conflicted _ | Rejected _
    | Subdividing _ | Subdivided _ -> Error "Original receipts precede a retained commit intent" in
  let apply record =
    let* absent=read_receipts () in
    if absent then confirm record else
    let source : Current.source={kind=Current.Librarian;
      trace_id=Ids.Turn_ref.trace_id (Capture.input capture).turn_ref} in
    let committed=ref None in
    let applied=io (fun () ->
      let* ()=live_owner owner in
      Current.apply_disposition ~on_committed:(fun disposition -> committed:=Some disposition)
        ~dropped_statements:accepted.selection.dropped
        ~explicit_candidate_ids:accepted.explicit_candidate_ids
        ~admission_recall:{decided_at_revision=Capture.expected_revision capture;
          bindings=accepted.admission_recall_bindings}
        ~required_memory_ids:accepted.required_memory_ids
        ~absorbed:(Gate.absorbed_of_run gate) ~revisions:accepted.selection.revisions
        ~keepers_dir ~keeper_id ~now:(Capture.now capture) ~source
        ~new_claims:(Gate.without_copies gate accepted.selection.new_claims) ()) in
    (* Secondary journal/unlock failure can follow snapshot publication. Only
       the same independently verified receipts settle the domain effect. *)
    let* proved=read_receipts () in
    if proved then (
      let ()=match !committed with
        | None -> ()
        | Some disposition ->
          io (fun () -> Keeper_memory_os_events.append_all ~keepers_dir ~keeper_id
            (List.map (fun (revision : Keeper_librarian.revision) : Keeper_memory_os_events.event ->
              {recorded_at=disposition.snapshot.updated_at;memory_id=revision.superseded;
                trace_id=source.trace_id;kind=Keeper_memory_os_events.Revised {superseded_by=revision.superseded_by}})
              disposition.revisions_applied))
          |> List.iter (fun error -> Log.Keeper.warn ~keeper_name:keeper_id "%s"
            (Keeper_memory_os_events.append_error_to_string error)) in
      confirm record)
    else
      let detail=match applied with
        | Error detail -> detail
        | Ok _ -> "Disposition returned without matching original candidate receipts" in
      let* _new,_record=publish record (Progress.Commit_uncertain (`Assoc ["detail",`String detail])) in
      Ok (Pending detail) in
  let* proved=read_receipts () in
  if proved then confirm current else
  match Progress.phase current.progress with
  | Progress.Finished _ -> Error "Finished admission no longer has authoritative candidate receipts"
  | Judged _ ->
    let* fresh,record=publish current (Progress.Commit_intended {before;after}) in
    if fresh then apply record else Ok (Pending "Reload original local disposition intent")
  | Committing _ ->
    (* A previous process may have stopped anywhere after its intent. Record
       uncertainty, then independently observe the complete absent receipt set. *)
    let* _new,record=publish current (Progress.Commit_uncertain (`Assoc ["detail",`String "Original local disposition requires receipt reconciliation"])) in
    let* proved=read_receipts () in
    if proved then confirm record else
    let* fresh,record=publish record (Progress.Commit_retry_observed before) in
    if fresh then apply record else Ok (Pending "Reload original local commit retry")
  | Commit_unknown _ ->
    let* fresh,record=publish current (Progress.Commit_retry_observed before) in
    if fresh then apply record else Ok (Pending "Reload original local commit retry")
  | Captured | Admission_wait _ | Dispatch_pending _ | Conflicted _ | Rejected _
  | Subdividing _ | Subdivided _ -> Error "Original admission cannot apply a disposition in this phase"
