module Capture = Workspace_memory_execution_capture
module Owner = Lane_addon_tool_request_owner
module Progress = Lane_addon_request_progress
module Exact = Lane_addon_exact
module Runtime = Lane_addon_runtime
module Binding = Server_workspace_memory_addon_validation
module Ledger = Workspace_memory_ledger
module Briefing = Workspace_memory_briefing
module Context = Workspace_memory_context
let ( let* ) = Result.bind

type error = Unavailable of string | Rejected of string | Uncertain of string
let error_to_string = function Unavailable detail | Rejected detail | Uncertain detail -> detail
let runtime_error = function
  | Runtime.Unavailable detail -> Unavailable detail
  | Runtime.Outcome_unknown detail -> Uncertain detail
  | Runtime.Host_refusal refusal -> (match refusal with
      | Lane_addon_call_context.Rejected detail | Activity_disabled detail -> Rejected detail
      | Unavailable detail | Activity_unobserved detail -> Unavailable detail)
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
      | Some export -> Ok export | None -> Error (Unavailable "No attached Add-on provides curate"))
let capture ~config make =
  let reserved=reserved () in
  let* export=resolve ~config ~reserved in
  let request_id=Capture.Request_id.fresh () in
  let* workspace=Eio_unix.run_in_systhread (fun () -> Capture.observe_workspace ~base_path:config.Workspace.base_path)
    |> Result.map_error (fun detail -> Unavailable detail) in
  Runtime.capture_tool_request_owner ~config ~access:Lane_addon_sources.Operator_configuration ~reserved ~export
    ~scope:Capture.scope ~request_id:(Capture.Request_id.to_string request_id)
    ~capture:(fun (destination : Runtime.tool_request_destination) ->
      let* ()=if destination.package_id=Binding.package_id && destination.tool=Binding.tool then Ok ()
        else Error "Curator capture requires its declared package and tool" in
      let destination : Capture.destination = {
        installation_id=destination.installation_id;package_id=destination.package_id;tool=destination.tool;
        source_revision=destination.source_revision;configuration_revision=destination.configuration_revision} in
      let* capture=make ~request_id ~workspace ~destination in
      Ok (capture,Capture.to_json capture)) |> Result.map_error runtime_error
let capture_classification ~config ~prompt ~ledger ~batch =
  capture ~config (fun ~request_id ~workspace ~destination ->
    Capture.classification ~request_id ~workspace ~destination ~prompt ~ledger ~batch)
let capture_briefing ~config ~prompt ~batch =
  let* current=Eio_unix.run_in_systhread (fun () ->
    Briefing.load ~directory:(Ledger.directory ~base_path:config.Workspace.base_path))
    |> Result.map_error (fun detail -> Unavailable detail) in
  let* ()=if Yojson.Safe.equal (Briefing.to_json current) (Briefing.to_json (Briefing.prepared_state batch))
    then Ok () else Error (Rejected "Confirm the original prepared briefing state before capturing model work") in
  capture ~config (fun ~request_id ~workspace ~destination ->
    Capture.briefing ~request_id ~workspace ~destination ~prompt ~batch)

type wait = Capacity | Worker_pending | Worker_unknown | Missing_after_dispatch | Journal_recheck
type result =
  | Awaiting of wait * Owner.retained
  | Judgment of {capture:Capture.t;record:Owner.retained;final:Exact.final;expected:Capture.expected_commit}
  | Terminal of Exact.final * Owner.retained
  | Commit_pending of Owner.retained
  | Settled of Owner.retained

type worker_state = Absent | Pending | Capacity_wait | Finished of Exact.final
let reply ~capture (reply : Mcp_protocol.Mcp_types.tool_result) =
  let context="Curator Add-on reply" in
  let* ()=match reply.is_error with
    | Some true -> Error (Unavailable (Agent_core.Mcp.text_of_tool_result reply))
    | None | Some false -> Ok () in
  let* json=match reply.structured_content with Some json -> Ok json
    | None -> Error (Rejected "Curator reply has no structured content") in
  let parse () =
    let* fields=Candle_json.object_fields ~context json in
    let* id,fields=Candle_json.field ~context "request_id" Candle_json.as_non_blank fields in
    let* ()=if id=Capture.Request_id.to_string (Capture.request_id capture) then Ok ()
      else Error "Curator reply belongs to another original request" in
    let* state,fields=Candle_json.field ~context "state" Candle_json.as_string fields in
    let* state,fields=match state with
      | "absent" -> Ok (Absent,fields) | "pending" -> Ok (Pending,fields)
      | "capacity_wait" -> Ok (Capacity_wait,fields)
      | "finished" -> let* final,fields=Candle_json.field ~context "result"
          (Exact.final_of_json ~schema:(Capture.output_schema capture)) fields in Ok (Finished final,fields)
      | _ -> Error "Unknown Curator worker state" in
    let* ()=Candle_json.finish ~context fields in Ok (state,json) in
  rejected (parse ())

