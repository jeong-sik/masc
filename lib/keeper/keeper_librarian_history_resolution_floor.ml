module Request = Keeper_librarian_durable_request
module Capture = Keeper_librarian_durable_capture
module Lock = Keeper_librarian_durable_source_lock
module Lineage = Keeper_librarian_history_resolution_lineage
module State = Keeper_librarian_history_resolution_state
module Journal = Keeper_librarian_durable_gate
module Chain = Keeper_librarian_floor_chain
module Step = Keeper_librarian_floor_step_request
module Steps = Keeper_librarian_floor_step_owner
module Owner = Lane_addon_tool_request_owner
module Progress = Lane_addon_request_progress
module Exact = Lane_addon_exact
module Runtime = Keeper_librarian_runtime
module Current = Keeper_memory_os_current
module Memory = Keeper_memory_os_current_types
module Program = Keeper_memory_os_program
module Cursor = Keeper_external_read_cursor
let ( let* ) = Result.bind
let ( let+ ) result f = Result.map f result
let io f = Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ f
let require condition detail = if condition then Ok () else Error detail
let owned result = Result.map_error Owner.error_to_string result

type t = {store:Lane_addon_store.t;record:Owner.retained;request:Request.t;
  cut_original_id:string;final:Exact.final}
let request t=t.request
let cut_original_id t=t.cut_original_id
let unencumbered (record:Owner.retained) =
  Progress.preparation record.progress=None && Progress.replacement record.progress=None
  && Progress.settlement record.progress=None
let execution_final request (record:Owner.retained) =
  match Progress.phase record.progress with
  | Progress.Rejected {stage=Progress.Execution;evidence} when unencumbered record ->
    let* exact=Request.request request in
    let* schema=Option.to_result ~none:"Cut descendant refusal has no schema" exact.Exact.schema in
    let+ retained=Exact.retained_final_of_json ~schema evidence in Some (Exact.delivered retained)
  | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
  | Finished _ | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ -> Ok None
let no_gate ~store request =
  let* root=Journal.root ~store ~owner:(Request.physical_owner request) ~capture:request in
  require (Option.is_none root) "Cut floor leaf already owns an actual absorption Gate"
let confirm t =
  let* ()=Request.confirm_owner t.request in
  let* record=Owner.reload ~store:t.store t.record |> owned in
  let* record=Option.to_result ~none:"Cut floor original disappeared" record in
  let* ()=Request.confirm_record t.request record in
  let* ()=State.check_unfenced ~store:t.store ~request:t.request ~original:record in
  let* ()=no_gate ~store:t.store t.request in
  let* final=execution_final t.request record in
  let* ()=require (final=Some t.final) "Cut floor leaf changed its definite refusal or acquired other work" in
  let* ()=Request.confirm_final ~store:t.store t.request t.final in
  let* obligation=Lineage.refusal_obligation ~store:t.store t.request in
  require (obligation=Lineage.Cut_read_required t.cut_original_id)
    "Cut floor lost its confirmed original source obligation"
let candidate ~store ~record ~request = io (fun () ->
  let* ()=Request.confirm_record request record in
  let* final=execution_final request record in
  match final with
  | Some (Exact.Call_final (Exact.Input_refused _) as final) ->
    let* ()=Request.confirm_owner request in
    let* ()=State.check_unfenced ~store ~request ~original:record in
    let* ()=no_gate ~store request in
    let* ()=Request.confirm_final ~store request final in
    let* evidence=Request.refusal_evidence ~store request final in
    let report=Runtime.not_committed_of_failure ~detail:"Cut descendant input was refused" evidence in
    if not (Runtime.may_descend_messages [report]) then Ok None else
    let* obligation=Lineage.refusal_obligation ~store request in
    (match obligation with
     | Lineage.No_cut_ancestor -> Ok None
     | Cut_read_required cut_original_id ->
       let t={store;record;request;cut_original_id;final} in
       let+ ()=confirm t in Some t)
  | Some (Call_final (Answered _ | Invalid_output _ | Output_limit_reached _)
      | Outcome_unknown | Not_allowed _ | Request_id_reused) | None -> Ok None)
let source_identity t =
  let+ source_basis_digest=Request.source_basis_digest t.request in
  ({Runtime.request_id=Request.request_id t.request;request_digest=Request.body_digest t.request;
    source_basis_digest}:Runtime.retained_step_source)
