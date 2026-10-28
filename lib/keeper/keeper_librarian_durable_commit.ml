module Request = Keeper_librarian_durable_request
module Source = Keeper_librarian_durable_capture
module Owner = Lane_addon_tool_request_owner
module Progress = Lane_addon_request_progress
module Exact = Lane_addon_exact
module Gate = Keeper_librarian_absorb_gate
module Journal = Keeper_librarian_durable_gate
module Current = Keeper_memory_os_current
module Memory_types = Keeper_memory_os_types
module Cursor = Keeper_external_read_cursor
module Atom = Keeper_librarian_progress
module Official = Keeper_librarian_official_progress
module Publication = Keeper_librarian_durable_owner
open Result.Syntax
let io f = Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ f
let require condition detail = if condition then Ok () else Error detail
let same left right =
  let* left=Lane_addon_action.canonical left in
  let* right=Lane_addon_action.canonical right in
  require (Yojson.Safe.equal left right) "Original completed-history publication differs"
let owned result = Result.map_error Owner.error_to_string result
let advance ~store record event =
  match Owner.advance ~store ~expected:record ~event with
  | Ok (Owner.Stored record) -> Ok (true,record)
  | Ok (Already_stored record) -> Ok (false,record)
  | Ok (Unconfirmed detail) -> Error detail
  | Error error -> Error (Owner.update_error_to_string error)
let judgment (record : Owner.retained) = match Progress.phase record.progress with
  | Progress.Judged value -> Ok value
  | Committing commit | Commit_unknown (commit,_) | Finished commit | Conflicted (commit,_) -> Ok commit.judgment
  | Captured | Admission_wait _ | Dispatch_pending _ | Rejected _
  | Subdividing _ | Subdivided _ -> Error "History publication has no answered original judgment"
(* The record as it stands now. [previous] carries the body an earlier load
   verified, so only the record is read again; [Request.confirm_record] checks
   that it still names this request. *)
let reload ~store ~previous request =
  let* ()=Request.confirm_owner request in
  let* record=owned (Owner.reload ~store previous) in
  let* record=Option.to_result ~none:"Original history publication record is absent" record in
  let* ()=Request.confirm_record request record in
  Ok record
let original_answer ~store request record =
  let* value=judgment record in
  let* exact=Request.request request in
  let* schema=Option.to_result ~none:"Original history request has no output schema" exact.schema in
  let* final=Exact.final_of_json ~schema value in
  let* ()=Request.confirm_final ~store request final in
  match final with
  | Exact.Call_final (Answered {output;_}) ->
    let raw=Exact.checked_json output in
    let* proposal=Request.validate_proposal request raw in
    Ok (raw,proposal)
  | Call_final (Invalid_output _ | Input_refused _ | Output_limit_reached _)
  | Outcome_unknown | Not_allowed _ | Request_id_reused ->
    Error "History publication requires its actual answered original host result"
(* A range the message floor published carries the messages it could not read
   in its receipt identity; the original names none. The range is the same. *)
let same_atom_range (expected : Current.durable_range_id) (actual : Current.durable_range_id) =
  Yojson.Safe.equal (Current.durable_range_id_to_json {expected with unread_messages=[]})
    (Current.durable_range_id_to_json {actual with unread_messages=[]})
let same_official_range (expected : Current.official_range_id) (actual : Current.official_range_id) =
  Yojson.Safe.equal (Current.official_range_id_to_json {expected with unread_messages=[]})
    (Current.official_range_id_to_json {actual with unread_messages=[]})
