module Request = Keeper_librarian_durable_request
module Owner = Keeper_librarian_durable_owner
module Retained = Lane_addon_tool_request_owner
module Progress = Lane_addon_request_progress
module Runtime = Lane_addon_runtime
module Consumer = Keeper_librarian_durable_consumer
module Source = Keeper_librarian_durable_capture
module Current = Keeper_memory_os_current
module Commit = Keeper_librarian_durable_commit
module Submit = Lane_addon_submit_once
module Exact = Lane_addon_exact
module Descent = Keeper_librarian_floor_descent
module Floor_chain = Keeper_librarian_floor_chain
module Floor_cleanup = Keeper_librarian_floor_cleanup
module Floor_publish = Keeper_librarian_floor_publish
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
  Edge.fresh_authority ~config ~reserved ~owner:(Request.physical_owner request)
    ~expected:(Request.destination request) ()
let call = Edge.call
let refusal_report ~store request final : Keeper_librarian_runtime.not_committed =
  let detail=match final with
    | Exact.Call_final (Answered _) -> "Unexpected answered result in original history refusal"
    | Call_final (Invalid_output _ | Input_refused _ | Output_limit_reached _)
    | Outcome_unknown | Not_allowed _ | Request_id_reused ->
      "Original history request refused: " ^ Yojson.Safe.to_string (Exact.final_to_json final) in
  (* A terminal refusal ends this original ID, not its unread source. It
     reports what the host actually observed about reading less, and grants no
     consumption, capacity or skip authority. An unreadable observation reports
     none and says so, the same as a refusal that shows nothing. This report
     alone does not free a Keeper from a range it cannot read (#46398): the
     same range is chosen again until a floor reads it smaller. *)
  match io (fun () -> Request.refusal_evidence ~store request final) with
  | Ok evidence -> Keeper_librarian_runtime.not_committed_of_failure ~detail evidence
  | Error why ->
    Keeper_librarian_runtime.not_committed_of_failure
      ~detail:(detail ^ "; reading less could not be judged: " ^ why) Keeper_exact_walk_failure.empty
let resume ~store ~config ~reserved ~wake (original,request) =
  Owner.resume ~store ~config ~reserved ~original ~request ~wake ~call:(call ~config ~reserved)
    ~publish:(fun ~original ~request ~proposal ->
      Keeper_librarian_durable_commit.publish ~store ~config ~original ~request ~proposal
        ~fresh_authority:(fresh_authority ~config ~reserved request)
      |> Result.map_error (fun detail -> Owner.Rejected detail))
  |> Result.map_error Owner.error_to_string
let advance_original ~store record event =
  io (fun () -> match Retained.advance ~store ~expected:record ~event with
    | Ok (Retained.Stored record | Already_stored record) -> Ok record
    | Ok (Unconfirmed detail) -> Error detail
    | Error error -> Error (Retained.update_error_to_string error))
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
let capture ?replacement_parent ~store ~config ~reserved ~keeper_name source =
  let base_path=config.Workspace.base_path in
  let keepers_dir=Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let* owner=io (fun () ->
    let* anchor=Current.capture_program_anchor ~keepers_dir ~keeper_id:keeper_name in
    let snapshot=Current.program_anchor_snapshot anchor in
    let revision=Option.map (fun (snapshot : Current.t) -> snapshot.revision) snapshot in
    let current=Option.map (fun (snapshot : Current.t) ->
      ({Keeper_librarian.facts=snapshot.facts} : Keeper_librarian.current_selection)) snapshot in
    let* ()=require (revision=Source.expected_revision source && current=(Source.input source).current)
      "Memory changed before the original completed-history capture" in
    Request.observe_owner ~base_path ~keepers_dir ~keeper_id:keeper_name) in
  let* preparation=Keeper_librarian_runtime.prepare_durable ~now:(Time_compat.now ()) (Source.input source) in
  let request_id=Request.fresh_request_id owner in
  (* Factory/retention performs local I/O under the actual configuration/action
     serializers. capture_tool_request_owner's factory is pure, so use the
     destination publication port rather than placing I/O in that factory. *)
  with_destination ~config ~reserved (fun destination ->
    let predecessor=Option.map (fun ((parent:Retained.retained),_) ->
      {Request.request_id=parent.request_id;request_digest=parent.request_digest}) replacement_parent in
    let* request=io (fun () -> Request.create ?predecessor ~request_id ~owner ~destination ~source ~preparation ()) in
    match replacement_parent with
    | None ->
      let* original=Owner.retain ~store request |> Result.map_error Owner.error_to_string in
      Ok (original,request)
    | Some (parent,parent_request) ->
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
let validate_lineage originals =
  let find id=List.find_opt (fun ((record:Retained.retained),_) -> record.request_id=id) originals in
  let predecessors=List.filter_map (fun (_,request) -> Request.predecessor request) originals in
  let parent_ids=List.map (fun (parent:Request.predecessor) -> parent.request_id) predecessors in
  let* ()=require (List.length parent_ids=List.length (List.sort_uniq String.compare parent_ids))
    "Original history basis supersession has multiple children" in
  let* ()=List.fold_left (fun result ((child:Retained.retained),request) ->
    let* ()=result in
    match Request.predecessor request with
    | None -> Ok ()
    | Some predecessor ->
      let* parent,parent_request=Option.to_result ~none:"Original history predecessor is absent"
        (find predecessor.request_id) in
      let* ()=require (parent.request_digest=predecessor.request_digest && parent.request_id<>child.request_id)
        "Original history predecessor identity changed" in
      let* superseded=Keeper_librarian_durable_commit.is_superseded ~request:parent_request ~record:parent in
      let* ()=require superseded "Original history successor has no known superseded basis" in
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
        "Original history successor changed its immutable source or acknowledgment frontier") (Ok ()) originals in
  let* ()=List.fold_left (fun result ((parent:Retained.retained),request) ->
    let* ()=result in match Progress.replacement parent.progress with
    | None -> Ok ()
    | Some (Preparation_pending intended | Preparation_confirmed intended) ->
      let* superseded=Keeper_librarian_durable_commit.is_superseded ~request ~record:parent in
      let* ()=require superseded "Original history replacement intent has no superseded basis" in
      let* _=replacement_request parent request intended in
      (match find intended.request_id,Progress.replacement parent.progress with
       | None,Some (Preparation_confirmed _) -> Error "Acknowledged original history replacement is missing"
       | None,Some (Preparation_pending _) -> Ok ()
       | Some (_,child),Some (Preparation_pending _ | Preparation_confirmed _) ->
         equal_json (Request.to_json child) intended.request "Original history forward replacement payload changed"
       | (None | Some _),None -> Error "Original history replacement intent disappeared")) (Ok ()) originals in
  let rec ancestry seen request = match Request.predecessor request with
    | None -> Ok ()
    | Some predecessor ->
      let* ()=require (not (List.mem predecessor.request_id seen)) "Cyclic original history predecessor lineage" in
      let* _,parent=Option.to_result ~none:"Original history predecessor disappeared" (find predecessor.request_id) in
      ancestry (predecessor.request_id::seen) parent in
  let* ()=List.fold_left (fun result ((record:Retained.retained),request) ->
    let* ()=result in ancestry [record.request_id] request) (Ok ()) originals in
  Ok (List.filter (fun ((record:Retained.retained),_) ->
    match Progress.phase record.progress with
    | Progress.Conflicted _ -> not (List.mem record.request_id parent_ids)
    | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
    | Finished _ | Rejected _ | Subdividing _ | Subdivided _ -> false) originals)
(* RFC-librarian-history-settles-finished-originals. A chain settles leaf
   first under the day its root was minted, as Workspace Curator chains do:
   each history record, then the gate records of that execution. Every body
   holds its own request ID, so no two records share a body file and a move
   never takes another record's body. *)
let settle_record ~store ~date (record:Retained.retained) =
  Retained.settle ~store ~date (Retained.listed record)
  |> Result.map_error Retained.settle_error_to_string
let archived ~store ~scope ~date request_id =
  io (fun () -> Retained.settled ~store ~scope ~date ~request_id)
  |> Result.map_error Retained.error_to_string
let settle_gates ~store ~inventory ~date ~execution_id =
  List.fold_left (fun moved gate ->
    let* moved=moved in
    let* ()=settle_record ~store ~date gate in Ok (moved+1)) (Ok 0)
    (Keeper_librarian_durable_gate.Inventory.execution_records inventory ~execution_id)
let settle_chain ~store ~inventory ~date leaf_first =
  List.fold_left (fun moved ((record:Retained.retained),_) ->
    let* moved=moved in
    let* ()=settle_record ~store ~date record in
    let* gates=settle_gates ~store ~inventory ~date ~execution_id:record.request_id in
    Ok (moved+1+gates)) (Ok 0) leaf_first
(* A replacement chain no pass needs again, as its root ID and its originals
   leaf first: the leaf settled without a replacement, and every ancestor a
   superseded basis whose acknowledged replacement is the original below it. *)
let finished_chains ~settled ~superseded originals =
  let id ((record:Retained.retained),_)=record.request_id in
  let mem original list=List.exists (fun other -> id other=id original) list in
  let find request_id=List.find_opt (fun original -> id original=request_id) originals in
  let parents=List.filter_map (fun (_,request) -> Option.map
    (fun (predecessor:Request.predecessor) -> predecessor.request_id) (Request.predecessor request)) originals in
  let rec upward above (((record:Retained.retained),request) as original) =
    let above=original::above in
    match Request.predecessor request with
    | None -> Some (record.request_id,List.rev above)
    | Some predecessor ->
      match find predecessor.request_id with
      | Some (((parent:Retained.retained),_) as next) when mem next settled ->
        (match Progress.replacement parent.progress with
         | Some (Preparation_confirmed intended) when intended.request_id=record.request_id -> upward above next
         | Some (Preparation_confirmed _ | Preparation_pending _) | None -> None)
      | Some _ | None -> None in
  List.filter_map (fun (((record:Retained.retained),_) as original) ->
    if mem original settled && not (List.mem record.request_id parents) && not (mem original superseded)
       && Option.is_none (Progress.replacement record.progress)
    then upward [] original else None) originals
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
let finish_settling ~store originals =
  let find request_id=List.find_opt (fun ((record:Retained.retained),_) -> record.request_id=request_id) originals in
  (* [original] and its ancestors as the root ID and the chain leaf first.
     Each ancestor must hold the one below it as its acknowledged replacement. *)
  let rec upward above (((record:Retained.retained),request) as original) =
    let above=original::above in
    match Request.predecessor request with
    | None -> Ok (record.request_id,List.rev above)
    | Some predecessor ->
      match find predecessor.request_id with
      | None -> Error "Original history predecessor is absent"
      | Some (((parent:Retained.retained),_) as next) ->
        if List.exists (fun ((seen:Retained.retained),_) -> seen.request_id=parent.request_id) above
        then Error "Cyclic original history predecessor lineage" else
        match Progress.replacement parent.progress with
        | Some (Preparation_confirmed intended) when intended.request_id=record.request_id -> upward above next
        | Some (Preparation_confirmed _ | Preparation_pending _) | None ->
          Error "Original history predecessor does not hold its archived replacement" in
  List.fold_left (fun moved (((record:Retained.retained),request) as original) ->
    let* moved=moved in
    match Progress.replacement record.progress with
    | Some (Preparation_confirmed intended) when Option.is_none (find intended.request_id) ->
      let* root,leaf_first=upward [] original in
      let* date=Request.minted_on root in
      let* archived=archived ~store ~scope:record.scope ~date intended.request_id in
      if not archived then Ok moved else
      let* inventory=io (fun () -> Keeper_librarian_durable_gate.Inventory.read ~store
        ~owner:(Request.physical_owner request)) in
      let* gates=settle_gates ~store ~inventory ~date ~execution_id:intended.request_id in
      let* count=settle_chain ~store ~inventory ~date leaf_first in
      Ok (moved+gates+count)
    | Some (Preparation_confirmed _ | Preparation_pending _) | None -> Ok moved) (Ok 0) originals
(* Gate records of an archived execution no longer change validation. A stop
   between a chain root and its gate records leaves them here; a stop below
   the root leaves an ancestor that [finish_settling] reaches first. *)
let settle_orphan_gates ~store ~inventory ~scope originals =
  let discovered execution_id=List.exists (fun ((record:Retained.retained),_) ->
    record.request_id=execution_id) originals in
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
  let store=Lane_addon_store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
  let reserved=reserved () in
  let error detail=Error (Consumer.Original_publication_blocked detail) in
  let resume_original ((_,request) as original) =
    match resume ~store ~config ~reserved ~wake original with
    | Error detail -> error detail
    | Ok (Owner.Finished _) -> Ok (completed_outcome request)
    | Ok (Pending _ | Publication_waiting _ | Basis_superseded _) -> Ok Consumer.Pending
    | Ok (Refused (final,_)) ->
      (* The host's refusal reached this pass, not the Consumer's commit, so
         the Consumer did not narrow the next read as it does after a failed
         commit. Without the mark the same wide range is read again. *)
      Consumer.mark_range_failed ~config ~keeper_name;
      Consumer.refused_original (Request.source request) [refusal_report ~store request final] in
  (* Discovery does not initialize an epoch or create a replacement request.
     Any malformed old original fails the full inventory before fresh selection. *)
  let inventory_started=Mtime_clock.now () in
  match Owner.discover ~store ~base_path ~keepers_dir ~keeper_id:keeper_name with
  | Error failure -> error (Owner.error_to_string failure)
  | Ok originals ->
    match finish_settling ~store originals with
    | Error detail -> error ("Original history settle did not finish: " ^ detail)
    | Ok moved when moved>0 ->
      Log.Keeper.info ~keeper_name "durable Librarian finished an interrupted settle: records=%d" moved;
      consume_one ~config ~keeper_name ~wake
    | Ok _ ->
    let validated=match originals with
      | [] -> Ok ([],None)
      | ((first:Retained.retained),request)::_ ->
        (* One complete read-only gate observation for this inventory pass.
           Recovery and dispatch below deliberately retain their fresh reads. *)
        let* inventory=io (fun () -> Keeper_librarian_durable_gate.Inventory.read ~store
          ~owner:(Request.physical_owner request)) in
        let* unfinished,settled=List.fold_left (fun result ((record,request) as original) ->
          let* unfinished,settled=result in
          let* frontier=io (fun () -> Commit.validate_inventory ~inventory ~store ~request ~record) in
          match frontier with
          | Commit.Unfinished -> Ok (original::unfinished,settled)
          | Commit.Settled -> Ok (unfinished,original::settled)) (Ok ([],[])) originals in
        Ok (unfinished,Some (first.scope,Request.physical_owner request,inventory,settled)) in
    match validated with
    | Error detail -> error detail
    | Ok (unfinished,observed) ->
    let unfinished=List.rev unfinished in
    (* Every pass reads and verifies the whole retained inventory, so its size
       and time are what the pass costs before any new work. *)
    Log.Keeper.info ~keeper_name
      "durable Librarian inventory validated: originals=%d unfinished=%d gate_records=%d elapsed_ms=%.1f"
      (List.length originals) (List.length unfinished)
      (Option.fold ~none:0 ~some:(fun (_,_,inventory,_) ->
         Keeper_librarian_durable_gate.Inventory.record_count inventory) observed)
      (Int64.to_float (Mtime.Span.to_uint64_ns (Mtime.span inventory_started (Mtime_clock.now ())))
       /. 1_000_000.);
    match validate_lineage originals with
    | Error detail -> error detail
    | Ok superseded ->
    let candidates=match observed with
      | None -> Ok []
      | Some (_,_,_,settled) -> floor_candidates ~store settled in
    match candidates with
    | Error detail -> error ("Original history floor candidates did not resolve: " ^ detail)
    | Ok candidates ->
    let is_candidate ((record:Retained.retained),_) =
      List.exists (fun candidate -> (Descent.record candidate).request_id=record.request_id) candidates in
    let moved=match observed with
      | None -> Ok (0,0,0)
      | Some (scope,owner,inventory,settled) ->
        (* The steps go before the originals that name them, so a stop between
           the two never leaves a step without its original. *)
        let* steps=Floor_cleanup.cleanup ~store ~owner ~candidates in
        let* orphans=settle_orphan_gates ~store ~inventory ~scope originals in
        let settled=List.filter (fun original -> not (is_candidate original)) settled in
        let* chains=settle_chains ~store ~inventory (finished_chains ~settled ~superseded originals) in
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
    if List.length unfinished + List.length superseded > 1 then
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
           | Ok original -> resume_original original)
    | [],[] ->
      match resolve ~config ~reserved with
      | Error detail -> error detail
      | Ok None -> error "Original history Addon is not attached; source remains unconsumed"
      | Ok (Some _) ->
        let failure=ref None in
        let stop detail=failure:=Some detail;Consumer.Memory_pending in
        let new_original source =
          match capture ~store ~config ~reserved ~keeper_name source with
          | Error detail -> stop detail
          | Ok original ->
            match resume ~store ~config ~reserved ~wake original with
            | Error detail -> stop detail
            | Ok (Owner.Finished _) -> Consumer.Memory_committed
            | Ok (Pending _ | Publication_waiting _ | Basis_superseded _) -> Consumer.Memory_pending
            | Ok (Refused (final,_)) -> Consumer.Memory_refused [refusal_report ~store (snd original) final] in
        (* A refused one-turn original covers the range this pass selected. The
           pass reads that range message by message under the original, not as
           an original of its own: the host already refused it as one request. *)
        let floor candidate =
          let owner=Request.physical_owner (Descent.request candidate) in
          match Descent.descend ~store ~config ~reserved candidate with
          | Error detail -> stop detail
          | Ok (Floor_chain.Pending detail) ->
            Log.Keeper.info ~keeper_name "durable Librarian message floor waits: %s" detail;
            Consumer.Memory_pending
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
               (match Floor_cleanup.settle_chain ~store ~owner candidate with
                | Error detail -> stop detail
                | Ok moved ->
                  Log.Keeper.info ~keeper_name
                    "durable Librarian message floor dropped its chain after Memory changed: records=%d" moved;
                  wake ();Consumer.Memory_pending)) in
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
        match !failure with Some detail -> error detail | None -> result)