let same_owner captured current =
  match Lane_addon_captured_destination.relation ~captured ~current with
  | Same | Replaced -> true
  | Other_owner -> false
let retained_basis t =
  let* source=source_identity t in
  let* found=Steps.discover ~store:t.store ~owner:(Request.physical_owner t.request)
    |> Result.map_error Steps.error_to_string in
  let matching=List.filter (fun (_, (index:Step.index)) ->
    index.header.range.request_id=source.request_id) found in
  let* ()=require (List.for_all (fun (_, (index:Step.index)) ->
    index.header.range.request_digest=source.request_digest && index.header.retained_source=Some source
    && same_owner (Request.destination t.request) index.header.destination) matching)
    "Cut floor range has another source, preparation mode or destination owner" in
  match matching with
  | [] -> Ok None
  | _::_ ->
    let* first=match List.filter (fun (_, (index:Step.index)) -> index.header.position=0) matching with
      | [first] -> Ok first
      | [] | _::_ -> Error "Cut floor has no unique retained first question" in
    let* record,_=Steps.load ~store:t.store first |> Result.map_error Steps.error_to_string in
    let* step=Step.restore ~owner:(Request.physical_owner t.request) record in
    let* ()=require (same_owner
      (Request.destination t.request) (Step.destination step))
      "Cut floor first question belongs to another original leaf owner" in
    let* ()=Runtime.validate_retained_durable_step ~source ~original:(Request.preparation t.request) (Step.step step) in
    let+ basis=Option.to_result ~none:"Cut floor lost its retained anchor/manifest" (Step.chain_basis step) in
    Some (basis,Step.transaction_id step)
let keepers t =
  let owner=Request.physical_owner t.request in Request.keepers_dir owner,Request.keeper_id owner
let same_manifest (basis:Step.retained_chain_basis) (manifest:Capture.message_manifest) =
  require (basis.Step.sources=manifest.ordered_sources) "Cut floor original message manifest changed"
let before_inference t (basis:Step.retained_chain_basis) = io (fun () ->
  Lock.with_original_manifest ~request:t.request (fun manifest ->
    let* ()=confirm t in
    let* ()=same_manifest basis manifest in
    let keepers_dir,keeper_id=keepers t in
    let+ _=Current.resume_program_anchor ~keepers_dir ~keeper_id basis.anchor in ()))
let fresh t () = io (fun () ->
  Lock.with_original_manifest ~request:t.request (fun manifest ->
    let* ()=confirm t in
    let* recorded=Keeper_librarian_durable_receipts.state t.request in
    let* ()=require (not recorded) "Cut floor source already has receipts without this retained program" in
    let keepers_dir,keeper_id=keepers t in
    let* anchor=Current.capture_program_anchor ~keepers_dir ~keeper_id in
    let current=Option.map (fun (snapshot:Current.t) -> ({Keeper_librarian.facts=snapshot.facts}
      :Keeper_librarian.current_selection)) (Current.program_anchor_snapshot anchor) in
    let+ unread_messages=Current.read_unread_messages ~keepers_dir ~keeper_id in
    ({Chain.transaction_id=Keeper_librarian_message_floor.fresh_transaction_id ();
      current;previous_state=None;unread_messages},
     {Step.anchor=Current.program_anchor_evidence anchor;sources=manifest.ordered_sources})))

type attention = No_message_coordinate
  | Message_refused of {position:int;report:Runtime.not_committed}
  | Declaration_replaced of {position:int;request_id:string}
type prepared = {request_id:string;request_digest:string;basis:Step.retained_chain_basis;
  transaction_id:string;finished:Keeper_librarian_message_floor.Machine.finished}