let receipt_state request =
  let source=Request.source request and owner=Request.physical_owner request in
  let keepers_dir=Request.keepers_dir owner and keeper_id=Request.keeper_id owner in
  let* atom=match Source.range_id source with
    | None -> Ok None
    | Some expected ->
      let* actual=Current.committed_durable_coverage ~keepers_dir ~keeper_id
        ~receipt_scope:expected.receipt_scope in
      Ok (Some (Option.fold ~none:false ~some:(fun actual -> same_atom_range expected actual) actual)) in
  let* official=match Source.official_range_id source with
    | None -> Ok None
    | Some expected ->
      let* actual=Current.committed_official_coverage ~keepers_dir ~keeper_id
        ~receipt_scope:expected.receipt_scope in
      Ok (Some (Option.fold ~none:false ~some:(fun actual -> same_official_range expected actual) actual)) in
  let proofs=Option.to_list atom @ Option.to_list official in
  let* ()=require (proofs<>[]) "Original history has no Memory range receipts" in
  if List.for_all Fun.id proofs then Ok true
  else if List.exists Fun.id proofs then Error "Original history has only a partial committed range receipt set"
  else Ok false
let marker request (record : Owner.retained) ~root ~committed =
  let source=Request.source request in
  let optional encode=Option.fold ~none:`Null ~some:encode in
  Lane_addon_action.canonical (`Assoc ["version",`Int 1;
    "kind",`String "librarian-history-range-settlement";
    "execution_id",`String record.request_id;"execution_digest",`String record.request_digest;
    "gate_root_id",`String root;"committed",`Bool committed;
    "atom",optional Current.durable_range_id_to_json (Source.range_id source);
    "official",optional Current.official_range_id_to_json (Source.official_range_id source);
    "external_prepared",Cursor.observation_to_json (Source.external_prepared source)])
let commit_matches record ~before ~after = match Progress.phase record.Owner.progress with
  | Progress.Judged _ -> Ok ()
  | Committing commit | Commit_unknown (commit,_) | Finished commit | Conflicted (commit,_) ->
    let* ()=same before commit.change.before in same after commit.change.after
  | Captured | Admission_wait _ | Dispatch_pending _ | Rejected _
  | Subdividing _ | Subdivided _ -> Error "History publication has an unsupported original phase"
let expected_basis request : Current.disposition_basis =
  let source=Request.source request in
  { expected_revision=Source.expected_revision source;
    expected_facts=Option.map (fun (current : Keeper_librarian.current_selection) -> current.facts)
      (Source.input source).current }
let observed_basis snapshot : Current.disposition_basis =
  { expected_revision=Option.map (fun (current : Current.t) -> current.revision) snapshot;
    expected_facts=Option.map (fun (current : Current.t) -> current.facts) snapshot }
let basis_to_json (basis : Current.disposition_basis) =
  let optional encode=Option.fold ~none:`Null ~some:encode in
  `Assoc ["revision",optional (fun value -> `Int value) basis.expected_revision;
    "facts",optional (fun facts -> `List (List.map Memory_types.fact_to_json facts)) basis.expected_facts]
let closed_fields expected = function
  | `Assoc fields when List.sort String.compare (List.map fst fields)=List.sort String.compare expected -> Ok fields
  | _ -> Error "Original history basis evidence has unknown, duplicate or missing fields"
let basis_of_json json =
  let* fields=closed_fields ["revision";"facts"] json in
  let* expected_revision=match List.assoc "revision" fields with
    | `Null -> Ok None
    | `Int value when value>=1 -> Ok (Some value)
    | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ | `List _ ->
      Error "Original history basis revision is invalid" in
  let* expected_facts=match List.assoc "facts" fields with
    | `Null -> Ok None
    | `List facts ->
      let* facts=List.fold_right (fun json tail ->
        let* fact=Memory_types.fact_of_json json |> Result.map_error Memory_types.wire_error_to_string in
        let* tail=tail in Ok (fact::tail)) facts (Ok []) in Ok (Some facts)
    | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ ->
      Error "Original history basis facts are invalid" in
  let* ()=match expected_revision,expected_facts with
    | None,None | Some _,Some _ -> Ok ()
    | None,Some _ | Some _,None -> Error "Original history basis presence differs" in
  Ok {Current.expected_revision;expected_facts}