type publication = New of Owner.retained | Acknowledged of Owner.retained
let advance ~store record event =
  match Owner.advance ~store ~expected:record ~event with
  | Ok (Owner.Stored record) -> Ok (New record)
  | Ok (Owner.Already_stored record) -> Ok (Acknowledged record)
  | Ok (Owner.Unconfirmed detail) -> Error (Uncertain detail)
  | Error error -> Error (Unavailable (Owner.update_error_to_string error))
let record = function New record | Acknowledged record -> record
let same_observation left right=match left,right with
  | Progress.Waiting left,Progress.Waiting right
  | Progress.Outcome_unknown left,Progress.Outcome_unknown right
  | Progress.Absent left,Progress.Absent right -> Yojson.Safe.equal left right
  | Progress.Waiting _,(Progress.Outcome_unknown _ | Progress.Absent _)
  | Progress.Outcome_unknown _,(Progress.Waiting _ | Progress.Absent _)
  | Progress.Absent _,(Progress.Waiting _ | Progress.Outcome_unknown _) -> false
let terminal ~capture ~record final =
  match final with
  | Exact.Call_final (Exact.Answered {output;_}) ->
    let* expected=rejected (Capture.validate_output capture (Exact.checked_json output)) in
    Ok (Judgment {capture;record;final;expected})
  | Exact.Call_final (Exact.Invalid_output _ | Exact.Input_refused _)
  | Exact.Outcome_unknown | Exact.Not_allowed _ | Exact.Request_id_reused -> Ok (Terminal (final,record))
