module Request = Keeper_librarian_durable_request
module Owner = Keeper_librarian_durable_owner
module Retained = Lane_addon_tool_request_owner
module Record = Lane_addon_tool_request_owner.Record
module Progress = Lane_addon_request_progress
module Runtime = Lane_addon_runtime
module Consumer = Keeper_librarian_durable_consumer
module Refusal = Keeper_librarian_durable_refusal
module Source = Keeper_librarian_durable_capture
module Current = Keeper_memory_os_current
module Commit = Keeper_librarian_durable_commit
module Submit = Lane_addon_submit_once
module Descent = Keeper_librarian_floor_descent
module Floor_chain = Keeper_librarian_floor_chain
module Floor_cleanup = Keeper_librarian_floor_cleanup
module Floor_publish = Keeper_librarian_floor_publish
module Resolution_lineage = Keeper_librarian_history_resolution_lineage
module Resolution_work = Keeper_librarian_history_resolution_work
module Declaration_replacement = Keeper_librarian_declaration_replacement
open Result.Syntax
let io f = Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ f
let require condition detail = if condition then Ok () else Error detail
let equal_json left right detail =
  let* left=Lane_addon_action.canonical left in
  let* right=Lane_addon_action.canonical right in
  require (Yojson.Safe.equal left right) detail
module Edge = Keeper_librarian_durable_edge
let reserved = Edge.reserved
let resolve = Edge.resolve
let with_destination = Edge.with_destination
let fresh_authority ~config ~reserved request () =
  Edge.fresh_gate_authority ~config ~reserved ~owner:(Request.physical_owner request)
    ~expected:(Request.destination request) ()
let call = Edge.call
let resume ~store ~config ~reserved ~wake original =
  Owner.resume ~store ~config ~reserved ~original ~wake ~call:(call ~config ~reserved)
    ~publish:(fun ~original ~request ~proposal ->
      Keeper_librarian_durable_commit.publish ~store ~config ~original ~request ~proposal
        ~fresh_authority:(fresh_authority ~config ~reserved request)
      |> Result.map_error (fun detail -> Owner.Rejected detail))
  |> Result.map_error Owner.error_to_string
let pending_worker wait record =
  Keeper_librarian_pending.Worker
    (Keeper_librarian_pending.of_worker_wait ~installation_id:(Record.installation_id record)
       ~request_id:(Record.request_id record) wait)
let pending_publication request detail =
  Keeper_librarian_pending.Publication { request_id = Request.request_id request; detail }
let pending_basis request =
  Keeper_librarian_pending.Basis_changed { request_id = Request.request_id request }
let replacement_report_id request_id = Keeper_librarian_runtime.not_committed_of_failure
  ~detail:("Original Librarian declaration replaced; source remains unread: " ^ request_id)
  Keeper_exact_walk_failure.empty
let replacement_report record = replacement_report_id (Record.request_id record)
let advance_original ~store record event =
  io (fun () -> match Retained.advance ~store ~expected:record ~event with
    | Ok (Retained.Stored record | Already_stored record) -> Ok record
    | Ok (Unconfirmed detail) -> Error detail
    | Error error -> Error (Retained.update_error_to_string error))
let can_replace ~store ~(record:Retained.retained) ~request =
  let* superseded=Commit.is_superseded ~request ~record in
  if superseded then Ok true else
  match Request.predecessor request with
  | None -> Ok false
  | Some _ -> io (fun () ->
    let* exact=Request.request request in
    Declaration_replacement.ended ~store ~original:(Retained.listed record)
      ~exact ~captured:(Request.destination request))
let replacement_request (parent:Retained.retained) parent_request (intended:Progress.preparation_intent) =
  let* child=Request.of_json ~owner:(Request.physical_owner parent_request) intended.request in
  let* ()=require (Request.request_id child=intended.request_id)
    "Original history replacement intent names another request" in
  let* ()=match Request.predecessor child with
    | Some predecessor -> require (predecessor.request_id=parent.request_id
        && predecessor.request_digest=parent.request_digest)
        "Original history replacement intent has another predecessor"
    | None -> Error "Original history replacement intent has no predecessor" in
  let child_source=Request.source child in
  let* expected=Source.with_current ~expected_revision:(Source.expected_revision child_source)
    ~current:(Source.input child_source).current (Request.source parent_request)
    |> Result.map_error Source.error_to_string in
  let* ()=require (Source.to_json expected=Source.to_json child_source)
    "Original history replacement intent changed its immutable source" in
  Ok child
let recover_replacement ~store ((parent:Retained.retained),parent_request) =
  let* allowed=can_replace ~store ~record:parent ~request:parent_request in
  let* ()=require allowed "Original history has no confirmed replacement authority" in
  let* intended,pending=match Progress.replacement parent.progress with
    | Some (Preparation_pending intended) -> Ok (intended,true)
    | Some (Preparation_confirmed intended) -> Ok (intended,false)
    | None -> Error "Original history replacement publication intent is absent" in
  let* request=replacement_request parent parent_request intended in
  let scope=Request.scope (Request.physical_owner request) in
  let* observed=io (fun () -> Retained.load ~store ~scope ~request_id:intended.request_id
    |> Result.map_error Retained.error_to_string) in
  let* child=match observed,pending with
    | None,false -> Error "Acknowledged original history replacement is absent"
    | None,true -> Owner.retain ~store request |> Result.map_error Owner.error_to_string
    | Some child,(true | false) -> Ok child in
  let* restored=io (fun () -> Request.restore ~owner:(Request.physical_owner request) child) in
  let* ()=equal_json (Request.to_json restored) intended.request
    "Published original history replacement differs from its full intent" in
  let* ()=if not pending then Ok () else
    let* ()=require (Progress.phase child.progress=Progress.Captured)
      "Unacknowledged history replacement has execution progress" in
    let* _=advance_original ~store parent (Progress.Replacement_observed child.request_id) in Ok () in
  Ok (child,request)
