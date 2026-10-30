module Capture = Workspace_memory_execution_capture
module Owner = Lane_addon_tool_request_owner
module Progress = Lane_addon_request_progress
module Exact = Lane_addon_exact
module Runtime = Lane_addon_runtime
module Binding = Server_workspace_memory_addon_validation
module Ledger = Workspace_memory_ledger
module Briefing = Workspace_memory_briefing
module Context = Workspace_memory_context

module Submit = Lane_addon_submit_once
open Result.Syntax

type error = Submit.error = Unavailable of string | Rejected of string | Uncertain of string
let error_to_string = Submit.error_to_string
let runtime_error = Submit.error_of_runtime
let owned value = Result.map_error (fun error -> Unavailable (Owner.error_to_string error)) value
let rejected value = Result.map_error (fun detail -> Rejected detail) value
let reserved () =
  List.map (fun (schema : Masc_domain.tool_schema) -> schema.name) Config.raw_all_tool_schemas
  @ (Keeper_tool_descriptor.all_descriptors () |> List.concat_map Keeper_tool_descriptor.registered_names)
  |> List.sort_uniq String.compare
let resolve ~config ~reserved =
  let snapshot=Runtime.tool_export_snapshot ~config ~access:Lane_addon_sources.Operator_configuration ~reserved in
  match List.find_opt (fun (conflict : Lane_addon_tool_export.conflict) -> conflict.name=Binding.tool) snapshot.conflicts with
  | Some conflict -> Error (Rejected (Lane_addon_tool_export.conflict_to_string conflict))
  | None -> (match List.find_opt (fun (export : Runtime.tool_export) -> export.tool.name=Binding.tool) snapshot.exports with
      | Some export -> Ok export
      | None -> Error (Unavailable (match Lane_addon_unready.summary
          (Lane_addon_unready.declaring ~name:Binding.tool snapshot.unready) with
        | Some reason -> reason
        | None -> "No attached Add-on provides curate")))
let same_semantic_destination (actual:Runtime.tool_request_destination) (expected:Capture.destination) =
  actual.installation_id=expected.installation_id && actual.package_id=expected.package_id
  && actual.tool=expected.tool && actual.configuration_revision=expected.configuration_revision
let destination ~config =
  let reserved=reserved () in
  let* export=resolve ~config ~reserved in
  Runtime.with_tool_request_destination ~config ~access:Lane_addon_sources.Operator_configuration
    ~reserved ~export ~publish:(fun destination -> Ok destination) |> Result.map_error runtime_error
let captured_destination (destination : Runtime.tool_request_destination) : Capture.destination = {
  installation_id=destination.installation_id;package_id=destination.package_id;tool=destination.tool;
  source_revision=destination.source_revision;configuration_revision=destination.configuration_revision}
let capture ~config ~request_id make =
  let reserved=reserved () in
  let* export=resolve ~config ~reserved in
  let* workspace=Systhread_host.run (fun () -> Capture.observe_workspace ~base_path:config.Workspace.base_path)
    |> Result.map_error (fun detail -> Unavailable detail) in
  Runtime.capture_tool_request_owner ~config ~access:Lane_addon_sources.Operator_configuration ~reserved ~export
    ~scope:Capture.scope ~request_id:(Capture.Request_id.to_string request_id)
    ~capture:(fun (destination : Runtime.tool_request_destination) ->
      let* ()=if destination.package_id=Binding.package_id && destination.tool=Binding.tool then Ok ()
        else Error "Curator capture requires its declared package and tool" in
      let* capture=make ~workspace ~destination in
      let* summary=Capture.summary capture in
      Ok (capture,Capture.to_json capture,Capture.Summary.to_json summary)) |> Result.map_error runtime_error
let capture_classification ~config ~request_id ~prompt ~ledger ~batch =
  let* stored_ledger=Systhread_host.run (fun () ->
    Workspace_memory_revision.write_ledger ~base_path:config.Workspace.base_path ledger)
    |> Result.map_error (fun error -> Unavailable (Workspace_memory_revision.write_error_to_string error)) in
  capture ~config ~request_id (fun ~workspace ~destination ->
    let* capture=Capture.classification ~request_id ~workspace ~destination:(captured_destination destination)
      ~prompt ~ledger ~stored_ledger ~batch in
    (* The batch was sized against this destination's frame before capture.
       A package changed since then is refused here; the next pass sizes again. *)
    let* ()=Binding.check_frame ~max_reply_bytes:destination.max_reply_bytes capture in
    Ok capture)
let capture_briefing ~config ~prompt ~batch =
  let* current=Systhread_host.run (fun () ->
    Briefing.load ~directory:(Ledger.directory ~base_path:config.Workspace.base_path))
    |> Result.map_error (fun detail -> Unavailable detail) in
  let* ()=if Yojson.Safe.equal (Briefing.to_json current) (Briefing.to_json (Briefing.prepared_state batch))
    then Ok () else Error (Rejected "Confirm the original prepared briefing state before capturing model work") in
  let request_id=Capture.Request_id.fresh () in
  capture ~config ~request_id (fun ~workspace ~destination ->
    Capture.briefing ~request_id ~workspace ~destination:(captured_destination destination) ~prompt ~batch)