type outcome = Pending of Keeper_librarian_pending.t | Attention of attention | Prepared of prepared
let descend ~config ~reserved t =
  let* ()=io (fun () -> confirm t) in
  match (Capture.input (Request.source t.request)).messages with
  | [] -> Ok (Attention No_message_coordinate)
  | _::_ ->
    let* result=Chain.run_complete_original ~store:t.store ~config ~reserved ~original:t.request
      ~fresh:(fresh t) ~before_inference:(before_inference t) in
    match result.outcome with
    | Chain.Finished finished ->
      let+ ()=require (finished.program.unread=[]) "Cut floor cannot finish with unread source holes" in
      Prepared {request_id=Request.request_id t.request;request_digest=Request.body_digest t.request;
        basis=result.basis;transaction_id=result.transaction_id;finished}
    | Pending pending -> Ok (Pending pending)
    | Stopped {position;report} -> Ok (Attention (Message_refused {position;report}))
    | Declaration_replaced {position;request_id} -> Ok (Attention (Declaration_replaced {position;request_id}))
    | Superseded -> Error "Retained Cut floor cannot retire its original basis by facts equality"

let program_source t (manifest:Capture.message_manifest) =
  let source=Request.source t.request in
  match Capture.range_id source,Capture.official_range_id source,manifest.checkpoint with
  | Some range,None,Some checkpoint -> Ok (Current.Atom_program_source {range;checkpoint})
  | None,Some range,(None|Some _) -> Ok (Current.Official_program_source
      {range;selected_turns=manifest.selected_turns})
  | Some atom_range,Some official_range,Some checkpoint -> Ok (Current.Mixed_program_source
      {atom_range;checkpoint;official_range;selected_turns=manifest.selected_turns;
       ordered_sources=manifest.ordered_sources})
  | (Some _),(None|Some _),None | None,None,(None|Some _) -> Error "Cut floor lacks its full original source"
let prepare_cursor t =
  let source=Request.source t.request and owner=Request.physical_owner t.request in
  let keeper_name=Request.keeper_id owner in
  let runtime_keepers_dir=Capture.runtime_keepers_dir source in
  let* expected=Cursor.observe ~runtime_keepers_dir ~keeper_name in
  let after=Cursor.observation_offset (Capture.external_before source) in
  let original=Capture.external_prepared source in
  let* ()=require (Cursor.observation_offset expected=after
    && Cursor.observation_matches_preparation original ~after
      ~through:(Keeper_librarian_input_sources.external_through (Capture.counterparts source))
      ~atom:(Capture.range_id source) ~official:(Capture.official_range_id source))
    "Cut floor external cursor changed before publication" in
  Cursor.restore_original_preparation ~runtime_keepers_dir ~keeper_name ~expected ~original
let exact_ranges t (proof:Current.committed_program) =
  let source=Request.source t.request in
  let expected=Option.fold ~none:[] ~some:(fun range -> [Memory.Atom_range range]) (Capture.range_id source)
    @ Option.fold ~none:[] ~some:(fun range -> [Memory.Official_range range]) (Capture.official_range_id source) in
  let actual=List.filter_map (function
    | Memory.Committed {range_id;snapshot_revision;snapshot_sha256}
        when snapshot_revision=proof.snapshot_revision && snapshot_sha256=proof.snapshot_sha256 -> Some range_id
    | Committed _ | Prepared _ -> None) proof.receipts in
  require (expected<>[] && List.length actual=List.length expected
    && List.length actual=List.length proof.receipts && List.for_all (fun range -> List.mem range actual) expected
    && List.for_all (function Memory.Atom_range range -> range.unread_messages=[]
      | Official_range range -> range.unread_messages=[]
      | Explicit_candidate _ | Explicit_candidate_with_recall _ -> false) actual)
    "Cut floor program lacks the complete fully read original range receipts"
let confirm_program_basis t (basis:Step.retained_chain_basis) transaction_id (proof:Current.committed_program) =
  let keepers_dir,keeper_id=keepers t in
  let program=proof.publication.execution.program in
  let* ()=require (proof.keepers_dir=keepers_dir && proof.keeper_id=keeper_id
    && program.transaction_id=transaction_id && program.sources=basis.Step.sources && program.unread=[]
    && program.keeper_id=(Capture.input (Request.source t.request)).keeper_id
    && Ids.Turn_ref.equal program.turn_ref (Capture.input (Request.source t.request)).turn_ref)
    "Cut floor program differs from its original manifest or transaction" in
  let* ()=Current.program_anchor_evidence_matches_publication basis.anchor proof.publication in
  exact_ranges t proof
let confirm_program t proof =
  let* ()=io (fun () -> confirm t) in
  let* retained=retained_basis t in
  let* basis,transaction_id=Option.to_result ~none:"Cut floor program has no retained first question" retained in
  let* ()=confirm_program_basis t basis transaction_id proof in
  io (fun () -> Current.confirm_committed_program proof)