let capture ?replacement_parent ?(before_retain=fun _ -> Ok ())
    ~store ~config ~reserved ~keeper_name source =
  let base_path=config.Workspace.base_path in
  let keepers_dir=Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let* owner,source_lines=io (fun () ->
    let* anchor=Current.capture_program_anchor ~keepers_dir ~keeper_id:keeper_name in
    let snapshot=Current.program_anchor_snapshot anchor in
    let revision=Option.map (fun (snapshot : Current.t) -> snapshot.revision) snapshot in
    let current=Option.map (fun (snapshot : Current.t) ->
      ({Keeper_librarian.facts=snapshot.facts} : Keeper_librarian.current_selection)) snapshot in
    let* ()=require (revision=Source.expected_revision source && current=(Source.input source).current)
      "Memory changed before the original completed-history capture" in
    let* source_lines=Keeper_memory_source_current.read_budget_lines ~keepers_dir ~keeper_id:keeper_name in
    let+ owner=Request.observe_owner ~base_path ~keepers_dir ~keeper_id:keeper_name in
    owner,source_lines) in
  let* preparation=Keeper_librarian_runtime.prepare_durable ~now:(Time_compat.now ()) ~source_lines
    (Source.input source) in
  let request_id=Request.fresh_request_id owner in
  (* Factory/retention performs local I/O under the actual configuration/action
     serializers. capture_tool_request_owner's factory is pure, so use the
     destination publication port rather than placing I/O in that factory. *)
  with_destination ~config ~reserved (fun destination ->
    let* ()=before_retain destination in
    let predecessor=Option.map (fun ((parent:Retained.retained),_) ->
      {Request.request_id=parent.request_id;request_digest=parent.request_digest}) replacement_parent in
    let* request=io (fun () -> Request.create ?predecessor ~request_id ~owner ~destination ~source ~preparation ()) in
    match replacement_parent with
    | None ->
      let* original=Owner.retain ~store request |> Result.map_error Owner.error_to_string in
      Ok (original,request)
    | Some (parent,parent_request) ->
      let* allowed=can_replace ~store ~record:parent ~request:parent_request in
      let* ()=require allowed "Original history has no confirmed replacement authority" in
      let intended:Progress.preparation_intent={request_id;request=Request.to_json request} in
      let* parent=advance_original ~store parent (Progress.Replacement_intended intended) in
      recover_replacement ~store (parent,parent_request))
let completed_outcome request =
  let source=Request.source request in
  let atom=Option.map (fun (range : Current.durable_range_id) ->
    {Keeper_librarian_progress.position={trace_id=range.trace_id;end_atom=range.end_atom;
      last_atom_digest=range.last_atom_digest};boundary_lines_seen=range.boundary_lines_seen}) (Source.range_id source) in
  match Source.official_range_id source,atom with
  | Some official,_ ->
    let boundary_line=List.fold_left (fun latest (line,_) -> max latest line)
      official.after_boundary_line official.turns in
    Consumer.Official_advanced {atom;official={Keeper_librarian_official_progress.boundary_line}}
  | None,Some progress -> Consumer.Progress_advanced progress
  | None,None -> Consumer.Nothing_to_read
(* [listed] is every original of the scope as its record and index; [read]
   holds the request of each one this pass read. A fenced parent's link is
   checked on records and indexes. A known-basis link compares whole requests:
   the pass reads every original that holds a replacement intent, is a
   predecessor, or follows a predecessor that is not a settled fence. An
   original the pass leaves unread is none of these. *)
let validate_lineage ~store ~fenced ~read listed =
  let find id=List.find_opt (fun (record,_) -> Record.request_id record=id) listed in
  let body id=Option.to_result ~none:"Original history lineage needs a request this pass did not read"
    (List.find_opt (fun ((record:Retained.retained),_) -> record.request_id=id) read) in
  let predecessors=List.filter_map (fun (_,(index:Request.index)) -> index.predecessor) listed in
  let parent_ids=List.map (fun (parent:Request.predecessor) -> parent.request_id) predecessors in
  let* ()=require (List.length parent_ids=List.length (List.sort_uniq String.compare parent_ids))
    "Original history basis supersession has multiple children" in
  let* ()=List.fold_left (fun result (child_record,(index:Request.index)) ->
    let* ()=result in
    match index.predecessor with
    | None -> Ok ()
    | Some predecessor ->
      let* parent_record,_=Option.to_result ~none:"Original history predecessor is absent"
        (find predecessor.request_id) in
      let* ()=require (Record.request_digest parent_record=predecessor.request_digest
        && Record.request_id parent_record<>Record.request_id child_record)
        "Original history predecessor identity changed" in
      if fenced (Record.request_id parent_record) then
        io (fun () -> Resolution_lineage.confirm_predecessor_record ~store
          ~require_confirmed:(Progress.phase (Record.progress child_record)<>Progress.Captured) child_record index)
      else
      let* child,request=body (Record.request_id child_record) in
      let* parent,parent_request=body (Record.request_id parent_record) in
      let* allowed=can_replace ~store ~request:parent_request ~record:parent in
      let* ()=require allowed "Original history successor has no confirmed replacement authority" in
      let* intended,pending=match Progress.replacement parent.progress with
        | Some (Preparation_pending intended) -> Ok (intended,true)
        | Some (Preparation_confirmed intended) -> Ok (intended,false)
        | None -> Error "Original history successor has no forward publication intent" in
      let* ()=require (intended.request_id=child.request_id)
        "Original history predecessor names another replacement" in
      let* ()=equal_json intended.request (Request.to_json request)
        "Original history successor differs from its predecessor publication intent" in
      let* ()=require (not pending || Progress.phase child.progress=Progress.Captured)
        "Unacknowledged original history successor has execution progress" in
      let* ()=require (Request.owner_to_json (Request.physical_owner parent_request)
        =Request.owner_to_json (Request.physical_owner request)) "Original history successor changed its physical owner" in
      let child_source=Request.source request in
      let* expected=Source.with_current ~expected_revision:(Source.expected_revision child_source)
        ~current:(Source.input child_source).current (Request.source parent_request)
        |> Result.map_error Source.error_to_string in
      require (Source.to_json expected=Source.to_json child_source)
        "Original history successor changed its immutable source or acknowledgment frontier") (Ok ()) listed in
  let* ()=List.fold_left (fun result (record,_) ->
    let* ()=result in match Progress.replacement (Record.progress record) with
    | None -> Ok ()
    | Some (Preparation_pending _ | Preparation_confirmed _) ->
      let* parent,request=body (Record.request_id record) in
      let* intended=match Progress.replacement parent.progress with
        | Some (Preparation_pending intended | Preparation_confirmed intended) -> Ok intended
        | None -> Error "Original history replacement intent disappeared" in
      let* allowed=can_replace ~store ~request ~record:parent in
      let* ()=require allowed "Original history replacement intent has no confirmed authority" in
      let* _=replacement_request parent request intended in
      (match find intended.request_id,Progress.replacement parent.progress with
       | None,Some (Preparation_confirmed _) -> Error "Acknowledged original history replacement is missing"
       | None,Some (Preparation_pending _) -> Ok ()
       | Some (child,_),Some (Preparation_pending _ | Preparation_confirmed _) ->
         let* _,child=body (Record.request_id child) in
         equal_json (Request.to_json child) intended.request "Original history forward replacement payload changed"
       | (None | Some _),None -> Error "Original history replacement intent disappeared")) (Ok ()) listed in
  let rec ancestry seen (index:Request.index) = match index.predecessor with
    | None -> Ok ()
    | Some predecessor ->
      let* ()=require (not (List.mem predecessor.request_id seen)) "Cyclic original history predecessor lineage" in
      let* _,parent=Option.to_result ~none:"Original history predecessor disappeared" (find predecessor.request_id) in
      ancestry (predecessor.request_id::seen) parent in
  let* ()=List.fold_left (fun result (record,index) ->
    let* ()=result in ancestry [Record.request_id record] index) (Ok ()) listed in
  let+ candidates=List.fold_left (fun result (((record:Retained.retained),request) as original) ->
    let* candidates=result in
    if List.mem record.request_id parent_ids || fenced record.request_id then Ok candidates else
    let+ allowed=can_replace ~store ~record ~request in
    if allowed then original::candidates else candidates) (Ok []) read in
  List.rev candidates