type wait = Submit.wait = Capacity | Worker_pending | Worker_unknown | Worker_unreachable
  | Missing_after_dispatch | Journal_recheck
type result =
  | Awaiting of wait * Owner.retained
  | Judgment of {capture:Capture.t;record:Owner.retained;final:Exact.final;expected:Capture.expected_commit}
  | Terminal of Exact.final * Owner.retained
  | Commit_pending of Owner.retained
  | Settled of Owner.retained

type publication = Submit.publication = New of Owner.retained | Acknowledged of Owner.retained
let advance = Submit.advance
let record = Submit.record
let terminal ~capture ~record final =
  match final with
  | Exact.Call_final (Exact.Answered {output;_}) ->
    let* expected=rejected (Capture.validate_output capture (Exact.checked_json output)) in
    Ok (Judgment {capture;record;final;expected})
  | Exact.Call_final (Exact.Invalid_output _ | Exact.Input_refused _ | Exact.Output_limit_reached _)
  | Exact.Outcome_unknown | Exact.Not_allowed _ | Exact.Request_id_reused -> Ok (Terminal (final,record))
let restore ~store ~workspace original =
  Server_workspace_memory_curator_pass.restore ~run:Systhread_host.run (fun () -> Capture.restore ~workspace
    ~load:(fun ~request_id -> Owner.load ~store ~scope:Capture.scope ~request_id
      |> Result.map_error Owner.error_to_string) original) |> rejected
let restore_original ~config ~request_id =
  let store=Lane_addon_store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
  let* original=Systhread_host.run (fun () -> Owner.load ~store ~scope:Capture.scope ~request_id) |> owned in
  let* original=match original with Some original -> Ok original
    | None -> Error (Unavailable "Original Curator capture disappeared") in
  let* workspace=Systhread_host.run (fun () -> Capture.observe_workspace ~base_path:config.Workspace.base_path)
    |> Result.map_error (fun detail -> Unavailable detail) in
  restore ~store ~workspace original
let resume_with ~store ~base_path ~request_id ~prepare ~call =
  let* original=Systhread_host.run (fun () -> Owner.load ~store ~scope:Capture.scope ~request_id) |> owned in
  let* original=match original with Some original -> Ok original
    | None -> Error (Unavailable "Original Curator request is absent; resume cannot recreate it") in
  let* workspace=Systhread_host.run (fun () -> Capture.observe_workspace ~base_path)
    |> Result.map_error (fun detail -> Unavailable detail) in
  let* capture=restore ~store ~workspace original in
  let* request=rejected (Binding.request capture) in
  let* resumed=Submit.resume ~store ~label:"Curator" ~original ~request
    ~schema:(Capture.output_schema capture) ~prepare ~call
    ~terminal:(fun record final -> terminal ~capture ~record final) in
  match resumed with
  | Submit.Awaiting (wait,record) -> Ok (Awaiting (wait,record))
  | Submit.Final result -> Ok result
  | Submit.Commit_pending record -> Ok (Commit_pending record)
  | Submit.Settled record -> Ok (Settled record)
let resume ~config ~request_id =
  let reserved=reserved () in
  let store=Lane_addon_store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
  let rebind () =
    let* export=resolve ~config ~reserved in
    (* Re-retain the exact original capture through the live Runtime owner.
       This checks logical destination without replacing captured revisions. *)
    let* original=Systhread_host.run (fun () -> Owner.load ~store ~scope:Capture.scope ~request_id) |> owned in
    let* original=match original with Some record -> Ok record
      | None -> Error (Unavailable "Original Curator capture disappeared") in
    let* ()=Runtime.capture_tool_request_owner ~config ~access:Lane_addon_sources.Operator_configuration
      ~reserved ~export ~scope:Capture.scope ~request_id
      ~capture:(fun destination ->
        if destination.installation_id=original.installation_id && destination.package_id=original.package_id
           && destination.tool=original.tool then Ok ((),original.request,original.summary)
        else Error "Another installation cannot resume the original Curator request")
      |> Result.map_error runtime_error in
    Ok export in
  let call ~arguments =
    match rebind () with
    | Error error -> Error (Submit.Not_sent error)
    | Ok export ->
      Runtime.call_exported_tool_with_principal ~principal:(Some Lane_addon_call_context.Operator)
        ~config ~access:Lane_addon_sources.Operator_configuration ~reserved ~export ~arguments
      |> Result.map_error Submit.call_error_of_runtime in
  resume_with ~store ~base_path:config.Workspace.base_path ~request_id
    ~prepare:(fun () -> Result.map ignore (rebind ())) ~call

type commit_result = Commit_waiting of Owner.retained | Committed of Owner.retained
  | Commit_conflict of Owner.retained
