module Request = Keeper_librarian_durable_request
module Memory_runtime = Keeper_librarian_runtime
module Owner = Lane_addon_tool_request_owner
module Progress = Lane_addon_request_progress
module Exact = Lane_addon_exact
module Runtime = Lane_addon_runtime
module Submit = Lane_addon_submit_once
open Result.Syntax
type error = Submit.error = Unavailable of string | Rejected of string | Uncertain of string
let error_to_string = Submit.error_to_string
type wait = Submit.wait = Worker_pending | Worker_unknown | Worker_unreachable
  | Missing_after_dispatch | Journal_recheck
type publication = Publication_pending of string | Publication_complete of Owner.retained
  | Publication_superseded of Owner.retained
type publish = original:Owner.retained -> request:Request.t ->
  proposal:Memory_runtime.durable_proposal -> (publication,error) result
type call = expected:Request.destination -> original:Owner.Record.t -> arguments:Yojson.Safe.t ->
  (Mcp_protocol.Mcp_types.tool_result,Submit.call_error) result
type outcome = Publication_waiting of string
  | Refused of Exact.final * Owner.retained | Finished of Owner.retained
  | Basis_superseded of Owner.retained
  | Ended_unadmitted of Owner.retained
type resumed = Waited of wait * Owner.Record.t | Resumed of outcome * Request.t
  | Original_replaced of Owner.Record.t
type listed = Owner.Record.t * Request.index
type terminal_ending_recovery = No_ending | Ending_retained of Owner.Record.t
type ending_source = Host_ending | Replaced_ending
type held = Listed of listed | Read of (Owner.retained * Request.t)
let io work = Systhread_host.run work
let rejected value = Result.map_error (fun detail -> Rejected detail) value
let owned value = Result.map_error (fun error -> Unavailable (Owner.error_to_string error)) value
let require condition detail = if condition then Ok () else Error (Rejected detail)
let same left right =
  let* left=rejected (Lane_addon_action.canonical left) in
  let* right=rejected (Lane_addon_action.canonical right) in
  Ok (Yojson.Safe.equal left right)
let check_request request (record:Owner.retained) =
  io (fun () -> Request.confirm_record request record) |> rejected
let check_predecessor ~store ~dispatch request =
  io (fun () -> Keeper_librarian_history_resolution_lineage.confirm_predecessor ~store ~require_confirmed:dispatch request) |> rejected
let retain ~store request =
  let* ()=io (fun () -> Request.confirm_owner request) |> rejected in
  let* ()=check_predecessor ~store ~dispatch:false request in
  let destination=Request.destination request in
  let scope=Request.scope (Request.physical_owner request) and request_id=Request.request_id request in
  let* index=io (fun () -> Request.index request) |> rejected in
  let* ()=io (fun () -> Owner.retain ~store ~scope ~request_id
    ~installation_id:destination.installation_id ~package_id:destination.package_id ~tool:destination.tool
    ~summary:(Request.index_to_json index)
    ~request:(Request.to_json request)) |> owned in
  let* record=io (fun () -> Owner.load ~store ~scope ~request_id) |> owned in
  let* record=match record with Some record -> Ok record
    | None -> Error (Uncertain "Retained original history request is not observable") in
  let* ()=check_request request record in Ok record
let discover ~store ~base_path ~keepers_dir ~keeper_id =
  let* scope=io (fun () -> Request.discovery_scope ~base_path ~keepers_dir ~keeper_id) |> rejected in
  let* records=io (fun () -> Owner.discover ~store ~scope) |> owned in
  let rec restore found = function
    | [] -> Ok (List.rev found)
    | record::rest ->
      let* index,owner=io (fun () ->
        let* index=Request.index_of_summary record in
        let* owner=Request.observe_index_owner ~base_path ~keepers_dir index in
        let+ ()=Request.confirm_index_source_root index in index,owner) |> rejected in
      let* ()=require (Request.keeper_id owner=keeper_id) "History inventory includes another Keeper" in
      restore ((record,index)::found) rest in
  restore [] records