let check_supersession request evidence =
  let* fields=closed_fields ["version";"kind";"original_basis";"observed_basis"] evidence in
  let* ()=require (List.assoc "version" fields=`Int 1
    && List.assoc "kind" fields=`String "librarian-history-basis-superseded")
    "Original history conflict is not a known typed basis observation" in
  let* original=basis_of_json (List.assoc "original_basis" fields) in
  let* observed=basis_of_json (List.assoc "observed_basis" fields) in
  let* ()=same (basis_to_json (expected_basis request)) (basis_to_json original) in
  require (original<>observed) "Original history conflict has no different Memory basis"
let supersession_evidence request observed =
  let* evidence=Lane_addon_action.canonical (`Assoc ["version",`Int 1;
    "kind",`String "librarian-history-basis-superseded";
    "original_basis",basis_to_json (expected_basis request);
    "observed_basis",basis_to_json (observed_basis observed)]) in
  let* ()=check_supersession request evidence in Ok evidence
let is_superseded ~request ~(record : Owner.retained) =
  match Progress.phase record.progress with
  | Progress.Conflicted (_,evidence) ->
    let* ()=check_supersession request evidence in Ok true
  | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
  | Finished _ | Rejected _ | Subdividing _ | Subdivided _ -> Ok false
let atom_target source = Option.map (fun (range : Current.durable_range_id) : Atom.t ->
  {position={trace_id=range.trace_id;end_atom=range.end_atom;last_atom_digest=range.last_atom_digest};
    boundary_lines_seen=range.boundary_lines_seen}) (Source.range_id source)
let official_target source = Option.map (fun (range : Current.official_range_id) : Official.t ->
  {boundary_line=List.fold_left (fun line (next,_) -> max line next)
    range.after_boundary_line range.turns}) (Source.official_range_id source)
let settle_positions request =
  let source=Request.source request and owner=Request.physical_owner request in
  let keeper_id=Request.keeper_id owner and runtime_keepers_dir=Source.runtime_keepers_dir source in
  let* ()=Request.confirm_owner request in
  let* proved=receipt_state request in
  let* ()=require proved "History settlement lacks actual original Memory range receipts" in
  (* Archive original unread evidence before discarding any prepared cursor. *)
  let* _=Current.committed_unread_messages ~keepers_dir:(Request.keepers_dir owner) ~keeper_id in
  let* atom=Atom.read ~keepers_dir:runtime_keepers_dir ~keeper_id
    |> Result.map_error Atom.read_error_to_string in
  let* official=Official.read ~keepers_dir:runtime_keepers_dir ~keeper_id
    |> Result.map_error Official.read_error_to_string in
  let atom_next=atom_target source and official_next=official_target source in
  let positions=Source.positions source in
  let* ()=require (atom=positions.current || Option.fold ~none:false ~some:(fun next -> atom=Some next) atom_next)
    "Original history atom position changed outside its settlement" in
  let* ()=require (official=positions.official || Option.fold ~none:false ~some:(fun next -> official=Some next) official_next)
    "Original history official position changed outside its settlement" in
  let* external_cursor=Cursor.observe ~runtime_keepers_dir ~keeper_name:keeper_id in
  let prepared=Source.external_prepared source in
  let through=Keeper_librarian_input_sources.external_through (Source.counterparts source) in
  let already=Cursor.observation_matches_preparation external_cursor ~after:through ~through
    ~atom:None ~official:None in
  let* ()=require (already || Yojson.Safe.equal (Cursor.observation_to_json external_cursor)
    (Cursor.observation_to_json prepared)) "Original history external cursor differs from its prepared or settled state" in
  let* ()=if already then Ok () else Cursor.acknowledge ~runtime_keepers_dir ~keeper_name:keeper_id in
  let* ()=match atom_next with
    | None -> Ok ()
    | Some next -> if atom=Some next then Ok () else
      Atom.write ~keepers_dir:runtime_keepers_dir ~keeper_id next |> Result.map_error Atom.write_error_to_string in
  let* ()=match official_next with
    | None -> Ok ()
    | Some next -> if official=Some next then Ok () else
      Official.write ~keepers_dir:runtime_keepers_dir ~keeper_id next |> Result.map_error Official.write_error_to_string in
  let* external_cursor=Cursor.observe ~runtime_keepers_dir ~keeper_name:keeper_id in
  let* atom=Atom.read ~keepers_dir:runtime_keepers_dir ~keeper_id |> Result.map_error Atom.read_error_to_string in
  let* official=Official.read ~keepers_dir:runtime_keepers_dir ~keeper_id |> Result.map_error Official.read_error_to_string in
  let* ()=require (Cursor.observation_matches_preparation external_cursor ~after:through ~through ~atom:None ~official:None)
    "Original history external ACK remains unconfirmed" in
  require (atom=Option.fold ~none:positions.current ~some:(fun value -> Some value) atom_next
    && official=Option.fold ~none:positions.official ~some:(fun value -> Some value) official_next)
    "Original history read-position settlement remains unconfirmed"
type frontier = Unfinished | Settled
let validate_with ~validate_chain ~validate_preparation ~root ~latest ~size_evidence
    ~store ~request ~(record : Owner.retained) =
  let* ()=Request.confirm_record request record in
  let* ()=validate_chain () in
  let* ()=match Progress.preparation record.progress with
    | None ->
      let* root=root () in
      require (Option.is_none root) "History gate exists without its original parent intent"
    | Some (Preparation_pending _ | Preparation_confirmed _) ->
      validate_preparation () in
  match Progress.phase record.progress with
  | Progress.Captured | Admission_wait _ | Dispatch_pending _ -> Ok Unfinished
  | Judged _ -> let* _=original_answer ~store request record in Ok Unfinished
  | Committing _ | Commit_unknown _ | Finished _ | Conflicted _ ->
    let* _=is_superseded ~request ~record in
    let* _,proposal=original_answer ~store request record in
    let* ()=match Progress.preparation record.progress with
      | Some (Preparation_confirmed _) -> Ok ()
      | None | Some (Preparation_pending _) -> Error "History commit precedes original gate publication ACK" in
    let* root=root () in
    let* root=Option.to_result ~none:"Original history commit gate root is absent" root in
    let* before=marker request record ~root:root.Owner.request_id ~committed:false in
    let* after=marker request record ~root:root.request_id ~committed:true in
    let* ()=commit_matches record ~before ~after in
    (match Progress.phase record.progress with
     | Progress.Finished _ | Conflicted _ ->
       let* latest=latest () in
       let* latest=Option.to_result ~none:"Terminal history gate chain is absent" latest in
       let* gate=size_evidence ~gate_request_id:latest.Owner.request_id in
       (match Gate.failure_detail ~absorbed:proposal.accepted.selection.absorbed gate with
        | None -> Ok Settled | Some detail -> Error detail)
     | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
     | Rejected _ | Subdividing _ | Subdivided _ -> Ok Unfinished)
  | Rejected {stage=Progress.Execution;evidence} ->
    let* exact=Request.request request in
    let* schema=Option.to_result ~none:"Original history refusal lacks its schema" exact.schema in
    let* retained=Exact.retained_final_of_json ~schema evidence in
    let final=Exact.delivered retained in
    let* ()=Request.confirm_final ~store request final in
    (match final with
     | Exact.Call_final (Answered _) -> Error "History refusal contains an answered host result"
     | Outcome_unknown -> Ok Unfinished
     | Call_final (Invalid_output _ | Input_refused _ | Output_limit_reached _)
     | Not_allowed _ | Request_id_reused -> Ok Settled)
  | Rejected {stage=Progress.Before_dispatch;_} | Subdividing _ | Subdivided _ ->
    Error "Original history record has an unsupported domain phase"
let validate ~store ~request ~record =
  let owner=Request.physical_owner request in
  validate_with ~store ~request ~record
    ~validate_chain:(fun () -> Journal.validate_chain ~store ~owner ~capture:request)
    ~validate_preparation:(fun () -> Journal.validate_root_preparation ~store ~owner ~capture:request)
    ~root:(fun () -> Journal.root ~store ~owner ~capture:request)
    ~latest:(fun () -> Journal.latest ~store ~owner ~capture:request)
    ~size_evidence:(fun ~gate_request_id -> Journal.restore_size_evidence ~store ~owner
      ~parent_execution:request ~gate_request_id)
let validate_inventory ~inventory ~store ~request ~record =
  let* chain=Journal.Inventory.validate inventory ~capture:request ~parent:record in
  validate_with ~store ~request ~record
    ~validate_chain:(fun () -> Ok ())
    ~validate_preparation:(fun () -> Journal.Inventory.validate_root_preparation chain)
    ~root:(fun () -> Ok (Journal.Inventory.root chain))
    ~latest:(fun () -> Journal.Inventory.latest chain)
    ~size_evidence:(fun ~gate_request_id -> Journal.Inventory.restore_size_evidence chain ~gate_request_id)

type preparation = Ready of Owner.retained | Unavailable of string
let publish_with ~before_settlement ~store ~config ~request ~(original : Owner.retained) ~proposal:_ ~fresh_authority =
  let owner=Request.physical_owner request in
  let keeper_id=Request.keeper_id owner in
  let pending detail=Ok (Publication.Publication_pending detail) in
  let* ()=io (fun () ->
    let base_path=config.Workspace.base_path in
    let* current=Request.observe_owner ~base_path
      ~keepers_dir:(Config_dir_resolver.keepers_dir_for_base_path ~base_path) ~keeper_id in
    Request.owner_matches_json current (Request.owner_to_json owner)) in
  let* current,raw,proposal=io (fun () ->
    let* current=reload ~store ~previous:original request in
    let* ()=same (Progress.to_json original.progress) (Progress.to_json current.progress) in
    let* raw,proposal=original_answer ~store request current in
    let* _=validate ~store ~request ~record:current in
    Ok (current,raw,proposal)) in
  let* superseded=is_superseded ~request ~record:current in
  if superseded then Ok (Publication.Publication_superseded current) else
  let prepare current =
    match Progress.preparation current.Owner.progress with
    | Some (Progress.Preparation_pending _ | Preparation_confirmed _) -> Ok (Ready current)
    | None ->
      (match fresh_authority () with
       | Error detail -> Ok (Unavailable detail)
       | Ok () ->
         let authority=Gate.resolve ~keeper_id in
         let* current=io (fun () ->
           let* ()=Request.confirm_owner request in
           let* intended=Journal.prepare_root ~store ~owner ~capture:request ~parent:current
             ~proposal:raw ~request_id:(Random_id.uuid_v7 ()) ~authority in
           let* _,current=advance ~store current (Progress.Preparation_intended intended) in Ok current) in
         Ok (Ready current)) in
  (* Absence of a live configured destination suspends creation, never turns an
     old intent into a new ID. Existing full intents recover locally while Off. *)
  let* prepared=prepare current in
  match prepared with
  | Unavailable detail -> pending detail
  | Ready _ ->
    let* current,root,latest=io (fun () ->
      let* _=Journal.recover_root ~store ~owner ~capture:request in
      let* ()=Journal.recover_retries ~store ~owner ~capture:request in
      let* current=reload ~store ~previous:current request in
      let* root=Journal.root ~store ~owner ~capture:request in
      let* root=Option.to_result ~none:"Original history gate root is absent" root in
      let* latest=Journal.latest ~store ~owner ~capture:request in
      let* latest=Option.to_result ~none:"Original history gate leaf is absent" latest in
      Ok (current,root,latest)) in
    let* proved=io (fun () -> receipt_state request) in
    let* result=match Progress.phase current.progress with
      | Progress.Committing _ | Commit_unknown _ | Finished _ ->
        let* gate=io (fun () -> Journal.restore_size_evidence ~store ~owner
          ~parent_execution:request ~gate_request_id:latest.Owner.request_id) in
        Ok (Journal.Complete (gate,latest))
      | Judged _ ->
        if proved then Error "History Memory receipts precede their original commit intent"
        else
          let live_authority=match fresh_authority () with
            | Ok () -> Some (Gate.resolve ~keeper_id)
            | Error _ -> None in
          let* prior_complete=match Progress.phase latest.progress with
            | Progress.Judged _ | Rejected {stage=Progress.Execution;_} ->
              let* gate=io (fun () -> Journal.restore_size_evidence ~store ~owner
                ~parent_execution:request ~gate_request_id:latest.request_id) in Ok (Some gate)
            | Captured | Dispatch_pending _ -> Ok None
            | Admission_wait _ | Committing _ | Commit_unknown _ | Finished _ | Conflicted _
            | Rejected {stage=Progress.Before_dispatch;_} | Subdividing _ | Subdivided _ ->
              Error "Original history gate has an unsupported runnable phase" in
          let* next=match prior_complete,live_authority with
            | Some gate,Some authority ->
              (match Gate.failure_detail ~absorbed:proposal.Keeper_librarian_runtime.accepted.selection.absorbed gate,
                Gate.failure_kind gate with
               | Some _,(Some Gate.Evaluation_failed | None) ->
                 let* ()=fresh_authority () in
                 io (fun () -> Journal.retain ~store ~owner ~capture:request ~parent:current
                   ~proposal:raw ~request_id:(Random_id.uuid_v7 ()) ~authority
                   ~predecessor:(Some latest.request_id))
               | Some _,Some Input_capacity_exceeded | None,(Some Input_capacity_exceeded | Some Evaluation_failed | None) ->
                 Ok latest)
            | None,(None | Some _) | Some _,None -> Ok latest in
          Journal.resume ~store ~owner ~capture:request ~record:next ~live_authority
            ~before_dispatch:fresh_authority
      | Captured | Admission_wait _ | Dispatch_pending _ | Conflicted _ | Rejected _
      | Subdividing _ | Subdivided _ -> Error "History publication lacks its original answered phase" in
    match result with
    | Journal.Pending _ -> pending "Original history absorption judgment is pending"
    | Complete (gate,_) ->
      let accepted=proposal.Keeper_librarian_runtime.accepted in
      match Gate.failure_detail ~absorbed:accepted.selection.absorbed gate with
      | Some detail -> pending detail
      | None ->
        let* before=marker request current ~root:root.Owner.request_id ~committed:false in
        let* after=marker request current ~root:root.request_id ~committed:true in
        let* ()=commit_matches current ~before ~after in
        let event record event=io (fun () ->
          let* ()=Request.confirm_owner request in advance ~store record event) in
        let confirm record =
          before_settlement ();
          match io (fun () -> settle_positions request) with
          | Error detail -> pending detail
          | Ok () ->
            let confirmed=match Progress.phase record.Owner.progress with
              | Progress.Finished _ -> Ok record
              | Committing _ | Commit_unknown _ ->
                let* _,record=event record (Progress.Commit_observed after) in Ok record
              | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Conflicted _ | Rejected _
              | Subdividing _ | Subdivided _ -> Error "Memory receipts precede the original history commit intent" in
            (match confirmed with
             | Error detail -> pending detail
             | Ok record -> Ok (Publication.Publication_complete record)) in
        let apply record =
          let source=Request.source request in
          let committed=ref None in
          let applied=io (fun () ->
            Keeper_librarian_durable_source_lock.with_original ~request (fun () ->
              let* actual=reload ~store ~previous:record request in
              let* ()=same (Progress.to_json actual.progress) (Progress.to_json record.Owner.progress) in
              let* proved=receipt_state request in
              let* ()=require (not proved) "Original history Memory effect is already receipt-proved" in
              Ok (Current.apply_disposition_guarded ~on_committed:(fun disposition -> committed:=Some disposition)
                ~expected_basis:(expected_basis request)
                ~dropped_statements:accepted.selection.dropped
                ?durable_range_id:(Source.range_id source) ?official_range_id:(Source.official_range_id source)
                ~explicit_candidate_ids:accepted.explicit_candidate_ids
                ~admission_recall:{decided_at_revision=Source.expected_revision source;
                  bindings=accepted.admission_recall_bindings}
                ~required_memory_ids:accepted.required_memory_ids
                ~absorbed:(Gate.absorbed_of_run gate) ~revisions:accepted.selection.revisions
                ~keepers_dir:(Request.keepers_dir owner) ~keeper_id
                ~now:(Time_compat.now ())
                ~source:{Current.kind=Current.Librarian;trace_id=Ids.Turn_ref.trace_id (Source.input source).turn_ref}
                ~new_claims:(Gate.without_copies gate accepted.selection.new_claims) ()))) in
          (* An atomic save or outer source-lock release can fail after Memory
             publication. The real receipts, never the returned status, decide. *)
          let* proved=io (fun () -> let* ()=Request.confirm_owner request in receipt_state request) in
          if proved then (
            let ()=match !committed with
              | None -> ()
              | Some disposition ->
                io (fun () -> Keeper_memory_os_events.append_all
                  ~keepers_dir:(Request.keepers_dir owner) ~keeper_id
                  (List.map (fun (revision : Keeper_librarian.revision) : Keeper_memory_os_events.event ->
                    {recorded_at=disposition.Current.snapshot.updated_at;
                      memory_id=revision.superseded;trace_id=Ids.Turn_ref.trace_id (Source.input source).turn_ref;
                      kind=Keeper_memory_os_events.Revised {superseded_by=revision.superseded_by}})
                    disposition.revisions_applied))
                |> List.iter (fun error -> Log.Keeper.warn ~keeper_name:keeper_id "%s"
                  (Keeper_memory_os_events.append_error_to_string error)) in
            confirm record)
          else match applied with
          | Ok (Error (Current.Basis_superseded observed)) ->
            (* Only the locked store guard can establish this decision. Its
               recovery may have completed an earlier publication, so the
               actual original receipt check above always wins first. *)
            let* evidence=supersession_evidence request observed in
            let* _,record=event record (Progress.Commit_conflicted evidence) in
            let* _=io (fun () -> validate ~store ~request ~record) in
            Ok (Publication.Publication_superseded record)
          | Error detail | Ok (Error (Current.Disposition_store_failed detail)) ->
            let* _,_=event record (Progress.Commit_uncertain (`Assoc ["detail",`String detail])) in
            pending detail
          | Ok (Ok _) ->
            let detail="Original history disposition returned without its actual range receipts" in
            let* _,_=event record (Progress.Commit_uncertain (`Assoc ["detail",`String detail])) in
            pending detail in
        let* proved=io (fun () -> receipt_state request) in
        if proved then confirm current else
        match Progress.phase current.progress with
        | Progress.Finished _ -> Error "Finished history publication lacks its actual original Memory receipts"
        | Judged _ ->
          let* fresh,record=event current (Progress.Commit_intended {before;after}) in
          if fresh then apply record else pending "Reload the original history commit intent"
        | Committing _ ->
          let* _,record=event current (Progress.Commit_uncertain (`Assoc ["detail",`String "Reconcile original history disposition"])) in
          let* proved=io (fun () -> receipt_state request) in
          if proved then confirm record else
          let* fresh,record=event record (Progress.Commit_retry_observed before) in
          if fresh then apply record else pending "Reload the original history commit retry"
        | Commit_unknown _ ->
          let* fresh,record=event current (Progress.Commit_retry_observed before) in
          if fresh then apply record else pending "Reload the original history commit retry"
        | Captured | Admission_wait _ | Dispatch_pending _ | Conflicted _ | Rejected _
        | Subdividing _ | Subdivided _ -> Error "Original history publication cannot commit in this phase"

let publish = publish_with ~before_settlement:(fun () -> ())
module For_testing = struct
  let publish = publish_with
end