type write_permission = Newly_stored | Recovering
let domain_json kind state = `Assoc ["kind",`String kind;"state",state]
let ledger_json ledger=domain_json "classification" (Ledger.to_json ledger)
let briefing_json state=domain_json "briefing" (Briefing.to_json state)
let commit_plan capture judgment = rejected (Capture.commit_plan capture ~judgment)
let load_domain ~base_path = function
  | Capture.Classification_commit _ -> Ledger.load ~base_path |> Result.map ledger_json
  | Capture.Briefing_commit _ -> Briefing.load ~directory:(Ledger.directory ~base_path) |> Result.map briefing_json
let save_domain ~base_path = function
  | Capture.Classification_commit ledger -> Ledger.save ~base_path ledger
  | Capture.Briefing_commit state -> Briefing.save ~directory:(Ledger.directory ~base_path) state
let classification_current ~base_path ~ledger ~selected =
  let* context=Context.collect ~base_path |> Result.map_error (fun detail -> Unavailable detail) in
  let keepers=Context.keepers context in
  let unavailable observation=match observation with
    | Context.Unavailable detail -> Some detail | Context.Missing | Context.Available _ -> None in
  let rec readable = function
    | [] -> Ok ()
    | (pending : Ledger.pending_fact)::rest ->
      let keeper_id,check=match pending.fact with
        | Ledger.Ordinary {keeper_id;_} -> keeper_id,(fun (keeper : Context.keeper) -> unavailable keeper.ordinary)
        | Ledger.Source_bound {keeper_id;_} -> keeper_id,(fun (keeper : Context.keeper) -> unavailable keeper.source_bound) in
      let* ()=match List.find_opt (fun (keeper : Context.keeper) -> keeper.keeper_id=keeper_id) keepers with
        | None -> Ok ()
        | Some keeper -> (match check keeper with None -> Ok () | Some detail -> Error (Unavailable detail)) in
      readable rest in
  let* ()=readable selected in
  let current=Ledger.reconcile ledger keepers in
  Ok (Yojson.Safe.equal (Ledger.to_json current.ledger) (Ledger.to_json ledger)
      && List.for_all (fun pending -> List.mem pending current.current_facts) selected)
let eligible ~base_path ~briefing_contract capture = match Capture.work capture with
  | Capture.Classification {ledger;batch;_} ->
    Systhread_host.run (fun () -> classification_current ~base_path ~ledger ~selected:batch.selected)
  | Capture.Briefing batch ->
    (* Resolve live authority on the original caller, at this eligibility check.
       The worker receives only a captured contract and performs disk reads. *)
    let contract=briefing_contract () in
    Systhread_host.run (fun () ->
      let* ledger=Ledger.load ~base_path |> Result.map_error (fun detail -> Unavailable detail) in
      Briefing.batch_is_current ~sources:(Ledger.briefing_sources ledger) ~contract batch
      |> rejected)
let successor_is_current ~config ~capture =
  let reserved=reserved () in
  let* export=resolve ~config ~reserved in
  let* matching=Runtime.with_tool_request_destination ~config ~access:Lane_addon_sources.Operator_configuration
    ~reserved ~export ~publish:(fun actual -> Ok (same_semantic_destination actual (Capture.destination capture)))
    |> Result.map_error runtime_error in
  if not matching then Ok false else
  let base_path=config.Workspace.base_path in
  let briefing_contract ()=Briefing.contract
    ~template:(Prompt_registry.resolve_prompt Prompt_names.workspace_memory_briefing).effective in
  let* same_before=Systhread_host.run (fun () ->
    match Capture.work capture with
      | Capture.Classification {ledger;_} ->
        let* current=Ledger.load ~base_path |> Result.map_error (fun detail -> Unavailable detail) in
        Ok (Yojson.Safe.equal (Ledger.to_json current) (Ledger.to_json ledger))
      | Capture.Briefing batch ->
        let* current=Briefing.load ~directory:(Ledger.directory ~base_path)
          |> Result.map_error (fun detail -> Unavailable detail) in
        Ok (Yojson.Safe.equal (Briefing.to_json current) (Briefing.to_json (Briefing.prepared_state batch)))) in
  if not same_before then Ok false else eligible ~base_path ~briefing_contract capture
