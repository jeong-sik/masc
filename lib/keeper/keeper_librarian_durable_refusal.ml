module Request = Keeper_librarian_durable_request
module Retained = Lane_addon_tool_request_owner
module Progress = Lane_addon_request_progress
module Exact = Lane_addon_exact
module Runtime = Keeper_librarian_runtime
module Consumer = Keeper_librarian_durable_consumer
module Source = Keeper_librarian_durable_capture
module Edge = Keeper_librarian_durable_edge
open Result.Syntax
let io f = Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ f
type t = {request_id:string;destination:Request.destination;refusal:Consumer.error}
let detail = function
  | Exact.Call_final (Answered _) -> "Unexpected answered result in original history refusal"
  | Call_final (Invalid_output _ | Input_refused _ | Output_limit_reached _)
  | Outcome_unknown | Not_allowed _ | Request_id_reused as final ->
    "Original history request refused: " ^ Yojson.Safe.to_string (Exact.final_to_json final)
let report ~store request final =
  let detail=detail final in
  match io (fun () -> Request.refusal_evidence ~store request final) with
  | Ok evidence -> Runtime.not_committed_of_failure ~detail evidence
  | Error why -> Runtime.not_committed_of_failure
      ~detail:(detail ^ "; reading less could not be judged: " ^ why) Keeper_exact_walk_failure.empty
let retained_stop ~store ~(record:Retained.retained) ~request =
  let source=Request.source request in
  let input=Source.input source in
  match Progress.phase record.progress with
  | Rejected {stage=Progress.Execution;evidence} ->
    if input.messages<>[] || input.tool_observations<>[] || input.counterpart_observations=[] then Ok None else
    let* exact=Request.request request in
    let* schema=Option.to_result ~none:"Original history refusal lacks its schema" exact.schema in
    let* retained=Exact.retained_final_of_json ~schema evidence in
    let final=Exact.delivered retained in
    (match final with
     | Exact.Call_final (Input_refused (Input_capacity | Context_overflow | Request_body_refused)) ->
       (* Unlike a display report, an unreadable proof cannot release this
          original for another request. Whole-inventory validation precedes us. *)
       let* evidence=io (fun () -> Request.refusal_evidence ~store request final) in
       let report=Runtime.not_committed_of_failure ~detail:(detail final) evidence in
       (match Consumer.refused_original source [report] with
        | Error refusal ->
          let* committed=io (fun () ->
            let* past=Keeper_librarian_refusal_frontier.past_original request in
            if past then Ok true else Keeper_librarian_durable_commit.receipt_state request) in
          Ok (if committed then None else Some {request_id=record.request_id;
            destination=Request.destination request;refusal})
        | Ok _ -> Ok None)
     | Call_final (Answered _ | Invalid_output _ | Input_refused Invalid_request | Output_limit_reached _)
     | Outcome_unknown | Not_allowed _ | Request_id_reused -> Ok None)
  | Captured | Admission_wait _ | Dispatch_pending _ | Judged _ | Committing _ | Commit_unknown _
  | Finished _ | Conflicted _ | Rejected {stage=Progress.Before_dispatch;_}
  | Subdividing _ | Subdivided _ -> Ok None
let request_id stop=stop.request_id
let blocks_destination stops current =
  List.find_map (fun stop -> if Edge.same_destination current stop.destination
    then Some stop.refusal else None) stops
let blocked ~config ~reserved = function
  | [] -> None
  | (first::_ as stops) ->
    match Edge.with_destination ~config ~reserved (fun current -> Ok (blocks_destination stops current)) with
    | Ok refusal -> refusal
    | Error _ -> Some first.refusal