let load_with_restore ~restore ~store (record,(index:Request.index)) =
  let* original=io (fun () -> Owner.load_listed ~store record) |> owned in
  let* request=io (fun () ->
    let* request=restore ~owner:index.owner original in
    (* [restore] bound the summary of the record it read to the body. That
       record was read after [discover]; its summary must be the same index. *)
    let* stored=Request.index_of_summary (Owner.listed original) in
    if stored=index then Ok request
    else Error "Original history index changed after its inventory was read") |> rejected in
  Ok (original,request)
let load ~store original = load_with_restore ~restore:Request.restore ~store original
let load_many ~store originals =
  let rec read sources found = function
    | [] -> Ok (List.rev found)
    | ((_,(index:Request.index)) as original)::rest ->
      let restore=match Set_util.StringMap.find_opt index.source_digest sources with
        | None -> Request.restore
        | Some previous -> Request.restore_reusing_source ~previous in
      let* retained,request=load_with_restore ~restore ~store original in
      let sources=Set_util.StringMap.add index.source_digest request sources in
      read sources ((retained,request)::found) rest in
  read Set_util.StringMap.empty [] originals
let original_judgment (record:Owner.retained) =
  match Progress.phase record.progress with
  | Progress.Judged judgment -> Ok judgment
  | Committing commit | Commit_unknown (commit,_) | Finished commit | Conflicted (commit,_) -> Ok commit.judgment
  | Captured | Admission_wait _ | Dispatch_pending _ | Rejected _ | Subdividing _ | Subdivided _ ->
    Error (Rejected "Original history record has no answered host judgment")
let restore_answer ~store request record =
  let* judgment=original_judgment record in
  let* final=io (fun () -> Request.decode_final ~store request judgment) |> rejected in
  let* ()=io (fun () -> Request.confirm_final ~store request final) |> rejected in
  match final with
  | Exact.Call_final (Exact.Answered {output;_}) ->
    let* proposal=rejected (Request.validate_proposal request (Exact.checked_json output)) in
    Ok (final,proposal)
  | Call_final (Invalid_output _ | Input_refused _ | Output_limit_reached _)
  | Outcome_unknown | Not_allowed _ | Request_id_reused ->
    Error (Rejected "Original history publication requires an actual answered host result")
(* Whether the retained refusal says the process that started the
   attempt stopped before it ended. *)
let unknown_cause ~schema (record:Owner.retained) =
  match Progress.phase record.progress with
  | Progress.Rejected {stage=Progress.Execution;evidence} ->
    let* retained=rejected (Exact.retained_final_of_json ~schema evidence) in
    Ok (match retained with
      | Exact.Retained_unknown cause -> Some cause
      | Retained_call (Answered _ | Invalid_output _ | Input_refused _ | Output_limit_reached _)
      | Retained_not_allowed _ | Retained_request_id_reused -> None)
  | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
  | Finished _ | Conflicted _ | Rejected {stage=Progress.Before_dispatch;_}
  | Subdividing _ | Subdivided _ -> Ok None
let check_completed ~store ~superseded request ~original completed =
  let* ()=check_request request completed in
  let* ()=require (completed.Owner.request_digest=original.Owner.request_digest)
    "History publication changed its original request digest" in
  let* before=original_judgment original in
  let* after=original_judgment completed in
  let* judgment_equal=same before after in
  let* ()=require judgment_equal "History publication changed its original judgment" in
  let* ()=match superseded,Progress.phase completed.progress with
    | false,Progress.Finished _ | true,Conflicted _ -> Ok ()
    | false,(Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
      | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _)
    | true,(Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
      | Finished _ | Rejected _ | Subdividing _ | Subdivided _) ->
      Error (Rejected "History publication has no matching durable terminal acknowledgment") in
  let previous=Progress.events original.progress and next=Progress.events completed.progress in
  let* ()=require (List.length next>=List.length previous
    && List.take (List.length previous) next=previous)
    "History publication rewrote its original progress prefix" in
  let* actual=io (fun () -> Owner.load ~store ~scope:completed.scope ~request_id:completed.request_id) |> owned in
  match actual with
  | None -> Error (Uncertain "Completed history original is not observable")
  | Some actual ->
    let* ()=check_request request actual in
    let* equal_progress=same (Progress.to_json actual.progress) (Progress.to_json completed.progress) in
    require equal_progress "History publication callback differs from its durable original progress"