let settle_with ~store ~base_path ~request_id ~briefing_contract ~save =
  let* original=Systhread_host.run (fun () -> Owner.load ~store ~scope:Capture.scope ~request_id) |> owned in
  let* original=match original with Some record -> Ok record
    | None -> Error (Unavailable "Original Curator commit is absent") in
  let* workspace=Systhread_host.run (fun () -> Capture.observe_workspace ~base_path)
    |> Result.map_error (fun detail -> Unavailable detail) in
  let* capture=restore ~store ~workspace original in
  let phase=Progress.phase original.progress in
  let* judgment,stored=match phase with
    | Progress.Judged judgment -> Ok (judgment,None)
    | Progress.Committing commit | Progress.Commit_unknown (commit,_)
    | Progress.Finished commit | Progress.Conflicted (commit,_) -> Ok (commit.judgment,Some commit)
    | Progress.Captured | Progress.Admission_wait _ | Progress.Dispatch_pending _ | Progress.Rejected _ | Progress.Subdividing _ | Progress.Subdivided _ ->
      Error (Rejected "Original Curator request has no domain judgment to commit") in
  let* expected,change=commit_plan capture judgment in
  let* ()=match stored with
    | None -> Ok ()
    | Some commit -> if Yojson.Safe.equal commit.change.before change.before
        && Yojson.Safe.equal commit.change.after change.after then Ok ()
      else Error (Rejected "Recorded commit differs from its original captured domain states") in
  let publish original event=Systhread_host.run (fun () -> advance ~store original event) in
  let uncertain (original : Owner.retained) detail =
    let evidence=`Assoc ["detail",`String detail] in
    match Progress.phase original.progress with
    | Progress.Commit_unknown (_,previous) when Yojson.Safe.equal previous evidence -> Error (Uncertain detail)
    | Progress.Captured | Progress.Admission_wait _ | Progress.Dispatch_pending _ | Progress.Judged _
    | Progress.Committing _ | Progress.Commit_unknown _ | Progress.Finished _ | Progress.Conflicted _ | Progress.Rejected _ | Progress.Subdividing _ | Progress.Subdivided _ ->
      let* _=publish original (Progress.Commit_uncertain evidence) in Error (Uncertain detail) in
  let observe original event ctor =
    let* published=publish original event in Ok (ctor (record published)) in
  let fresh ()=Systhread_host.run (fun () -> load_domain ~base_path expected) in
  let confirm original = match fresh () with
    | Error detail -> uncertain original detail
    | Ok current ->
      if Yojson.Safe.equal current change.after then observe original (Progress.Commit_observed current) (fun r -> Committed r)
      else if Yojson.Safe.equal current change.before then uncertain original "Domain save returned without a confirmed after-state"
      else observe original (Progress.Commit_conflicted current) (fun r -> Commit_conflict r) in
  let write original =
    match Systhread_host.run (fun () -> save expected) with
    | Error detail -> uncertain original detail
    | Ok () -> confirm original
    | exception ex ->
      let backtrace=Printexc.get_raw_backtrace () in
      Eio.Cancel.protect (fun () ->
        match uncertain original "Domain save raised; publication remains uncertain" with
        | Ok _ | Error _ -> () | exception _ -> ());
      Printexc.raise_with_backtrace ex backtrace in
  let rec recover ~permission original =
    match fresh () with
    | Error detail -> uncertain original detail
    | Ok current ->
      (* After first: even a no-op or an already-applied result never repeats a
         write or borrows today's source/contract as a new model authority. *)
      if Yojson.Safe.equal current change.after then observe original (Progress.Commit_observed current) (fun r -> Committed r)
      else if not (Yojson.Safe.equal current change.before) then
        observe original (Progress.Commit_conflicted current) (fun r -> Commit_conflict r)
      else
        let* current_sources=eligible ~base_path ~briefing_contract capture in
        if not current_sources then
          observe original (Progress.Commit_conflicted (`Assoc ["state",current;"reason",`String "Original sources or contract changed"]))
            (fun r -> Commit_conflict r)
        else match permission with
        | Newly_stored -> write original
        | Recovering -> match Progress.phase original.progress with
          | Progress.Committing _ ->
            let* published=publish original (Progress.Commit_uncertain (`Assoc ["detail",`String "Recovered original commit intent"])) in
            (match published with
             | Acknowledged record -> Ok (Commit_waiting record)
             | New record -> recover ~permission:Recovering record)
          | Progress.Commit_unknown _ ->
            let* published=publish original (Progress.Commit_retry_observed current) in
            (match published with
             | Acknowledged record -> Ok (Commit_waiting record)
             | New record -> recover ~permission:Newly_stored record)
          | Progress.Captured | Progress.Admission_wait _ | Progress.Dispatch_pending _ | Progress.Judged _
          | Progress.Finished _ | Progress.Conflicted _ | Progress.Rejected _ | Progress.Subdividing _ | Progress.Subdivided _ ->
            Error (Rejected "Domain recovery lost its original commit intent") in
  match phase with
  | Progress.Finished _ -> Ok (Committed original)
  | Progress.Conflicted _ -> Ok (Commit_conflict original)
  | Progress.Judged _ ->
    let* published=publish original (Progress.Commit_intended change) in
    (match published with
     | Acknowledged record -> Ok (Commit_waiting record)
     | New record -> recover ~permission:Newly_stored record)
  | Progress.Committing _ | Progress.Commit_unknown _ -> recover ~permission:Recovering original
  | Progress.Captured | Progress.Admission_wait _ | Progress.Dispatch_pending _ | Progress.Rejected _ | Progress.Subdividing _ | Progress.Subdivided _ ->
    Error (Rejected "Original Curator request is not ready to commit")
let settle ~config ~request_id =
  let base_path=config.Workspace.base_path in
  let store=Lane_addon_store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
  let briefing_contract ()=let prompt=Prompt_registry.resolve_prompt Prompt_names.workspace_memory_briefing in
    Briefing.contract ~template:prompt.effective in
  settle_with ~store ~base_path ~request_id ~briefing_contract ~save:(save_domain ~base_path)