let resume_with ~store ~base_path ~request_id ~call =
  let* original=Eio_unix.run_in_systhread (fun () -> Owner.load ~store ~scope:Capture.scope ~request_id) |> owned in
  let* original=match original with Some original -> Ok original
    | None -> Error (Unavailable "Original Curator request is absent; resume cannot recreate it") in
  let* workspace=Eio_unix.run_in_systhread (fun () -> Capture.observe_workspace ~base_path)
    |> Result.map_error (fun detail -> Unavailable detail) in
  let* capture=rejected (Capture.restore ~workspace original) in
  let publish original event=Eio_unix.run_in_systhread (fun () -> advance ~store original event) in
  let observe (original : Owner.retained) reason observation evidence =
    let observation=observation evidence in
    match Progress.phase original.progress with
    | Progress.Dispatch_pending (Some previous) when same_observation previous observation ->
      Ok (Awaiting (reason,original))
    | Progress.Captured | Progress.Admission_wait _ | Progress.Dispatch_pending (None | Some _)
    | Progress.Judged _ | Progress.Committing _ | Progress.Commit_unknown _ | Progress.Finished _
    | Progress.Conflicted _ | Progress.Rejected _ ->
      let* published=publish original (Progress.Execution_observed observation) in
      Ok (Awaiting (reason,record published)) in
  let finish original final =
    let* _=terminal ~capture ~record:original final in
    let event=match final with
      | Exact.Call_final (Exact.Answered _) -> Progress.Judgment_retained (Exact.final_to_json final)
      | Exact.Call_final (Exact.Invalid_output _ | Exact.Input_refused _)
      | Exact.Outcome_unknown | Exact.Not_allowed _ | Exact.Request_id_reused ->
        Progress.Refused {stage=Progress.Execution;evidence=Exact.final_to_json final} in
    let* published=publish original event in
    terminal ~capture ~record:(record published) final in
  let received original ~submission state evidence =
    match state with
    | Pending -> observe original Worker_pending (fun value -> Progress.Waiting value) evidence
    | Absent -> observe original Missing_after_dispatch (fun value -> Progress.Absent value) evidence
    | Capacity_wait ->
      if submission then
        let* published=publish original (Progress.Admission_declined evidence) in
        Ok (Awaiting (Capacity,record published))
      else Error (Rejected "Curator read cannot grant a pre-admission capacity refusal")
    | Finished final -> finish original final in
  let invoke arguments=let* response=call ~arguments in reply ~capture response in
  let read=`Assoc ["kind",`String "read";"request_id",`String request_id] in
  let admit original =
    let* published=publish original Progress.Dispatch_intended in
    match published with
    | Acknowledged record -> Ok (Awaiting (Journal_recheck,record))
    | New original ->
      let* request=rejected (Binding.request capture) in
      let submit=`Assoc ["kind",`String "submit";"request",Exact.request_to_json request] in
      (match invoke submit with
       | Ok (state,evidence) -> received original ~submission:true state evidence
       | Error error ->
         (* Even a malformed reply may follow admission. Preserve the intent
            and uncertainty; a later authoritative absence cannot undo it. *)
         observe original Worker_unknown (fun value -> Progress.Outcome_unknown value)
           (`Assoc ["detail",`String (error_to_string error)])) in
  match Progress.phase original.progress with
  | Progress.Judged judgment ->
    let* final=rejected (Exact.final_of_json ~schema:(Capture.output_schema capture) judgment) in
    (match final with
     | Exact.Call_final (Exact.Answered _) -> terminal ~capture ~record:original final
     | Exact.Call_final (Exact.Invalid_output _ | Exact.Input_refused _)
     | Exact.Outcome_unknown | Exact.Not_allowed _ | Exact.Request_id_reused ->
       Error (Rejected "Original judgment does not contain an answered domain result"))
  | Progress.Committing _ | Progress.Commit_unknown _ -> Ok (Commit_pending original)
  | Progress.Rejected {stage=Progress.Execution;evidence} ->
    let* final=rejected (Exact.final_of_json ~schema:(Capture.output_schema capture) evidence) in
    (match final with
     | Exact.Call_final (Exact.Answered _) -> Error (Rejected "Refused original work cannot contain an answered judgment")
     | Exact.Call_final (Exact.Invalid_output _ | Exact.Input_refused _)
     | Exact.Outcome_unknown | Exact.Not_allowed _ | Exact.Request_id_reused -> terminal ~capture ~record:original final)
  | Progress.Finished _ | Progress.Conflicted _ | Progress.Rejected {stage=Progress.Before_dispatch;_} -> Ok (Settled original)
  | Progress.Captured | Progress.Admission_wait _ ->
    let* state,_evidence=invoke read in
    (match state with
     | Absent -> admit original
     | Pending | Capacity_wait | Finished _ ->
       Error (Rejected "Worker state contradicts original pre-admission host progress"))
  | Progress.Dispatch_pending _ ->
    (match invoke read with
     | Ok (state,evidence) -> received original ~submission:false state evidence
     | Error error -> observe original Worker_unknown (fun value -> Progress.Outcome_unknown value)
         (`Assoc ["detail",`String (error_to_string error)]))
let resume ~config ~request_id =
  let reserved=reserved () in
  let store=Lane_addon_store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
  let call ~arguments =
    let* export=resolve ~config ~reserved in
    (* Re-retain the exact original capture through the live Runtime owner.
       This checks logical destination without replacing captured revisions. *)
    let* original=Eio_unix.run_in_systhread (fun () -> Owner.load ~store ~scope:Capture.scope ~request_id) |> owned in
    let* original=match original with Some record -> Ok record
      | None -> Error (Unavailable "Original Curator capture disappeared") in
    let* ()=Runtime.capture_tool_request_owner ~config ~access:Lane_addon_sources.Operator_configuration
      ~reserved ~export ~scope:Capture.scope ~request_id
      ~capture:(fun destination ->
        if destination.installation_id=original.installation_id && destination.package_id=original.package_id
           && destination.tool=original.tool then Ok ((),original.request)
        else Error "Another installation cannot resume the original Curator request")
      |> Result.map_error runtime_error in
    Runtime.call_exported_tool_with_principal ~principal:(Some Lane_addon_call_context.Operator)
      ~config ~access:Lane_addon_sources.Operator_configuration ~reserved ~export ~arguments
      |> Result.map_error runtime_error in
  resume_with ~store ~base_path:config.Workspace.base_path ~request_id ~call

type commit_result = Commit_waiting of Owner.retained | Committed of Owner.retained
  | Commit_conflict of Owner.retained
type write_permission = Newly_stored | Recovering
let domain_json kind state = `Assoc ["kind",`String kind;"state",state]
let ledger_json ledger=domain_json "classification" (Ledger.to_json ledger)
let briefing_json state=domain_json "briefing" (Briefing.to_json state)
let commit_plan capture judgment =
  let* final=rejected (Exact.final_of_json ~schema:(Capture.output_schema capture) judgment) in
  let* expected=match final with
    | Exact.Call_final (Exact.Answered {output;_}) -> rejected (Capture.validate_output capture (Exact.checked_json output))
    | Exact.Call_final (Exact.Invalid_output _ | Exact.Input_refused _)
    | Exact.Outcome_unknown | Exact.Not_allowed _ | Exact.Request_id_reused ->
      Error (Rejected "Domain commit requires the original answered judgment") in
  let* change=match Capture.work capture,expected with
    | Capture.Classification {ledger;_},Capture.Classification_commit after ->
      Ok {Progress.before=ledger_json ledger;after=ledger_json after}
    | Capture.Briefing batch,Capture.Briefing_commit after ->
      Ok {Progress.before=briefing_json (Briefing.prepared_state batch);after=briefing_json after}
    | Capture.Classification _,Capture.Briefing_commit _
    | Capture.Briefing _,Capture.Classification_commit _ -> Error (Rejected "Original commit domain differs") in
  Ok (expected,change)
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
  | Capture.Classification {ledger;batch} -> classification_current ~base_path ~ledger ~selected:batch.selected
  | Capture.Briefing batch ->
    let* ledger=Ledger.load ~base_path |> Result.map_error (fun detail -> Unavailable detail) in
    Briefing.batch_is_current ~sources:(Ledger.briefing_sources ledger) ~contract:(briefing_contract ()) batch
    |> rejected
let settle_with ~store ~base_path ~request_id ~briefing_contract ~save =
  let* original=Eio_unix.run_in_systhread (fun () -> Owner.load ~store ~scope:Capture.scope ~request_id) |> owned in
  let* original=match original with Some record -> Ok record
    | None -> Error (Unavailable "Original Curator commit is absent") in
  let* workspace=Eio_unix.run_in_systhread (fun () -> Capture.observe_workspace ~base_path)
    |> Result.map_error (fun detail -> Unavailable detail) in
  let* capture=rejected (Capture.restore ~workspace original) in
  let phase=Progress.phase original.progress in
  let* judgment,stored=match phase with
    | Progress.Judged judgment -> Ok (judgment,None)
    | Progress.Committing commit | Progress.Commit_unknown (commit,_)
    | Progress.Finished commit | Progress.Conflicted (commit,_) -> Ok (commit.judgment,Some commit)
    | Progress.Captured | Progress.Admission_wait _ | Progress.Dispatch_pending _ | Progress.Rejected _ ->
      Error (Rejected "Original Curator request has no domain judgment to commit") in
  let* expected,change=commit_plan capture judgment in
  let* ()=match stored with
    | None -> Ok ()
    | Some commit -> if Yojson.Safe.equal commit.change.before change.before
        && Yojson.Safe.equal commit.change.after change.after then Ok ()
      else Error (Rejected "Recorded commit differs from its original captured domain states") in
  let publish original event=Eio_unix.run_in_systhread (fun () -> advance ~store original event) in
  let uncertain (original : Owner.retained) detail =
    let evidence=`Assoc ["detail",`String detail] in
    match Progress.phase original.progress with
    | Progress.Commit_unknown (_,previous) when Yojson.Safe.equal previous evidence -> Error (Uncertain detail)
    | Progress.Captured | Progress.Admission_wait _ | Progress.Dispatch_pending _ | Progress.Judged _
    | Progress.Committing _ | Progress.Commit_unknown _ | Progress.Finished _ | Progress.Conflicted _ | Progress.Rejected _ ->
      let* _=publish original (Progress.Commit_uncertain evidence) in Error (Uncertain detail) in
  let observe original event ctor =
    let* published=publish original event in Ok (ctor (record published)) in
  let fresh ()=Eio_unix.run_in_systhread (fun () -> load_domain ~base_path expected) in
  let confirm original = match fresh () with
    | Error detail -> uncertain original detail
    | Ok current ->
      if Yojson.Safe.equal current change.after then observe original (Progress.Commit_observed current) (fun r -> Committed r)
      else if Yojson.Safe.equal current change.before then uncertain original "Domain save returned without a confirmed after-state"
      else observe original (Progress.Commit_conflicted current) (fun r -> Commit_conflict r) in
  let write original =
    match Eio_unix.run_in_systhread (fun () -> save expected) with
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
        let* current_sources=Eio_unix.run_in_systhread (fun () -> eligible ~base_path ~briefing_contract capture) in
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
          | Progress.Finished _ | Progress.Conflicted _ | Progress.Rejected _ ->
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
  | Progress.Captured | Progress.Admission_wait _ | Progress.Dispatch_pending _ | Progress.Rejected _ ->
    Error (Rejected "Original Curator request is not ready to commit")
let settle ~config ~request_id =
  let base_path=config.Workspace.base_path in
  let store=Lane_addon_store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
  let briefing_contract ()=let prompt=Prompt_registry.resolve_prompt Prompt_names.workspace_memory_briefing in
    Briefing.contract ~template:prompt.effective in
  settle_with ~store ~base_path ~request_id ~briefing_contract ~save:(save_domain ~base_path)
module For_testing = struct let resume=resume_with let settle=settle_with end