(* The body of one original as the pass uses it: the retained original read
   with it, its request, and the Exact request and schema made from it. *)
type body = {retained:Owner.retained;request:Request.t;exact:Exact.request;schema:Yojson.Safe.t}
let body_of (retained,request) =
  let* exact=rejected (Request.request request) in
  let+ schema=match exact.schema with Some schema -> Ok schema
    | None -> Error (Rejected "Original history request has no output schema") in
  {retained;request;exact;schema}
let recover_terminal_ending ~store ~config ~reserved ~original:((record,index) as listed) =
  match Progress.phase (Owner.Record.progress record) with
  | Captured | Admission_wait _ | Judged _ | Committing _ | Commit_unknown _
  | Finished _ | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ -> Ok No_ending
  | Dispatch_pending _ ->
  let* ()=require (Option.is_none (Progress.preparation (Owner.Record.progress record))
    && Option.is_none (Progress.replacement (Owner.Record.progress record)))
    "History ending recovery cannot cross a publication intent" in
  let* ()=io (fun () ->
    let* stored=Request.index_of_summary record in
    let* ()=if stored=index then Ok () else Error "History ending recovery has another index" in
    let* _=Request.observe_index_owner ~base_path:config.Workspace.base_path
      ~keepers_dir:(Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path) index in
    Request.confirm_index_source_root index) |> rejected in
  let* declaration_id=io (fun () ->
    let* installation=Owner.installation_of_id (Owner.Record.installation_id record) in
    match installation with
    | Owner.Configuration id -> Ok id
    | Manual _ -> Error "History ending recovery requires a configured original") |> rejected in
  let identity=Exact.identity_of_digest ~request_id:(Owner.Record.request_id record) ~digest:index.exact_digest in
  let* observed=io (fun () -> Exact.observe_open ~store ~declaration_id identity
    |> Result.map_error Exact.describe_recovery_error) |> rejected in
  let* source=match observed with
    | Exact.Needs_request -> Ok (Some Host_ending)
    | No_record | Open ->
      match Keeper_librarian_durable_edge.observe_destination ~config ~reserved index.destination with
      | Error (Submit.Unavailable _ | Rejected _ | Uncertain _) -> Ok None
      | Ok current ->
        match Lane_addon_captured_destination.relation ~captured:index.destination ~current with
        | Same | Other_owner -> Ok None
        | Replaced -> Ok (Some Replaced_ending) in
  match source with
  | None -> Ok No_ending
  | Some source ->
  let* original,request=load ~store listed in
  let* ()=require (Progress.to_json original.progress=Progress.to_json (Owner.Record.progress record))
    "History original changed during ending recovery" in
  let* body=body_of (original,request) in
  let validate () =
    let* ()=Request.confirm_owner request in
    let* ()=Keeper_librarian_history_resolution_state.check_unfenced ~store ~request ~original in
    Keeper_librarian_history_resolution_lineage.confirm_predecessor ~store ~require_confirmed:true request in
  let* ()=io validate |> rejected in
  let* observed=match source with
    | Host_ending ->
      let+ observed=io (fun () -> Exact.observe_retained ~store ~declaration_id ~schema:body.schema body.exact) |> rejected in
      (match observed with
       | Exact.Retained_absent | Retained_open -> None
       | Retained_terminal final -> Some final)
    | Replaced_ending ->
      let+ reconciled=Keeper_librarian_durable_edge.reconcile_replacement ~config ~reserved
        ~original:record ~request:body.exact in
      (match reconciled with
       | Exact.Reconciled_terminal final -> Some final
       | Reconciliation_pending _ -> None) in
  match observed with
  | None
  | Some (Exact.Retained_call _ | Retained_unknown (Cut | Raised)
    | Retained_not_allowed {reason=Permission_refused _} | Retained_request_id_reused) -> Ok No_ending
  | Some ((Exact.Retained_not_allowed {reason=Replaced_declaration} | Retained_unknown Interrupted) as ending) ->
  let confirm_ending () =
    Request.confirm_retained_final ~store request ending |> rejected in
  (* No call or publication port is reachable here. Protect only this local
     refusal publication and its strict confirmation, joining the I/O work. *)
  Eio.Cancel.protect (fun () -> io (fun () ->
    let* ()=validate () |> rejected in
    let* ()=confirm_ending () in
    let* published=Submit.advance ~store original
      (Progress.Refused {stage=Execution;evidence=Exact.retained_final_to_json ending}) in
    let published=Submit.record published in
    let* reread=Owner.reload ~store published |> owned in
    let* reread=Option.to_result ~none:(Uncertain "Retained history ending is not observable") reread in
    let* ()=require (Owner.same_record published reread) "Retained history ending changed before confirmation" in
    let* ()=Request.confirm_record request reread |> rejected in
    let* ()=validate () |> rejected in
    let+ ()=confirm_ending () in
    Ending_retained (Owner.listed reread)))