type successor_result = Indivisible of Owner.retained | Successor_waiting of Owner.retained
  | Successor_ready of {parent:Owner.retained;child:Owner.retained}
let read_original ~store ~request_id = Systhread_host.run (fun () ->
  Owner.load ~store ~scope:Capture.scope ~request_id) |> owned
(* The parent read again, with the workspace it is restored in and its
   restored capture. *)
let restore_parent ~store ~base_path ~request_id =
  let* parent = read_original ~store ~request_id in
  let* parent = match parent with Some parent -> Ok parent
    | None -> Error (Unavailable "Original Curator size refusal is absent") in
  let* workspace = Systhread_host.run (fun () -> Capture.observe_workspace ~base_path)
    |> Result.map_error (fun detail -> Unavailable detail) in
  let* original = restore ~store ~workspace parent in
  Ok (parent,workspace,original)
let derive_successor original (refusal : Progress.refusal) child_id =
  let* final = match refusal.stage with
    | Progress.Execution ->
      rejected (Exact.retained_final_of_json ~schema:(Capture.output_schema original) refusal.evidence)
      |> Result.map Exact.delivered
    | Progress.Before_dispatch -> Error (Rejected "A pre-dispatch refusal cannot create a Curator successor") in
  rejected (Capture.narrow ~request_id:child_id ~final original)
(* Complete the successor intent [parent]'s record holds: retain the child
   derived again from the parent, read it back and acknowledge it. Returns
   the acknowledged parent and the child. *)
let complete_with ~store ~workspace ~original (parent : Owner.retained) =
  let validate_intent refusal (intent : Progress.successor) =
    let* id = rejected (Capture.Request_id.of_string intent.request_id) in
    let* child = derive_successor original refusal id in
    let* child = match child with Some child -> Ok child
      | None -> Error (Rejected "An indivisible original batch cannot have a successor") in
    let* digest = rejected (Owner.request_digest (Capture.to_json child)) in
    let* () = if String.equal digest intent.request_digest then Ok ()
      else Error (Rejected "Stored successor differs from the original whole-batch reduction") in
    Ok child in
  let finish parent (intent : Progress.successor) =
    let* child = read_original ~store ~request_id:intent.request_id in
    let* child = match child with Some child -> Ok child
      | None -> Error (Unavailable "The original child capture is absent; acknowledged work cannot be recreated") in
    let* () = if String.equal child.Owner.request_digest intent.request_digest then Ok ()
      else Error (Rejected "Retained child differs from its original parent intent") in
    let* _ = restore ~store ~workspace child in
    Ok (parent,child) in
  match Progress.phase parent.progress with
  | Progress.Subdividing (refusal,intent) ->
    (* The intent names the child by digest; the child retained is the one
       derived again from the parent, which [validate_intent] matched to it. *)
    let* child = validate_intent refusal intent in
    let* summary = rejected (Capture.summary child) in
    let destination = Capture.destination child in
    let* () = Systhread_host.run (fun () ->
      Owner.retain ~store ~scope:Capture.scope ~request_id:intent.request_id
        ~installation_id:destination.installation_id ~package_id:destination.package_id
        ~tool:destination.tool ~summary:(Capture.Summary.to_json summary) ~request:(Capture.to_json child))
      |> owned in
    (* This strict read and the equal request digest establish only that the
       intended child is durable. Ordinary restore still rejects it until ACK. *)
    let* retained = read_original ~store ~request_id:intent.request_id in
    let* retained = match retained with Some retained -> Ok retained
      | None -> Error (Uncertain "Child publication has no confirmed original capture") in
    let* () = if String.equal retained.request_digest intent.request_digest
        && retained.installation_id=destination.installation_id
        && retained.package_id=destination.package_id && retained.tool=destination.tool then Ok ()
      else Error (Rejected "Another child binding cannot acknowledge the original successor") in
    let* published = Systhread_host.run (fun () ->
      advance ~store parent (Progress.Successor_observed intent.request_id)) in
    finish (record published) intent
  | Progress.Subdivided (refusal,intent) ->
    let* _ = validate_intent refusal intent in finish parent intent
  | Progress.Captured | Progress.Admission_wait _ | Progress.Dispatch_pending _ | Progress.Judged _
  | Progress.Committing _ | Progress.Commit_unknown _ | Progress.Finished _ | Progress.Conflicted _
  | Progress.Rejected _ -> Error (Rejected "The original holds no successor intent to complete")