let recover_committed t =
  let* ()=io (fun () -> confirm t) in
  let* retained=retained_basis t in
  match retained with
  | None -> Ok None
  | Some (basis,transaction_id) ->
    let keepers_dir,keeper_id=keepers t in
    let* proof=io (fun () -> Lock.with_original_settlement ~request:t.request (fun () ->
      let* ()=confirm t in Current.read_committed_program ~keepers_dir ~keeper_id ~transaction_id)) in
    (match proof with
     | None -> Ok None
     | Some proof -> let+ ()=confirm_program_basis t basis transaction_id proof in Some proof)
let publish t prepared =
  let* prior=recover_committed t in
  match prior with
  | Some proof -> Ok proof
  | None ->
  let* ()=require (prepared.request_id=Request.request_id t.request
    && prepared.request_digest=Request.body_digest t.request && prepared.finished.program.unread=[]
    && prepared.transaction_id=prepared.finished.program.transaction_id)
    "Cut floor prepared program belongs to another original or has unread holes" in
  let keepers_dir,keeper_id=keepers t in
  let outcome=io (fun () -> Lock.with_original_manifest ~request:t.request (fun manifest ->
    let* ()=confirm t in
    let* retained=retained_basis t in
    let* basis,transaction_id=Option.to_result ~none:"Cut floor publication lost its retained first question" retained in
    let* expected_anchor=Lane_addon_action.canonical
      (Current.program_anchor_evidence_to_json prepared.basis.anchor) in
    let* actual_anchor=Lane_addon_action.canonical
      (Current.program_anchor_evidence_to_json basis.anchor) in
    let* ()=require (transaction_id=prepared.transaction_id && basis.sources=prepared.basis.sources
      && Yojson.Safe.equal expected_anchor actual_anchor)
      "Cut floor publication changed its persisted original transaction, anchor or manifest" in
    let* ()=same_manifest prepared.basis manifest in
    let* recorded=Keeper_librarian_durable_receipts.state t.request in
    let* ()=require (not recorded) "Cut floor publication found range receipts without its canonical program" in
    let* anchor=Current.resume_program_anchor ~keepers_dir ~keeper_id prepared.basis.anchor in
    let* source=program_source t manifest in
    let* ()=prepare_cursor t in
    let* _=Current.apply_program ~pass:Keeper_memory_commit_pass.Durable ~keepers_dir ~keeper_id
      ~now:(Time_compat.now ()) ~anchor ~source ~validate_source:(fun () -> confirm t) prepared.finished.program in
    Ok ())) in
  match recover_committed t,outcome with
  | Ok (Some proof),_ -> Ok proof
  | Ok None,Ok () -> Error "Memory returned without the actual complete Cut floor program"
  | Ok None,Error detail -> Error detail
  | Error why,Ok () -> Error why
  | Error why,Error detail -> Error (detail ^ "; program readback: " ^ why)

let validate_retained_step ~store step =
  match (Step.step step).mode with
  | Runtime.Ordinary_floor -> Ok ()
  | Retained_original identity ->
    let owner=Step.physical_owner step in
    let* record=Owner.load ~store ~scope:(Request.scope owner) ~request_id:identity.request_id |> owned in
    let* record=Option.to_result ~none:"Retained floor has no original input-refused leaf" record in
    let* original=Request.restore ~owner record in
    let* selected=candidate ~store ~record ~request:original in
    let* selected=Option.to_result ~none:"Retained floor has no actual Cut source obligation" selected in
    let* actual=source_identity selected in
    let* ()=require (actual=identity) "Retained floor source identity differs from its actual leaf" in
    let* ()=require (same_owner
      (Request.destination original) (Step.destination step))
      "Retained floor request belongs to another original leaf owner" in
    let* ()=Runtime.validate_retained_durable_step ~source:identity ~original:(Request.preparation original) (Step.step step) in
    let* retained=retained_basis selected in
    let* basis,transaction_id=Option.to_result ~none:"Retained floor has no initial anchor/manifest" retained in
    let* ()=require (transaction_id=Step.transaction_id step) "Retained floor changed its original transaction" in
    before_inference selected basis