type terminal = Answer of Memory_runtime.durable_proposal * Owner.retained
  | Refusal of Exact.final * Owner.retained
type admission_check = Admission_continues | Admission_unavailable
  | Admission_replaced of Owner.Record.t
type replacement_check = Continue_original | Replacement_wait of wait
let resume ~store ~config ~reserved ~(original:held) ~(call:call) ~(publish:publish) ~wake =
  let record,owner,destination=match original with
    | Listed (record,index) -> record,index.owner,index.destination
    | Read (retained,request) ->
      Owner.listed retained,Request.physical_owner request,Request.destination request in
  let confirm_live_owner () =
    let base_path=config.Workspace.base_path in
    let keepers_dir=Config_dir_resolver.keepers_dir_for_base_path ~base_path in
    let* actual=io (fun () -> Request.observe_owner ~base_path ~keepers_dir ~keeper_id:(Request.keeper_id owner)) |> rejected in
    rejected (Request.owner_matches_json actual (Request.owner_to_json owner)) in
  let finish_replacement record =
    let* ()=confirm_live_owner () in
    wake ();Ok (Original_replaced record) in
  (* A listed original is checked on its record and index here. Its body is
     read in the branches that need it, and [load] binds that index to it. *)
  let* ()=match original with
    | Read (retained,request) ->
      let* ()=check_request request retained in
      io (fun () -> Keeper_librarian_history_resolution_state.check_unfenced
        ~store ~request ~original:retained) |> rejected
    | Listed (record,index) ->
      let* fence=io (fun () -> Keeper_librarian_history_resolution_lineage.fenced_record
        ~store ~record ~index) |> rejected in
      require (Option.is_none fence) "This original history result is durably fenced by an operator" in
  let* ()=confirm_live_owner () in
  let* ()=match original with
    | Read (_,request) -> check_predecessor ~store ~dispatch:true request
    | Listed (record,index) ->
      io (fun () -> Keeper_librarian_history_resolution_lineage.confirm_predecessor_record
        ~store ~require_confirmed:true record index) |> rejected in
  let* index=match original with
    | Listed (_,index) -> Ok index
    | Read (_,request) -> Request.index request |> rejected in
  let* admission=match Progress.phase (Owner.Record.progress record) with
    | Progress.Captured | Admission_wait _ ->
      (match Keeper_librarian_durable_edge.observe_destination ~config ~reserved destination with
       | Error (Submit.Unavailable _ | Rejected _ | Uncertain _) -> Ok Admission_unavailable
       | Ok current ->
         match Lane_addon_captured_destination.relation ~captured:destination ~current with
         | Same -> Ok Admission_continues
         | Other_owner -> Error (Rejected "Fresh history destination belongs to another original owner")
         | Replaced ->
           let+ record=io (fun () -> Keeper_librarian_declaration_replacement.refuse ~store
             ~original:record ~exact_digest:index.exact_digest ~captured:destination ~current) in
           Admission_replaced record)
    | Rejected {stage=Before_dispatch;_} ->
      let* replaced=Keeper_librarian_declaration_replacement.retained
        ~original:record ~captured:destination |> rejected in
      let* ()=io (fun () -> Keeper_librarian_declaration_replacement.confirm_no_execution
        ~store ~original:record ~exact_digest:index.exact_digest) |> rejected in
      if replaced then Ok (Admission_replaced record) else Ok Admission_continues
    | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _ | Finished _ | Conflicted _
    | Rejected {stage=Execution;_} | Subdividing _ | Subdivided _ -> Ok Admission_continues in
  match admission with
  | Admission_unavailable -> Ok (Waited (Worker_unreachable,record))
  | Admission_replaced record -> finish_replacement record
  | Admission_continues ->
  let* identity,read_body=match original with
    | Read read ->
      let+ body=body_of read in Exact.identity body.exact,(fun () -> Ok body)
    | Listed ((record,index) as listed) ->
      let loaded=ref None in
      let load_body () = match !loaded with
        | Some body -> Ok body
        | None ->
          let* body=Result.bind (load ~store listed) body_of in
          loaded:=Some body;
          Ok body in
      Ok (Exact.identity_of_digest ~request_id:(Owner.Record.request_id record) ~digest:index.exact_digest,
        load_body) in
  let rebind (body:body) record = match Owner.rebind body.retained record with
    | Some retained -> Ok retained
    | None -> Error (Rejected "Original history record names another request") in
  let prepare () =
    let* ()=confirm_live_owner () in
    Keeper_librarian_durable_edge.confirm_destination ~config ~reserved destination in
  (* An original no worker has received ends when its declaration was
     replaced. The worker of the new declaration is never asked about it.
     Under the same declaration nothing changes: the worker is read, and
     [prepare] checks the owner before admission. The end is a write, so the
     owner is checked before it too. *)
  let unadmitted () =
    let* relation,current=Submit.destination_relation ~config ~reserved ~label:"history" destination in
    match relation with
    | Lane_addon_captured_destination.Same -> Ok Submit.Admit
    | Replaced ->
      let* ()=confirm_live_owner () in
      Ok (Submit.End_replaced (Request.replaced_to_json {Request.captured=destination;current}))
    | Other_owner ->
      Error (Rejected "Fresh history destination differs from its original semantic configuration") in
  (* Admission reads the body inside [prepare], where an [Unavailable] check
     is a wait. A body the store cannot give is not one: it ends the pass. *)
  let admit () =
    let* body=read_body () |> Result.map_error (fun error -> Rejected (error_to_string error)) in
    let* ()=Memory_runtime.require_counterpart_template (Request.preparation body.request) |> rejected in
    prepare () in
  let call ~arguments =
    match prepare () with
    | Error error -> Error (Submit.Not_sent error)
    | Ok () -> call ~expected:destination ~original:record ~arguments in
  let terminal (body:body) record final =
    let* retained=rebind body record in
    let* ()=confirm_live_owner () in
    let* ()=io (fun () -> Request.confirm_final ~store body.request final) |> rejected in
    match final with
    | Exact.Call_final (Exact.Answered {output;_}) ->
      let* proposal=rejected (Request.validate_proposal body.request (Exact.checked_json output)) in
      Ok (body,Answer (proposal,retained))
    | Call_final (Invalid_output _ | Input_refused _ | Output_limit_reached _)
    | Outcome_unknown | Not_allowed _ | Request_id_reused -> Ok (body,Refusal (final,retained)) in
  let publish_answer (body:body) (record : Owner.retained) proposal =
    let request=body.request in
    let already_acked_commit =
      match Progress.phase record.progress with
      | Progress.Committing _ | Commit_unknown _ ->
        let source = Request.source request and owner = Request.physical_owner request in
        let keeper_id = Request.keeper_id owner in
        let runtime_keepers_dir = Keeper_librarian_durable_capture.runtime_keepers_dir source in
        let through =
          Keeper_librarian_input_sources.external_through
            (Keeper_librarian_durable_capture.counterparts source)
        in
        (match io (fun () -> Keeper_external_read_cursor.observe ~runtime_keepers_dir ~keeper_name:keeper_id) with
         | Ok external_cursor ->
           Keeper_external_read_cursor.observation_matches_preparation
             external_cursor ~after:through ~through ~atom:None ~official:None
         | Error _ -> false)
      | Captured | Admission_wait _ | Dispatch_pending _ | Judged _
      | Finished _ | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ -> false
    in
    let* () =
      if already_acked_commit then Ok ()
      else Memory_runtime.require_counterpart_template (Request.preparation request) |> rejected
    in
    let* published=publish ~original:record ~request ~proposal in
    let+ outcome=match published with
      | Publication_pending detail -> Ok (Publication_waiting detail)
      | Publication_complete completed ->
        let* ()=check_completed ~store ~superseded:false request ~original:record completed in
        let* ()=confirm_live_owner () in
        wake ();
        Ok (Finished completed)
      | Publication_superseded completed ->
        let* ()=check_completed ~store ~superseded:true request ~original:record completed in
        let* ()=confirm_live_owner () in
        (match Progress.phase record.progress with
         | Progress.Conflicted _ -> ()
         | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
         | Finished _ | Rejected _ | Subdividing _ | Subdivided _ -> wake ());
        Ok (Basis_superseded completed) in
    Resumed (outcome,request) in
  let source:body Submit.source={identity;load=read_body;request=(fun body -> body.exact);schema=(fun body -> body.schema)} in
  let decode_final (body:body) json=io (fun () -> Request.decode_final ~store body.request json) in
  let reconcile_replacement () =
    match Progress.phase (Owner.Record.progress record) with
    | Captured | Admission_wait _ | Judged _ | Committing _ | Commit_unknown _
    | Finished _ | Conflicted _ | Rejected _ | Subdividing _ | Subdivided _ -> Ok Continue_original
    | Dispatch_pending _ ->
      match Keeper_librarian_durable_edge.observe_destination ~config ~reserved destination with
      | Error (Submit.Unavailable _ | Rejected _ | Uncertain _) -> Ok Continue_original
      | Ok current ->
        match Lane_addon_captured_destination.relation ~captured:destination ~current with
        | Same | Other_owner -> Ok Continue_original
        | Replaced ->
          let* declaration_id=io (fun () ->
            let* installation=Owner.installation_of_id destination.installation_id in
            match installation with
            | Owner.Configuration id -> Ok id
            | Manual _ -> Error "History replacement requires a configured original") |> rejected in
          let* observed=io (fun () -> Exact.observe_open ~store ~declaration_id identity
            |> Result.map_error Exact.describe_recovery_error) |> rejected in
          match observed with
          | Exact.Needs_request -> Ok Continue_original
          | No_record | Open ->
          let* body=read_body () in
          let* ()=io (fun () ->
            let* ()=Request.confirm_owner body.request in
            let* ()=Keeper_librarian_history_resolution_state.check_unfenced
              ~store ~request:body.request ~original:body.retained in
            Keeper_librarian_history_resolution_lineage.confirm_predecessor
              ~store ~require_confirmed:true body.request) |> rejected in
          let+ reconciled=Keeper_librarian_durable_edge.reconcile_replacement ~config ~reserved
            ~original:record ~request:body.exact in
          match reconciled with
          | Exact.Reconciled_terminal _ | Reconciliation_pending Declaration_current -> Continue_original
          | Reconciliation_pending Replacement_claim_busy -> Replacement_wait Worker_pending
          | Reconciliation_pending (Declaration_unavailable _) -> Replacement_wait Worker_unreachable
          | Reconciliation_pending Execution_unresolved -> Replacement_wait Worker_unknown in
  let* replacement=reconcile_replacement () in
  match replacement with
  | Replacement_wait wait -> Ok (Waited (wait,record))
  | Continue_original ->
  let* result=Submit.resume ~store ~label:"History Memory" ~original:record ~source ~decode_final
    ~unadmitted ~prepare:admit ~call ~terminal in
  match result with
  | Submit.Awaiting (wait,record) -> Ok (Waited (wait,record))
  | Final (body,Answer (proposal,record)) -> publish_answer body record proposal
  | Final (body,Refusal (Exact.Outcome_unknown,record)) ->
    let original=Owner.listed record in
    let wait ()=Ok (Waited (Worker_unknown,original)) in
    let* cause=unknown_cause ~schema:body.schema record in
    (match cause with
     | Some Exact.Interrupted -> wake ();wait ()
     | None | Some Exact.Raised -> wait ()
     | Some Exact.Cut ->
       let* released=io (fun () -> Keeper_librarian_declaration_replacement.released_cut
         ~store ~original ~exact:body.exact ~captured:destination) |> rejected in
       if released then finish_replacement original else
       match Keeper_librarian_durable_edge.observe_destination ~config ~reserved destination with
       | Error (Unavailable _ | Rejected _ | Uncertain _) -> wait ()
       | Ok current ->
         match Lane_addon_captured_destination.relation ~captured:destination ~current with
         | Same | Other_owner -> wait ()
         | Replaced ->
           let* ()=confirm_live_owner () in
           let* released=io (fun () -> Keeper_librarian_declaration_replacement.release_cut
             ~store ~original ~exact:body.exact ~captured:destination ~current) in
           finish_replacement released)
  | Final (body,Refusal ((Exact.Call_final _ | Not_allowed _ | Request_id_reused as final),record)) ->
    let* replacement = match final with
      | Exact.Not_allowed _ ->
        io (fun () ->
          let* target=Keeper_librarian_original_final.target
            ~installation_id:destination.installation_id body.exact in
          Keeper_librarian_original_final.declaration_replaced ~store target record) |> rejected
      | Call_final _ | Outcome_unknown | Request_id_reused -> Ok false in
    if replacement then finish_replacement (Owner.listed record)
    else Ok (Resumed (Refused (final,record),body.request))
  | Commit_pending record ->
    let* body=read_body () in
    let* record=rebind body record in
    let* _,proposal=restore_answer ~store body.request record in
    publish_answer body record proposal
  | Settled record ->
    let* body=read_body () in
    let* record=rebind body record in
    (match Progress.phase record.progress with
     | Progress.Finished _ ->
       let* _=restore_answer ~store body.request record in
       Ok (Resumed (Finished record,body.request))
     | Conflicted _ ->
       let* _,proposal=restore_answer ~store body.request record in
       publish_answer body record proposal
     | Rejected {stage=Progress.Before_dispatch;evidence} ->
       let* _=rejected (Request.confirm_replaced body.request evidence) in
       Ok (Resumed (Ended_unadmitted record,body.request))
     | Rejected {stage=Progress.Execution;_} | Subdividing _ | Subdivided _ ->
       Error (Rejected "Original history request has a terminal host refusal")
     | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _ ->
       Error (Rejected "Original history request unexpectedly settled without terminal progress"))