let narrow_with ~admit ~store ~base_path ~request_id =
  let* parent,workspace,original = restore_parent ~store ~base_path ~request_id in
  let complete parent = complete_with ~store ~workspace ~original parent
    |> Result.map (fun (parent,child) -> Successor_ready {parent;child}) in
  match Progress.phase parent.progress with
  | Progress.Subdividing _ | Progress.Subdivided _ -> complete parent
  | Progress.Rejected refusal ->
    let child_id = Capture.Request_id.fresh () in
    let* child = derive_successor original refusal child_id in
    (match child with
     | None -> Ok (Indivisible parent)
     | Some child ->
       let* request_digest = rejected (Owner.request_digest (Capture.to_json child)) in
       let intent : Progress.successor = {request_id=Capture.Request_id.to_string child_id;request_digest} in
       admit original (fun () ->
         let* published = Systhread_host.run (fun () ->
           advance ~store parent (Progress.Successor_intended intent)) in
         match published with
         | Acknowledged parent -> Ok (Successor_waiting parent)
         | New parent -> complete parent))
  | Progress.Captured | Progress.Admission_wait _ | Progress.Dispatch_pending _ | Progress.Judged _
  | Progress.Committing _ | Progress.Commit_unknown _ | Progress.Finished _ | Progress.Conflicted _ ->
    Error (Rejected "Only an original execution size refusal can create a Curator successor")
let local_admission _ publish = publish ()
let narrow_local ~store ~base_path ~request_id = narrow_with ~admit:local_admission ~store ~base_path ~request_id
(* Discovery recovery completes the intent a parent's record already holds.
   It never derives or publishes a new one: a parent that holds none when
   read again is refused. *)
let recover_successor ~store ~base_path ~request_id =
  let* parent,workspace,original = restore_parent ~store ~base_path ~request_id in
  let* _ = complete_with ~store ~workspace ~original parent in
  Ok ()
let narrow ~config ~request_id =
  let store=Lane_addon_store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
  let admit original publish =
    let reserved=reserved () in
    let* export=resolve ~config ~reserved in
    Runtime.with_tool_request_destination ~config ~access:Lane_addon_sources.Operator_configuration
      ~reserved ~export ~publish:(fun actual ->
        let expected=Capture.destination original in
        if not (same_semantic_destination actual expected) then
          Error (Runtime.Host_refusal (Lane_addon_call_context.Rejected
            "New Curator successor requires its original configured installation inputs"))
        else publish () |> Result.map_error (function
          | Unavailable detail -> Runtime.Unavailable detail
          | Uncertain detail -> Runtime.Outcome_unknown detail
          | Rejected detail -> Runtime.Host_refusal (Lane_addon_call_context.Rejected detail)))
    |> Result.map_error runtime_error in
  narrow_with ~admit ~store ~base_path:config.Workspace.base_path ~request_id
type original = {id:Capture.Request_id.t;record:Owner.Record.t;summary:Capture.Summary.t}
module Ids = Map.Make (String)
let settle_original_with ~store ~date record =
  Owner.settle ~store ~date record
  |> Result.map_error (function
    | Owner.Settle_unavailable detail -> Unavailable detail
    | Owner.Settle_changed as error -> Uncertain (Owner.settle_error_to_string error))
(* Settle a chain's records in the order given, leaf first, under the day its
   root was minted. *)
let settle_chain_with ~store root leaf_first =
  let* date = rejected (Capture.Request_id.minted_on root) in
  List.fold_left (fun settled record -> let* () = settled in settle_original_with ~store ~date record)
    (Ok ()) leaf_first
(* A chain is settled leaf first, so a settle interrupted between two of its
   originals leaves a Subdivided parent whose child is already in the archive,
   under the date of the chain's root. Settle that parent and its ancestors
   too. A missing child that did not move is left for the link check to
   refuse. Returns whether anything moved. *)
let finish_settling ~store originals =
  let by_id = List.fold_left (fun ids original -> Ids.add (Owner.Record.request_id original.record) original ids)
      Ids.empty originals in
  (* [original] and its ancestors, nearest first, so the root is last. Each
     ancestor must hold the one below it as its Subdivided child. *)
  let rec upward above original =
    let above = original :: above in
    match original.summary.Capture.Summary.predecessor with
    | None -> Ok (List.rev above)
    | Some parent ->
      let child = Owner.Record.request_id original.record in
      match Ids.find_opt (Capture.Request_id.to_string parent) by_id with
      | None -> Error (Rejected "original Curator predecessor is absent")
      | Some parent ->
        if List.exists (fun seen -> Capture.Request_id.compare seen.id parent.id = 0) above
        then Error (Rejected "original Curator predecessors form a cycle") else
        match Progress.phase (Owner.Record.progress parent.record) with
        | Progress.Subdivided (_,intent) when String.equal intent.request_id child -> upward above parent
        | Progress.Subdivided _ | Progress.Captured | Progress.Admission_wait _ | Progress.Dispatch_pending _
        | Progress.Judged _ | Progress.Committing _ | Progress.Commit_unknown _ | Progress.Finished _
        | Progress.Conflicted _ | Progress.Rejected _ | Progress.Subdividing _ ->
          Error (Rejected "original Curator predecessor does not hold this child") in
  List.fold_left (fun moved original ->
    let* moved = moved in
    match Progress.phase (Owner.Record.progress original.record) with
    | Progress.Subdivided (_,intent) when not (Ids.mem intent.request_id by_id) ->
      let* chain = upward [] original in
      let root = List.nth chain (List.length chain - 1) in
      let* date = rejected (Capture.Request_id.minted_on root.id) in
      let* child_settled = Systhread_host.run (fun () ->
        Owner.settled ~store ~scope:Capture.scope ~date ~request_id:intent.request_id) |> owned in
      if not child_settled then Ok moved else
      let* () = settle_chain_with ~store root.id (List.map (fun original -> original.record) chain) in
      Ok true
    | Progress.Subdivided _ | Progress.Captured | Progress.Admission_wait _ | Progress.Dispatch_pending _
    | Progress.Judged _ | Progress.Committing _ | Progress.Commit_unknown _ | Progress.Finished _
    | Progress.Conflicted _ | Progress.Rejected _ | Progress.Subdividing _ -> Ok moved) (Ok false) originals