(* A chain settles leaf
   first under the day its root was minted, as Workspace Curator chains do:
   each history record, then the gate records of that execution. Every body
   holds its own request ID, so no two records share a body file and a move
   never takes another record's body. *)
let settle_record ~store ~date record =
  Retained.settle ~store ~date record
  |> Result.map_error Retained.settle_error_to_string
let archived ~store ~scope ~date request_id =
  io (fun () -> Retained.settled ~store ~scope ~date ~request_id)
  |> Result.map_error Retained.error_to_string
let settle_gates ~store ~inventory ~date ~execution_id =
  List.fold_left (fun moved gate ->
    let* moved=moved in
    let* ()=settle_record ~store ~date (Retained.listed gate) in Ok (moved+1)) (Ok 0)
    (Keeper_librarian_durable_gate.Inventory.execution_records inventory ~execution_id)
let settle_chain ~store ~inventory ~date leaf_first =
  List.fold_left (fun moved (record,_) ->
    let* moved=moved in
    let* ()=settle_record ~store ~date record in
    let* gates=settle_gates ~store ~inventory ~date ~execution_id:(Record.request_id record) in
    Ok (moved+1+gates)) (Ok 0) leaf_first
(* A replacement chain no pass needs again, as its root ID and its originals
   leaf first: the leaf settled without a replacement, and every ancestor a
   superseded basis whose acknowledged replacement is the original below it. *)
let finished_chains ~settled ~superseded listed =
  let id (record,_)=Record.request_id record in
  let find request_id=List.find_opt (fun original -> id original=request_id) listed in
  let parents=List.filter_map (fun (_,(index:Request.index)) -> Option.map
    (fun (predecessor:Request.predecessor) -> predecessor.request_id) index.predecessor) listed in
  let rec upward above ((record,(index:Request.index)) as original) =
    let above=original::above in
    match index.predecessor with
    | None -> Some (Record.request_id record,List.rev above)
    | Some predecessor ->
      match find predecessor.request_id with
      | Some ((parent,_) as next) when List.mem (id next) settled ->
        (match Progress.replacement (Record.progress parent) with
         | Some (Preparation_confirmed intended) when intended.request_id=Record.request_id record -> upward above next
         | Some (Preparation_confirmed _ | Preparation_pending _) | None -> None)
      | Some _ | None -> None in
  List.filter_map (fun ((record,_) as original) ->
    if List.mem (id original) settled && not (List.mem (id original) parents)
       && not (List.mem (id original) superseded)
       && Option.is_none (Progress.replacement (Record.progress record))
    then upward [] original else None) listed
let settle_chains ~store ~inventory chains =
  List.fold_left (fun moved (root,leaf_first) ->
    let* moved=moved in
    let* date=Request.minted_on root in
    let* count=settle_chain ~store ~inventory ~date leaf_first in
    Ok (moved+count)) (Ok 0) chains
(* A stopped settle leaves an original whose acknowledged replacement is
   already archived under the chain's day. Settle the gate records that
   replacement left, then the original and its ancestors, before validation
   needs the replacement. A missing replacement that did not move is left for
   [validate_lineage] to refuse. *)
let finish_settling ~store listed =
  let find request_id=List.find_opt (fun (record,_) -> Record.request_id record=request_id) listed in
  (* [original] and its ancestors as the root ID and the chain leaf first.
     Each ancestor must hold the one below it as its acknowledged replacement. *)
  let rec upward above ((record,(index:Request.index)) as original) =
    let* ()=match Progress.phase (Record.progress record) with
      | Rejected _ ->
        let* parent,request=io (fun () ->
          let* parent=Retained.load_listed ~store record |> Result.map_error Retained.error_to_string in
          let+ request=Request.restore ~owner:index.owner parent in parent,request) in
        let* allowed=can_replace ~store ~record:parent ~request in
        let* ()=require allowed "Archived replacement has no confirmed declaration ending" in
        let* intended=match Progress.replacement parent.progress with
          | Some (Preparation_confirmed intended) -> Ok intended
          | None | Some (Preparation_pending _) -> Error "Archived replacement has no exact publication ACK" in
        let+ _=replacement_request parent request intended in ()
      | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
      | Finished _ | Conflicted _ | Subdividing _ | Subdivided _ -> Ok () in
    let above=original::above in
    match index.predecessor with
    | None -> Ok (Record.request_id record,List.rev above)
    | Some predecessor ->
      match find predecessor.request_id with
      | None -> Error "Original history predecessor is absent"
      | Some ((parent,_) as next) ->
        if List.exists (fun (seen,_) -> Record.request_id seen=Record.request_id parent) above
        then Error "Cyclic original history predecessor lineage" else
        match Progress.replacement (Record.progress parent) with
        | Some (Preparation_confirmed intended) when intended.request_id=Record.request_id record -> upward above next
        | Some (Preparation_confirmed _ | Preparation_pending _) | None ->
          Error "Original history predecessor does not hold its archived replacement" in
  List.fold_left (fun moved ((record,(index:Request.index)) as original) ->
    let* moved=moved in
    match Progress.replacement (Record.progress record) with
    | Some (Preparation_confirmed intended) when Option.is_none (find intended.request_id) ->
      let* root,leaf_first=upward [] original in
      let* date=Request.minted_on root in
      let* archived=archived ~store ~scope:(Record.scope record) ~date intended.request_id in
      if not archived then Ok moved else
      let* inventory=io (fun () -> Keeper_librarian_durable_gate.Inventory.read ~store ~owner:index.owner) in
      let* gates=settle_gates ~store ~inventory ~date ~execution_id:intended.request_id in
      let* count=settle_chain ~store ~inventory ~date leaf_first in
      Ok (moved+gates+count)
    | Some (Preparation_confirmed _ | Preparation_pending _) | None -> Ok moved) (Ok 0) listed
(* Gate records of an archived execution no longer change validation. A stop
   between a chain root and its gate records leaves them here; a stop below
   the root leaves an ancestor that [finish_settling] reaches first. *)
let settle_orphan_gates ~store ~inventory ~scope listed =
  let discovered execution_id=List.exists (fun (record,_) ->
    Record.request_id record=execution_id) listed in
  List.fold_left (fun moved execution_id ->
    let* moved=moved in
    if discovered execution_id then Ok moved else
    let* date=Request.minted_on execution_id in
    let* archived=archived ~store ~scope ~date execution_id in
    if not archived then Ok moved else
    let* gates=settle_gates ~store ~inventory ~date ~execution_id in
    Ok (moved+gates)) (Ok 0) (Keeper_librarian_durable_gate.Inventory.executions inventory)
(* Settled originals the durable message floor can still read (RFC
   librarian-durable-message-floor 3.9), in the order the store lists them,
   which is the digest of their IDs and says nothing of age. A candidate is not
   archived with the finished history: it stays, with the steps that name it,
   until its range is published or the read positions move on. *)
let floor_candidates ~store settled =
  let* found=List.fold_left (fun found (record,request) ->
    let* found=found in
    let* candidate=Descent.candidate ~store ~record ~request in
    Ok (Option.fold ~none:found ~some:(fun candidate -> candidate::found) candidate)) (Ok []) (List.rev settled) in
  Ok (List.rev found)
let rec consume_one ~config ~keeper_name ~wake =
  let base_path=config.Workspace.base_path in
  let keepers_dir=Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let store=Lane_addon_store.of_config config in
  let reserved=reserved () in
  let error detail=Error (Consumer.Original_publication_blocked detail) in
  let wait_for_original wait record =
    let+ resolution=match wait with
      | Owner.Missing_after_dispatch ->
        Resolution_work.resolve_missing_serialized ~config ~keeper_name ~request_id:(Record.request_id record)
        |> Result.map_error Keeper_librarian_history_resolution_intent.error_to_string
      | Worker_unknown ->
        Resolution_work.resolve_cut_serialized ~config ~keeper_name ~request_id:(Record.request_id record)
        |> Result.map_error Keeper_librarian_history_resolution_intent.error_to_string
      | Worker_pending | Worker_unreachable | Journal_recheck ->
        Ok Resolution_work.Original_waiting in
    match resolution with
    | Resolution_work.Original_waiting -> pending_worker wait record
    | Reobserve_original -> wake (); pending_worker wait record
    | Resume_history ->
      (* The continuation is durable before the next unit is requested. Do
         not recursively dispatch it here: another absence must yield too. *)
      wake ();
      Keeper_librarian_pending.Publication
        {request_id=Record.request_id record;
         detail="History resolution advanced; the next Memory unit will read its continuation"} in
  (* No worker received this original and its declaration was replaced, so
     the pass ended it. Nothing was refused: the next read is not narrowed.
     The next pass moves the original and selects its range for the
     declaration of then, and no host event would start that pass. *)
  let ended_unadmitted request_id =
    Log.Keeper.info ~keeper_name
      "durable Librarian ended an original no worker received because its declaration was replaced: request=%s"
      request_id;
    wake ();
    Consumer.Memory_not_committed [Keeper_librarian_runtime.not_committed_of_failure
      ~detail:"Original history request ended before any worker received it: its declaration was replaced"
      Keeper_exact_walk_failure.empty] in
  let resume_original original =
    match resume ~store ~config ~reserved ~wake original with
    | Error detail -> error detail
    | Ok (Owner.Waited (wait, record)) ->
      (match wait_for_original wait record with
       | Ok pending -> Ok (Consumer.Pending pending)
       | Error detail -> error detail)
    | Ok (Owner.Original_replaced record) ->
      Ok (Consumer.Memory_not_committed [replacement_report record])
    | Ok (Resumed (Finished completed,request)) ->
      (match Resolution_work.record_completed_serialized ~config ~keeper_name ~request ~completed with
       | Ok () -> Ok (completed_outcome request)
       | Error failure -> error (Keeper_librarian_history_resolution_intent.error_to_string failure))
    | Ok (Resumed (Publication_waiting detail,request)) ->
      Ok (Consumer.Pending (pending_publication request detail))
    | Ok (Resumed (Basis_superseded _,request)) -> Ok (Consumer.Pending (pending_basis request))
    | Ok (Resumed (Ended_unadmitted (record:Retained.retained),_)) -> Ok (ended_unadmitted record.request_id)
    | Ok (Resumed (Refused (final,_),request)) ->
      (* Only a non-counterpart refusal marks a smaller next read. A capacity-
         only counterpart original has no message-floor coordinate; narrowing
         would change its chat window instead of splitting its model input.
         A request the host ended unrun because its declaration was replaced
         marks nothing: the next pass selects the same range for the
         declaration of then, and no host event would start that pass. *)
      let refused=Consumer.refused_original (Request.source request) [Refusal.report ~store request final] in
      (match refused with
       | Error _ -> ()
       | Ok _ ->
         match Refusal.next_read ~final with
         | Refusal.Narrowed -> Consumer.mark_range_failed ~config ~keeper_name
         | Whole_again ->
           Log.Keeper.info ~keeper_name
             "durable Librarian original was ended unrun under a replaced declaration: the next pass reads the same range whole";
           wake ());
      refused in
  match Resolution_work.run_pending_serialized ~config ~keeper_name with
  | Error failure -> error (Keeper_librarian_history_resolution_intent.error_to_string failure)
  | Ok (Some pending) -> Ok (Consumer.Pending pending)
  | Ok None ->
  (* Discovery does not initialize an epoch or create a replacement request.
     Any malformed old original fails the full inventory before fresh selection. *)
  let inventory_started=Mtime_clock.now () in
  match Owner.discover ~store ~base_path ~keepers_dir ~keeper_id:keeper_name with
  | Error failure -> error (Owner.error_to_string failure)
  | Ok listed ->
    (* A fenced original is read as its record and index when no known-basis
       link touches it: it holds no replacement intent, and its predecessor,
       if any, is fenced and holds none either. The pass does nothing more
       with such an original. An original waiting for its worker is read the
       same way (below). Every other original is read with its body. *)
    let observed_fences=List.fold_left (fun result (record,index) ->
      let* fenced=result in
      let+ fence=io (fun () -> Resolution_lineage.fenced_record ~store ~record ~index) in
      if Option.is_some fence then Record.request_id record::fenced else fenced) (Ok []) listed in
    match observed_fences with
    | Error detail -> error detail
    | Ok fenced_ids ->
    let fenced id=List.mem id fenced_ids in
    let settled_fence id=fenced id && List.exists (fun (record,_) ->
      Record.request_id record=id && Option.is_none (Progress.replacement (Record.progress record))) listed in
    let unread (record,(index:Request.index)) =
      settled_fence (Record.request_id record)
      && (match index.predecessor with
          | None -> true
          | Some predecessor -> settled_fence predecessor.request_id) in
    (* One complete read-only gate observation for this inventory pass.
       Recovery and dispatch below deliberately retain their fresh reads. *)
    let gates=match listed with
      | [] -> Ok None
      | (first,(first_index:Request.index))::_ ->
        let+ inventory=io (fun () -> Keeper_librarian_durable_gate.Inventory.read ~store
          ~owner:first_index.owner) in
        Some (Record.scope first,first_index.owner,inventory) in
    match gates with
    | Error detail -> error detail
    | Ok gates ->
    (* RFC librarian-waiting-pass-reads-records-not-bodies 3.4. An original
       admitted to its worker goes on as its record and index, and its body is
       read only where the worker's answer needs it. It holds no gate
       preparation, no gate record names it, it holds no replacement intent,
       its predecessor if any is a settled fence, and no original names it as
       a predecessor. So neither the gate check nor a known-basis link below
       compares its request. *)
    let executions=Option.fold ~none:[] ~some:(fun (_,_,inventory) ->
      Keeper_librarian_durable_gate.Inventory.executions inventory) gates in
    let parents=List.filter_map (fun (_,(index:Request.index)) -> Option.map
      (fun (predecessor:Request.predecessor) -> predecessor.request_id) index.predecessor) listed in
    let isolated (record,(index:Request.index)) =
      let id=Record.request_id record and progress=Record.progress record in
      not (fenced id) && Option.is_none index.predecessor
      && Option.is_none (Progress.preparation progress)
      && Option.is_none (Progress.replacement progress)
      && not (List.mem id parents) && not (List.mem id executions) in
    let ended=List.fold_left (fun result ((record,(index:Request.index)) as original) ->
      let* ended=result in
      if not (isolated original) then Ok ended else
      let+ replaced=Declaration_replacement.retained ~original:record ~captured:index.destination in
      if replaced then original::ended else ended) (Ok []) listed in
    match ended with
    | Error detail -> error detail
    | Ok ended ->
    let is_ended (record,_)=List.exists (fun (ended,_) ->
      Record.request_id ended=Record.request_id record) ended in
    let waits (record,(index:Request.index)) =
      let id=Record.request_id record and progress=Record.progress record in
      (match Progress.phase progress with
       | Progress.Dispatch_pending _ -> true
       | Captured | Admission_wait _ -> isolated (record,index)
       | Judged _ | Committing _ | Commit_unknown _ | Finished _
       | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ -> false)
      && not (fenced id)
      && Option.is_none (Progress.preparation progress)
      && Option.is_none (Progress.replacement progress)
      && (match index.predecessor with
          | None -> true
          | Some predecessor -> settled_fence predecessor.request_id)
      && not (List.mem id parents)
      && not (List.mem id executions) in
    let waiting=List.filter waits listed in
    let is_waiting (record,_)=List.exists (fun (waiting,_) ->
      Record.request_id waiting=Record.request_id record) waiting in
    let read=List.filter (fun original ->
      not (unread original || is_waiting original || is_ended original)) listed
      |> Owner.load_many ~store in
    match read with
    | Error failure -> error (Owner.error_to_string failure)
    | Ok read ->
    let originals=read in
    (* From here an original the pass read is its record as read with the
       body, so progress means one thing for the rest of the pass and a
       settle compares the record the pass judged. *)
    let listed=List.map (fun ((record,index) as original) ->
      match List.find_opt (fun ((read:Retained.retained),_) -> read.request_id=Record.request_id record) originals with
      | Some (read,_) -> Retained.listed read,index
      | None -> original) listed in
    match finish_settling ~store listed with
    | Error detail -> error ("Original history settle did not finish: " ^ detail)
    | Ok moved when moved>0 ->
      Log.Keeper.info ~keeper_name "durable Librarian finished an interrupted settle: records=%d" moved;
      consume_one ~config ~keeper_name ~wake
    | Ok _ ->
    let validated=match gates with
      | None -> Ok ([],[],None)
      | Some (scope,owner,inventory) ->
        let* unfinished,settled,fenced_read=List.fold_left (fun result (((record:Retained.retained),request) as original) ->
          let* unfinished,settled,fenced_read=result in
          let* fence=io (fun () -> Resolution_lineage.fenced_original ~store ~request ~original:record) in
          match fence with
          | Some _ -> Ok (unfinished,settled,record.request_id::fenced_read)
          | None ->
          let* frontier=io (fun () -> Commit.validate_inventory ~inventory ~store ~request ~record) in
          match frontier with
          | Commit.Unfinished -> Ok (Owner.Read original::unfinished,settled,fenced_read)
          | Commit.Settled -> Ok (unfinished,original::settled,fenced_read)) (Ok ([],[],[])) originals in
        (* A waiting original's fence is read again here, as the fold above
           reads it for every original it holds with its body. *)
        let* unfinished,fenced_read=List.fold_left (fun result ((record,index) as original) ->
          let* unfinished,fenced_read=result in
          let+ fence=io (fun () -> Resolution_lineage.fenced_record ~store ~record ~index) in
          match fence with
          | Some _ -> unfinished,Record.request_id record::fenced_read
          | None -> Owner.Listed original::unfinished,fenced_read) (Ok (unfinished,fenced_read)) waiting in
        Ok (unfinished,fenced_read,Some (scope,owner,inventory,settled)) in
    match validated with
    | Error detail -> error detail
    | Ok (unfinished,fenced_read,observed) ->
    (* A fence published after the first observation is one this fold saw. *)
    let fenced id=fenced id || List.mem id fenced_read in
    let unfinished=List.rev unfinished in
    (* Every pass lists the whole retained inventory and verifies each body
       it reads, so those counts and this time are what the pass costs before
       any new work. *)
    Log.Keeper.info ~keeper_name
      "durable Librarian inventory validated: originals=%d bodies_read=%d unfinished=%d gate_records=%d elapsed_ms=%.1f"
      (List.length listed) (List.length originals) (List.length unfinished)
      (Option.fold ~none:0 ~some:(fun (_,_,inventory,_) ->
         Keeper_librarian_durable_gate.Inventory.record_count inventory) observed)
      (Int64.to_float (Mtime.Span.to_uint64_ns (Mtime.span inventory_started (Mtime_clock.now ())))
       /. 1_000_000.);
    match validate_lineage ~store ~fenced ~read:originals listed with
    | Error detail -> error detail
    | Ok superseded ->
    (* Recover a host ending, or reconcile a real replaced-declaration ending,
       before arbitrating multiple waiting frontiers. Only this ending port
       is safe here: ordinary resume could dispatch or publish. Changed
       progress requires a new inventory. *)
    let rec recover_ending = function
      | [] -> Ok None
      | ((record,_) as original)::rest ->
        if fenced (Record.request_id record) then recover_ending rest else
        let* recovered=Owner.recover_terminal_ending ~store ~config ~reserved ~original
          |> Result.map_error Owner.error_to_string in
        match recovered with
        | Owner.No_ending -> recover_ending rest
        | Ending_retained record -> Ok (Some record) in
    let multiple_frontiers=List.length unfinished + List.length superseded > 1 in
    (match (if multiple_frontiers then recover_ending waiting else Ok None) with
    | Error detail -> error detail
    | Ok (Some record) ->
      wake ();
      Ok (Consumer.Pending (Keeper_librarian_pending.Publication
        {request_id=Record.request_id record;
         detail="Original host ending retained; the next pass revalidates history frontiers"}))
    | Ok None ->
    let moved=List.fold_left (fun result (record,(index:Request.index)) ->
      let* moved=result in
      let* ()=io (fun () ->
        let* _=Request.observe_index_owner ~base_path ~keepers_dir index in
        let* fence=Resolution_lineage.fenced_record ~store ~record ~index in
        let* ()=require (Option.is_none fence) "Replaced history original acquired an operator fence" in
        let* ()=Declaration_replacement.confirm_no_execution ~store ~original:record
          ~exact_digest:index.exact_digest in
        let* date=Request.minted_on (Record.request_id record) in
        Retained.settle ~store ~date record |> Result.map_error Retained.settle_error_to_string) in
      Ok (moved+1)) (Ok 0) ended in
    match moved with
    | Error detail -> error ("Before-admission replacement did not settle: " ^ detail)
    | Ok moved when moved>0 -> consume_one ~config ~keeper_name ~wake
    | Ok _ ->
    match io (fun () -> Refusal.inventory (match observed with
      | None -> [] | Some (_,_,_,settled) -> settled)) with
    | Error detail -> error ("Original history refusal inventory did not resolve: " ^ detail)
    | Ok refusals ->
    let candidates=match observed with
      | None -> Ok []
      | Some (_,_,_,settled) -> floor_candidates ~store settled in
    match candidates with
    | Error detail -> error ("Original history floor candidates did not resolve: " ^ detail)
    | Ok candidates ->
    let stops=match observed with
      | None -> Ok []
      | Some (_,_,_,settled) ->
        List.fold_left (fun stops (record,request) ->
          let* stops=stops in
          let* stop=Refusal.retained_stop ~store ~completed:refusals ~record ~request in
          Ok (Option.fold ~none:stops ~some:(fun stop -> stop::stops) stop))
          (Ok []) settled in
    match stops with
    | Error detail -> error ("Original history capacity stop did not resolve: " ^ detail)
    | Ok stops ->
    (* A permanent capacity refusal has no smaller form and its input is
       append-only, so nothing can ever cover it. Abandon its exact range with a
       typed diagnosis; the next inventory read finds it settled and releases
       the destination. A settlement that fails leaves only that stop in place:
       it keeps blocking its own destination as before, the reason is logged,
       and the next wake retries (settling is idempotent). The rest of this
       Keeper's work does not wait on it. *)
    let abandoned,stops=List.fold_left (fun (count,kept) stop ->
      match Refusal.diagnosis stop with
      | None -> count,stop::kept
      | Some _ ->
        let record,request=Refusal.original stop in
        (match io (fun () -> Commit.settle_refused ~store ~request ~record) with
         | Ok _ ->
           Log.Keeper.warn ~keeper_name
             "durable Librarian abandoned a permanently over-capacity counterpart range: request=%s"
             (Refusal.request_id stop);
           count+1,kept
         | Error detail ->
           Log.Keeper.warn ~keeper_name
             "durable Librarian could not settle a permanently over-capacity counterpart range, \
              its destination stays blocked: request=%s: %s"
             (Refusal.request_id stop) detail;
           count,stop::kept)) (0,[]) stops in
    let stops=List.rev stops in
    if abandoned>0 then consume_one ~config ~keeper_name ~wake else
    let is_candidate ((record:Retained.retained),_) =
      List.exists (fun candidate -> (Descent.record candidate).request_id=record.request_id) candidates in
    let is_stopped ((record:Retained.retained),_) =
      List.exists (fun stop -> Refusal.request_id stop=record.request_id) stops in
    let moved=match observed with
      | None -> Ok (0,0,0)
      | Some (scope,owner,inventory,settled) ->
        (* The steps go before the originals that name them, so a stop between
           the two never leaves a step without its original. *)
        let* steps=Floor_cleanup.cleanup ~store ~owner ~candidates ~settled in
        let* orphans=settle_orphan_gates ~store ~inventory ~scope listed in
        let settled=io (fun () -> List.filter (fun ((record,request) as original) ->
          not (is_candidate original || is_stopped original
            || Refusal.preserves_completed ~settled:refusals ~record ~request)) settled) in
        let ids=List.map (fun ((record:Retained.retained),_) -> record.request_id) in
        let* chains=settle_chains ~store ~inventory
          (finished_chains ~settled:(ids settled) ~superseded:(ids superseded) listed) in
        Ok (chains,orphans,steps) in
    match moved with
    | Error detail -> error ("Original history settle did not finish: " ^ detail)
    | Ok (chain_records,orphan_gates,floor_records) ->
    if chain_records+orphan_gates+floor_records>0 then
      Log.Keeper.info ~keeper_name
        "durable Librarian settled finished history: chain_records=%d orphan_gates=%d floor_records=%d"
        chain_records orphan_gates floor_records;
    let recoveries=List.filter (fun ((record:Retained.retained),_) ->
      match Progress.replacement record.progress with
      | Some (Preparation_pending _) -> true
      | None | Some (Preparation_confirmed _) -> false) originals in
    if multiple_frontiers then
      error "Completed-history Librarian has multiple unfinished original frontiers"
    else (match recoveries with
    | _::_::_ -> error "Original history has multiple unfinished replacement publications"
    | [parent] ->
      (match recover_replacement ~store parent with
       | Error detail -> error detail
       | Ok _ -> consume_one ~config ~keeper_name ~wake)
    | [] ->
    match unfinished,superseded with
    | (_::_::_),_ | _,(_::_::_) | (_::_),(_::_) ->
      error "Completed-history Librarian has multiple unfinished original frontiers"
    | [original],[] -> resume_original original
    | [],[(parent,request)] ->
      (match resolve ~config ~reserved with
       | Error detail -> error detail
       | Ok None -> error "Original history Addon is not attached; replacement source remains unconsumed"
       | Ok (Some _) ->
         let rebased=io (fun () ->
           let* anchor=Current.capture_program_anchor ~keepers_dir ~keeper_id:keeper_name in
           let snapshot=Current.program_anchor_snapshot anchor in
           let expected_revision=Option.map (fun (snapshot:Current.t) -> snapshot.revision) snapshot in
           let current=Option.map (fun (snapshot:Current.t) ->
             ({Keeper_librarian.facts=snapshot.facts}:Keeper_librarian.current_selection)) snapshot in
           Source.with_current ~expected_revision ~current (Request.source request)
           |> Result.map_error Source.error_to_string) in
         match rebased with
         | Error detail -> error detail
         | Ok source ->
           match capture ~replacement_parent:(parent,request) ~store ~config ~reserved ~keeper_name source with
           | Error detail -> error detail
           | Ok original -> resume_original (Owner.Read original))
    | [],[] ->
      let settled_records=match observed with
        | Some (_,_,_,settled) -> settled
        | None -> [] in
      let replaced_evidence (evidence:Yojson.Safe.t) =
        match evidence with
        | `Assoc fields ->
          List.exists (fun (k,v) -> k="cause" && v=`String "declaration_replaced") fields
          && List.exists (fun (k,v) -> k="status" && v=`String "not_allowed") fields
        | _ -> false in
      let drained_replaced=settled_records<>[] && List.for_all (fun ((record:Retained.retained),_) ->
        match Progress.phase record.progress with
        | Rejected {stage=Execution;evidence} -> replaced_evidence evidence
        | Rejected {stage=Before_dispatch;_} -> false
        | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _
        | Commit_unknown _ | Finished _ | Conflicted _
        | Subdividing _ | Subdivided _ -> false) settled_records in
      let* ()=
        if drained_replaced then
          let runtime_keepers_dir=Workspace.keepers_runtime_dir config in
          (match Keeper_external_read_cursor.observe ~runtime_keepers_dir ~keeper_name with
           | Error detail -> error detail
           | Ok observed ->
             (match Keeper_external_read_cursor.release_pending ~runtime_keepers_dir
                      ~keeper_name ~expected:observed with
              | Error detail -> error detail
              | Ok () -> Ok ()))
        else Ok () in
      match Refusal.blocked ~config ~reserved stops with
      | Some refusal -> Error refusal
      | None ->
      match resolve ~config ~reserved with
      | Error detail -> error detail
      | Ok None -> error "Original history Addon is not attached; source remains unconsumed"
      | Ok (Some _) ->
        let failure=ref None in
        let capacity_stop=ref None in
        let ended=ref None in
        let stop detail =
          failure := Some detail;
          Consumer.Memory_pending (Keeper_librarian_pending.Local_failure detail) in
        let before_retain destination=match Refusal.blocks_destination stops destination with
          | None -> Ok ()
          | Some refusal -> capacity_stop:=Some refusal;Error (Consumer.error_to_string refusal) in
        let new_original source =
          match capture ~before_retain ~store ~config ~reserved ~keeper_name source with
          | Error detail -> stop detail
          | Ok original ->
            match resume ~store ~config ~reserved ~wake (Owner.Read original) with
            | Error detail -> stop detail
            | Ok (Owner.Waited (wait, record)) ->
              (match wait_for_original wait record with
               | Ok pending -> Consumer.Memory_pending pending
               | Error detail -> stop detail)
            | Ok (Owner.Original_replaced record) ->
              Consumer.Memory_replaced [replacement_report record]
            | Ok (Resumed (Finished completed,request)) ->
              (match Resolution_work.record_completed_serialized ~config ~keeper_name ~request ~completed with
               | Ok () -> Consumer.Memory_committed
               | Error failure -> stop (Keeper_librarian_history_resolution_intent.error_to_string failure))
            | Ok (Resumed (Publication_waiting detail,request)) ->
              Consumer.Memory_pending (pending_publication request detail)
            | Ok (Resumed (Basis_superseded _,request)) -> Consumer.Memory_pending (pending_basis request)
            | Ok (Resumed (Ended_unadmitted (record:Retained.retained),request)) ->
              (* Not [Memory_refused]: the Consumer would keep its narrowing
                 mark for that value. The pass result is set below. *)
              ended := Some record.request_id;
              Consumer.Memory_pending (pending_publication request
                "The original ended before any worker received it")
            | Ok (Resumed (Refused (final,_),request)) -> Consumer.Memory_refused [Refusal.report ~store request final] in
        (* A refused one-turn original covers the range this pass selected. The
           pass reads that range message by message under the original, not as
           an original of its own: the host already refused it as one request. *)
        let floor candidate =
          let owner=Request.physical_owner (Descent.request candidate) in
          let superseded () =
            match Floor_cleanup.settle_chain ~store ~owner candidate with
            | Error detail -> stop detail
            | Ok moved ->
              Log.Keeper.info ~keeper_name
                "durable Librarian message floor dropped its chain after Memory changed: records=%d" moved;
              wake (); Consumer.Memory_pending (pending_basis (Descent.request candidate)) in
          match Descent.descend ~store ~config ~reserved candidate with
          | Error detail -> stop detail
          | Ok (Floor_chain.Pending pending) ->
            Log.Keeper.info ~keeper_name "durable Librarian message floor waits: %s"
              (Keeper_librarian_pending.description pending);
            Consumer.Memory_pending pending
          | Ok Floor_chain.Superseded -> superseded ()
          | Ok (Floor_chain.Declaration_replaced {position;request_id}) ->
            (match Floor_cleanup.settle_step ~store ~owner candidate ~position with
             | Error detail -> stop detail
             | Ok _ -> wake ();Consumer.Memory_replaced [replacement_report_id request_id])
          | Ok (Floor_chain.Stopped {position;report}) ->
            (* The host ended this step's ID. The steps before it stay, and the
               next pass asks the same position under a new ID. *)
            (match Floor_cleanup.settle_step ~store ~owner candidate ~position with
             | Error detail -> stop detail
             | Ok _ -> Consumer.Memory_refused [report])
          | Ok (Floor_chain.Finished finished) ->
            (match Floor_publish.publish ~candidate ~finished with
             | Error detail -> stop detail
             | Ok Floor_publish.Published -> Consumer.Memory_committed
             | Ok Floor_publish.Superseded ->
               (* Memory changed under the chain, so its decisions do not apply.
                  The next pass starts the chain again from the Memory then. *)
               superseded ()) in
        let commit source =
          match List.find_opt (fun candidate -> Descent.covers candidate source) candidates with
          | Some candidate -> floor candidate
          | None -> new_original source in
        (* A candidate proves the range too wide for one request. The Consumer
           keeps its narrowing mark in the process only, so say it again here:
           a restart would otherwise read the wide range once more. *)
        (match candidates with
         | [] -> ()
         | _::_ -> Consumer.mark_range_failed ~config ~keeper_name);
        let result=Consumer.consume_one ~config ~keeper_name ~commit in
        match !capacity_stop,!failure,!ended with
        | Some refusal,_,_ -> Error refusal
        | None,Some detail,_ -> error detail
        | None,None,Some request_id -> Ok (ended_unadmitted request_id)
        | None,None,None -> result))
