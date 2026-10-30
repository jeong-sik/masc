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
type wait = Submit.wait = Capacity | Worker_pending | Worker_unknown | Worker_unreachable
  | Missing_after_dispatch | Journal_recheck
type publication = Publication_pending of string | Publication_complete of Owner.retained
  | Publication_superseded of Owner.retained
type publish = original:Owner.retained -> request:Request.t ->
  proposal:Memory_runtime.durable_proposal -> (publication,error) result
type call = expected:Request.destination -> original:Owner.retained -> arguments:Yojson.Safe.t ->
  (Mcp_protocol.Mcp_types.tool_result,Submit.call_error) result
type outcome = Pending of wait * Owner.retained | Publication_waiting of string
  | Refused of Exact.final * Owner.retained | Finished of Owner.retained
  | Basis_superseded of Owner.retained
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
  io (fun () -> Request.confirm_predecessor ~store ~require_confirmed:dispatch request) |> rejected
let retain ~store request =
  let* ()=io (fun () -> Request.confirm_owner request) |> rejected in
  let* ()=check_predecessor ~store ~dispatch:false request in
  let destination=Request.destination request in
  let scope=Request.scope (Request.physical_owner request) and request_id=Request.request_id request in
  let* ()=io (fun () -> Owner.retain ~store ~scope ~request_id
    ~installation_id:destination.installation_id ~package_id:destination.package_id ~tool:destination.tool ~summary:`Null
    ~request:(Request.to_json request)) |> owned in
  let* record=io (fun () -> Owner.load ~store ~scope ~request_id) |> owned in
  let* record=match record with Some record -> Ok record
    | None -> Error (Uncertain "Retained original history request is not observable") in
  let* ()=check_request request record in Ok record
let discover ~store ~base_path ~keepers_dir ~keeper_id =
  let* scope=io (fun () -> Request.discovery_scope ~base_path ~keepers_dir ~keeper_id) |> rejected in
  let* records=io (fun () -> Owner.load_scope ~store ~scope) |> owned in
  let rec restore found = function
    | [] -> Ok (List.rev found)
    | record::rest ->
      let* owner=io (fun () -> Request.observe_record_owner ~base_path ~keepers_dir record) |> rejected in
      let* ()=require (Request.keeper_id owner=keeper_id) "History inventory includes another Keeper" in
      let* request=io (fun () -> Request.restore ~owner record) |> rejected in
      restore ((record,request)::found) rest in
  restore [] records
let original_judgment (record:Owner.retained) =
  match Progress.phase record.progress with
  | Progress.Judged judgment -> Ok judgment
  | Committing commit | Commit_unknown (commit,_) | Finished commit | Conflicted (commit,_) -> Ok commit.judgment
  | Captured | Admission_wait _ | Dispatch_pending _ | Rejected _ | Subdividing _ | Subdivided _ ->
    Error (Rejected "Original history record has no answered host judgment")
let restore_answer ~store ~schema request record =
  let* judgment=original_judgment record in
  let* final=rejected (Exact.final_of_json ~schema judgment) in
  let* ()=io (fun () -> Request.confirm_final ~store request final) |> rejected in
  match final with
  | Exact.Call_final (Exact.Answered {output;_}) ->
    let* proposal=rejected (Request.validate_proposal request (Exact.checked_json output)) in
    Ok (final,proposal)
  | Call_final (Invalid_output _ | Input_refused _ | Output_limit_reached _)
  | Outcome_unknown | Not_allowed _ | Request_id_reused ->
    Error (Rejected "Original history publication requires an actual answered host result")
type terminal = Answer of Memory_runtime.durable_proposal * Owner.retained
  | Refusal of Exact.final * Owner.retained
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
let resume ~store ~config ~reserved ~(original:Owner.retained) ~request ~(call:call) ~(publish:publish) ~wake =
  let confirm_live_owner () =
    let owner=Request.physical_owner request in
    let base_path=config.Workspace.base_path in
    let keepers_dir=Config_dir_resolver.keepers_dir_for_base_path ~base_path in
    let* actual=io (fun () -> Request.observe_owner ~base_path ~keepers_dir ~keeper_id:(Request.keeper_id owner)) |> rejected in
    rejected (Request.owner_matches_json actual (Request.owner_to_json owner)) in
  let* ()=check_request request original in
  let* ()=confirm_live_owner () in
  let* ()=check_predecessor ~store ~dispatch:true request in
  let* exact=rejected (Request.request request) in
  let* schema=match exact.schema with Some schema -> Ok schema
    | None -> Error (Rejected "Original history request has no output schema") in
  let destination=Request.destination request in
  let prepare () =
    let* ()=confirm_live_owner () in
    Keeper_librarian_durable_edge.confirm_destination ~config ~reserved destination in
  let admit () =
    let* ()=Memory_runtime.require_counterpart_template (Request.preparation request) |> rejected in
    prepare () in
  let call ~arguments =
    match prepare () with
    | Error error -> Error (Submit.Not_sent error)
    | Ok () -> call ~expected:destination ~original ~arguments in
  let terminal record final =
    let* ()=confirm_live_owner () in
    let* ()=io (fun () -> Request.confirm_final ~store request final) |> rejected in
    match final with
    | Exact.Call_final (Exact.Answered {output;_}) ->
      let* proposal=rejected (Request.validate_proposal request (Exact.checked_json output)) in
      Ok (Answer (proposal,record))
    | Call_final (Invalid_output _ | Input_refused _ | Output_limit_reached _)
    | Outcome_unknown | Not_allowed _ | Request_id_reused -> Ok (Refusal (final,record)) in
  let publish_answer record proposal =
    let* ()=Memory_runtime.require_counterpart_template (Request.preparation request) |> rejected in
    let* published=publish ~original:record ~request ~proposal in
    match published with
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
  let* result=Submit.resume ~store ~label:"History Memory" ~original ~request:exact ~schema ~prepare:admit ~call ~terminal in
  match result with
  | Submit.Awaiting (wait,record) -> Ok (Pending (wait,record))
  | Final (Answer (proposal,record)) -> publish_answer record proposal
  | Final (Refusal (Exact.Outcome_unknown,record)) -> Ok (Pending (Worker_unknown,record))
  | Final (Refusal ((Exact.Call_final _ | Not_allowed _ | Request_id_reused as final),record)) ->
    Ok (Refused (final,record))
  | Commit_pending record ->
    let* _,proposal=restore_answer ~store ~schema request record in
    publish_answer record proposal
  | Settled record ->
    (match Progress.phase record.progress with
     | Progress.Finished _ ->
       let* _=restore_answer ~store ~schema request record in
       Ok (Finished record)
     | Conflicted _ ->
       let* _,proposal=restore_answer ~store ~schema request record in
       publish_answer record proposal
     | Rejected _ | Subdividing _ | Subdivided _ ->
       Error (Rejected "Original history request has a terminal host refusal")
     | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _ ->
       Error (Rejected "Original history request unexpectedly settled without terminal progress"))