(* Records and their summaries only: no request body is read and no capture
   is restored here. The pass restores only the originals it acts on. *)
let discover_observed_with ~store ~base_path ~after_inventory =
  let read () = Systhread_host.run (fun () ->
    let* workspace = Capture.observe_workspace ~base_path |> Result.map_error (fun detail -> Unavailable detail) in
    let inventory = Owner.discover ~store ~scope:Capture.scope in
    after_inventory ();
    let* records = inventory |> owned in
    let rec summarize originals = function
      | [] -> Ok (List.rev originals)
      | record::rest ->
        let* id = Capture.Request_id.of_string (Owner.Record.request_id record) |> rejected in
        let* summary = Capture.Summary.of_json (Owner.Record.summary record) |> rejected in
        summarize ({id;record;summary}::originals) rest in
    let* originals = summarize [] records in
    Ok (workspace,originals)) in
  let scan () =
    let* workspace,originals = read () in
    let* moved = finish_settling ~store originals in
    let* workspace,originals = if moved then read () else Ok (workspace,originals) in
    let* pending = Systhread_host.run (fun () -> Capture.recoverable_successors ~workspace
        (List.map (fun original -> original.record,original.summary) originals)) |> rejected in
    Ok (originals,pending) in
  let* originals,pending = scan () in
  let rec recover = function
    | [] -> Ok ()
    | request_id::rest ->
      let* () = recover_successor ~store ~base_path ~request_id in
      recover rest in
  match pending with
  | [] ->
    (* No recovery changed this pass's validated forest. This observation
       cannot authorize effects: resume/settle/narrow still reload the owner. *)
    Ok originals
  | _::_ ->
    let* () = recover pending in
    let* originals,pending = scan () in
    (match pending with
     | [] -> Ok originals
     | _::_ -> Error (Uncertain "Original successor discovery changed during recovery"))
let discover_with ~store ~base_path =
  discover_observed_with ~store ~base_path ~after_inventory:(fun () -> ())
(* A Curator body names its own request ID, so no other record names it. *)
let settle_chains_with ~store settling originals =
  let* chains = Capture.settled_chains settling
      (List.map (fun original -> original.record,original.summary) originals) |> rejected in
  List.fold_left (fun settled (root,leaf_first) -> let* () = settled in settle_chain_with ~store root leaf_first)
    (Ok ()) chains
let settle_chains ~config settling originals =
  let store=Lane_addon_store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
  settle_chains_with ~store settling originals
let discover ~config =
  let store=Lane_addon_store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
  discover_with ~store ~base_path:config.Workspace.base_path
module Observation = Workspace_memory_observation_receipt
module Receipt = Lane_addon_request_receipt
type observation = {original:Owner.retained;registration:Observation.registration;
  completion:Observation.completion option}
let prepare_observation_with ~store ~base_path ~request_id ~now =
  let* original = Systhread_host.run (fun () -> Owner.load ~store ~scope:Capture.scope ~request_id) |> owned in
  let* original = match original with Some original -> Ok original
    | None -> Error (Unavailable "An observer cannot create a missing original Curator request") in
  let* workspace = Systhread_host.run (fun () -> Capture.observe_workspace ~base_path)
    |> Result.map_error (fun detail -> Unavailable detail) in
  let* capture = restore ~store ~workspace original in
  let publish original event = Systhread_host.run (fun () -> advance ~store original (Progress.Observer event))
    |> Result.map record in
  let* original,registration = match (Progress.observer original.progress).registration with
    | Receipt.Unobserved ->
      let* registration = rejected (Observation.registration ~capture ~original ~observed_at:(now ())) in
      let* original = publish original (Receipt.Intended (Receipt.Registration,registration.receipt)) in
      Ok (original,registration)
    | Receipt.Pending receipt | Receipt.Acknowledged receipt ->
      let* registration = rejected (Observation.restore_registration ~capture ~original receipt) in
      Ok (original,registration) in
  match (Progress.observer original.progress).completion with
  | Receipt.Pending receipt | Receipt.Acknowledged receipt ->
    let* completion = rejected (Observation.restore_completion ~capture ~original ~registration receipt) in
    Ok {original;registration;completion=Some completion}
  | Receipt.Unobserved ->
    match Progress.phase original.progress with
    | Progress.Captured | Progress.Admission_wait _ | Progress.Dispatch_pending _ | Progress.Judged _
    | Progress.Committing _ | Progress.Commit_unknown _ -> Ok {original;registration;completion=None}
    | Progress.Finished _ | Progress.Conflicted _ | Progress.Rejected _
    | Progress.Subdividing _ | Progress.Subdivided _ ->
      let* completion = rejected (Observation.completion ~capture ~original ~registration ~observed_at:(now ())) in
      let* original = publish original (Receipt.Intended (Receipt.Completion,completion.receipt)) in
      Ok {original;registration;completion=Some completion}
let prepare_observation ~config ~request_id =
  let store = Lane_addon_store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
  prepare_observation_with ~store ~base_path:config.Workspace.base_path ~request_id ~now:Time_compat.now
module Runs = Exact_lane_run_registry
type observation_error =
  | Original_observation_failed of error
  | Registry_delivery_failed of Runs.reconciliation_error
let observation_error_to_string = function
  | Original_observation_failed error -> error_to_string error
  | Registry_delivery_failed error -> Runs.reconciliation_error_to_string error
let deliver_observation_with ~store ~base_path ~registry ~request_id ~now =
  let integrity value=Result.map_error (fun error -> Original_observation_failed error) value in
  let* prepared=prepare_observation_with ~store ~base_path ~request_id ~now |> integrity in
  let pending = function Receipt.Pending _ -> true | Unobserved | Acknowledged _ -> false in
  let observer=Progress.observer prepared.original.progress in
  if not (pending observer.registration || pending observer.completion) then Ok prepared else
  let registration=prepared.registration in
  let terminal=match prepared.completion with
    | None -> None
    | Some completion ->
      let outcome=match completion.disposition with
        | Observation.Confirmed_commit _ -> Runs.Succeeded
        | Domain_conflict _ -> Runs.Failed {code="domain_conflict";detail="Original domain state conflicts with the retained commit"}
        | Before_dispatch_refusal _ -> Runs.Failed {code="before_dispatch_refused";detail="Original Curator request was refused before dispatch"}
        | Execution_refusal _ -> Runs.Failed {code="execution_refused";detail="Original Curator execution was refused"} in
      Some {Runs.outcome;elapsed_s=None;output=Receipt.to_json completion.receipt;
        selected_slot=completion.selected_slot;usage=None} in
  let* ()=Runs.reconcile_original registry ~run_id:registration.run_id ~lane:Runs.Workspace_curator
    ~actor:registration.actor ~started_at:registration.receipt.observed_at
    ~input:(Runs.Exact_input registration.input) ~completion:terminal
    |> Result.map_error (function
      | Runs.Invalid_original detail -> Original_observation_failed (Rejected detail)
      | (Runs.Original_registration_conflict | Original_completion_conflict
          | Failed_completion_conflict | Reconciliation_unavailable _
          | Reconciliation_persistence_failed _) as error -> Registry_delivery_failed error) in
  (* Reconciliation returned with every registry lock released. Restore the
     physical original/ancestry and the full immutable receipt again before
     acknowledging that exact fact; no registry getter can manufacture an ACK. *)
  let acknowledge stage expected =
    let* fresh=prepare_observation_with ~store ~base_path ~request_id ~now in
    let observer=Progress.observer fresh.original.progress in
    let publication=match stage with Receipt.Registration -> observer.registration
      | Completion -> observer.completion in
    match publication with
    | Receipt.Unobserved -> Error (Rejected "Original observer intention vanished before acknowledgement")
    | Receipt.Pending actual | Receipt.Acknowledged actual ->
      if not (Yojson.Safe.equal (Receipt.to_json actual) (Receipt.to_json expected)) then
        Error (Rejected "Original observer receipt changed after durable registry confirmation")
      else match publication with
        | Receipt.Unobserved -> Error (Rejected "Original observer intention vanished")
        | Receipt.Acknowledged _ -> Ok ()
        | Receipt.Pending _ ->
          Systhread_host.run (fun () -> advance ~store fresh.original
            (Progress.Observer (Receipt.Recorded (stage,expected.Receipt.digest))))
          |> Result.map (fun _ -> ()) in
  let* ()=acknowledge Receipt.Registration registration.receipt |> integrity in
  let* ()=match prepared.completion with None -> Ok ()
    | Some completion -> acknowledge Receipt.Completion completion.receipt |> integrity in
  prepare_observation_with ~store ~base_path ~request_id ~now |> integrity
let deliver_observation ~config ~request_id =
  let store=Lane_addon_store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
  deliver_observation_with ~store ~base_path:config.Workspace.base_path
    ~registry:(Runs.global ()) ~request_id ~now:Time_compat.now
module For_testing = struct
  let resume ~store ~base_path ~request_id ~call =
    resume_with ~store ~base_path ~request_id ~prepare:(fun () -> Ok ()) ~call
  let settle=settle_with let narrow=narrow_local
  let recover_successor=recover_successor
  let deliver_observation=deliver_observation_with
  let prepare_observation=prepare_observation_with
  let discover=discover_with
  let discover_observed=discover_observed_with
  let settle_chains=settle_chains_with
end
