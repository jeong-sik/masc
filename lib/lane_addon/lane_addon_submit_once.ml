module Owner = Lane_addon_tool_request_owner
module Progress = Lane_addon_request_progress
module Exact = Lane_addon_exact
module Runtime = Lane_addon_runtime
open Result.Syntax

type error = Unavailable of string | Rejected of string | Uncertain of string
let error_to_string = function Unavailable detail | Rejected detail | Uncertain detail -> detail
let rejected value = Result.map_error (fun detail -> Rejected detail) value

let error_of_runtime = function
  | Runtime.Unavailable detail -> Unavailable detail
  | Runtime.Outcome_unknown detail -> Uncertain detail
  | Runtime.Host_refusal refusal -> (match refusal with
      | Lane_addon_call_context.Rejected detail | Activity_disabled detail -> Rejected detail
      | Unavailable detail | Activity_unobserved detail -> Unavailable detail)

type call_error = Not_sent of error | Sent_unknown of string
type call = arguments:Yojson.Safe.t ->
  (Mcp_protocol.Mcp_types.tool_result, call_error) Stdlib.result
let call_error_of_runtime = function
  | Runtime.Outcome_unknown detail -> Sent_unknown detail
  | (Runtime.Unavailable _ | Runtime.Host_refusal _) as error -> Not_sent (error_of_runtime error)

type wait = Capacity | Worker_pending | Worker_unknown | Worker_unreachable
  | Missing_after_dispatch | Journal_recheck
type 'final result =
  | Awaiting of wait * Owner.retained
  | Final of 'final
  | Commit_pending of Owner.retained
  | Settled of Owner.retained

type worker_state = Absent | Pending | Capacity_wait | Finished of Exact.final
let reply ~label ~request_id ~schema (response : Mcp_protocol.Mcp_types.tool_result) =
  let context = label ^ " Add-on reply" in
  let* () = match response.is_error with
    | Some true -> Error (Unavailable (Agent_core.Mcp.text_of_tool_result response))
    | None | Some false -> Ok () in
  let* json = match response.structured_content with
    | Some json -> Ok json
    | None -> Error (Rejected (label ^ " reply has no structured content")) in
  let parse () =
    let* fields = Candle_json.object_fields ~context json in
    let* id, fields = Candle_json.field ~context "request_id" Candle_json.as_non_blank fields in
    let* () = if id = request_id then Ok ()
      else Error (label ^ " reply belongs to another original request") in
    let* state, fields = Candle_json.field ~context "state" Candle_json.as_string fields in
    let* state, fields = match state with
      | "absent" -> Ok (Absent, fields)
      | "pending" -> Ok (Pending, fields)
      | "capacity_wait" -> Ok (Capacity_wait, fields)
      | "finished" ->
        let* final, fields = Candle_json.field ~context "result" (Exact.final_of_json ~schema) fields in
        Ok (Finished final, fields)
      | _ -> Error ("Unknown " ^ label ^ " worker state") in
    let* () = Candle_json.finish ~context fields in
    Ok (state, json) in
  rejected (parse ())

type publication = New of Owner.retained | Acknowledged of Owner.retained
let advance ~store original event =
  match Owner.advance ~store ~expected:original ~event with
  | Ok (Owner.Stored record) -> Ok (New record)
  | Ok (Owner.Already_stored record) -> Ok (Acknowledged record)
  | Ok (Owner.Unconfirmed detail) -> Error (Uncertain detail)
  | Error error -> Error (Unavailable (Owner.update_error_to_string error))
let record = function New record | Acknowledged record -> record
let publish ~store original event =
  Eio_unix.run_in_systhread (fun () -> advance ~store original event)

let same_observation left right = match left, right with
  | Progress.Waiting left, Progress.Waiting right
  | Progress.Outcome_unknown left, Progress.Outcome_unknown right
  | Progress.Absent left, Progress.Absent right -> Yojson.Safe.equal left right
  | Progress.Waiting _, (Progress.Outcome_unknown _ | Progress.Absent _)
  | Progress.Outcome_unknown _, (Progress.Waiting _ | Progress.Absent _)
  | Progress.Absent _, (Progress.Waiting _ | Progress.Outcome_unknown _) -> false

(* How one worker call ended. A reply that arrived but cannot be read still
   followed the RPC, so only a call the host refused before sending is
   [Unsent]. *)
type attempt_error = Unsent of error | Unknown of error

let resume ~store ~label ~(original : Owner.retained) ~request ~schema ~prepare
    ~(call : call) ~terminal =
  let final original final =
    let* value = terminal original final in
    Ok (Final value) in
  let observe_host (original : Owner.retained) =
    let* installation = rejected (Owner.installation_of_id original.installation_id) in
    let* declaration_id = match installation with
      | Owner.Configuration id -> Ok id
      | Owner.Manual _ ->
        Error (Rejected ("Original " ^ label ^ " work requires its configured installation")) in
    Eio_unix.run_in_systhread (fun () ->
      Exact.observe_retained ~store ~declaration_id ~schema request)
    |> Result.map_error (fun detail -> Unavailable detail) in
  let observe (original : Owner.retained) reason observation evidence =
    let observation = observation evidence in
    match Progress.phase original.progress with
    | Progress.Dispatch_pending (Some previous) when same_observation previous observation ->
      Ok (Awaiting (reason, original))
    | Progress.Captured | Progress.Admission_wait _ | Progress.Dispatch_pending (None | Some _)
    | Progress.Judged _ | Progress.Committing _ | Progress.Commit_unknown _ | Progress.Finished _
    | Progress.Conflicted _ | Progress.Rejected _ | Progress.Subdividing _ | Progress.Subdivided _ ->
      let* published = publish ~store original (Progress.Execution_observed observation) in
      Ok (Awaiting (reason, record published)) in
  let unknown original error =
    observe original Worker_unknown (fun value -> Progress.Outcome_unknown value)
      (`Assoc ["detail", `String (error_to_string error)]) in
  let finish original result =
    let delivered = Exact.delivered result in
    let* _ = terminal original delivered in
    let event = match result with
      | Exact.Retained_call (Exact.Answered _) ->
        Progress.Judgment_retained (Exact.retained_final_to_json result)
      | Exact.Retained_call (Exact.Invalid_output _ | Exact.Input_refused _ | Exact.Output_limit_reached _)
      | Exact.Retained_unknown _ | Exact.Retained_not_allowed _ | Exact.Retained_request_id_reused ->
        Progress.Refused {stage = Progress.Execution; evidence = Exact.retained_final_to_json result} in
    let* published = publish ~store original event in
    final (record published) delivered in
  let finish_worker original = function
    | Exact.Call_final result -> finish original (Exact.Retained_call result)
    | Exact.Not_allowed {reason} -> finish original (Exact.Retained_not_allowed {reason})
    | Exact.Request_id_reused -> finish original Exact.Retained_request_id_reused
    | Exact.Outcome_unknown ->
      (* The worker has no authority to name the cause. It can only echo a
         terminal the host retained before delivery. Re-read that authority
         after the RPC, including a synchronous submission completion. *)
      let* retained = observe_host original in
      (match retained with
       | Exact.Retained_terminal (Exact.Retained_unknown _ as result) -> finish original result
       | Exact.Retained_absent | Exact.Retained_open
       | Exact.Retained_terminal (Exact.Retained_call _ | Exact.Retained_not_allowed _
                                 | Exact.Retained_request_id_reused) ->
         Error (Rejected ("Worker outcome_unknown contradicts original " ^ label ^ " host execution"))) in
  let received original ~submission state evidence = match state with
    | Pending -> observe original Worker_pending (fun value -> Progress.Waiting value) evidence
    | Absent -> observe original Missing_after_dispatch (fun value -> Progress.Absent value) evidence
    | Capacity_wait ->
      if submission then
        let* published = publish ~store original (Progress.Admission_declined evidence) in
        Ok (Awaiting (Capacity, record published))
      else Error (Rejected (label ^ " read cannot grant a pre-admission capacity refusal"))
    | Finished result -> finish_worker original result in
  let invoke arguments =
    match call ~arguments with
    | Error (Not_sent error) -> Error (Unsent error)
    | Error (Sent_unknown detail) -> Error (Unknown (Uncertain detail))
    | Ok response ->
      reply ~label ~request_id:original.request_id ~schema response
      |> Result.map_error (fun error -> Unknown error) in
  let read = `Assoc ["kind", `String "read"; "request_id", `String original.request_id] in
  let wait_before_send original = function
    | Unavailable _ -> Ok (Awaiting (Worker_unreachable, original))
    | (Rejected _ | Uncertain _) as error -> Error error in
  let admit original =
    match prepare () with
    | Error error -> wait_before_send original error
    | Ok () ->
    let* published = publish ~store original Progress.Dispatch_intended in
    match published with
    | Acknowledged record -> Ok (Awaiting (Journal_recheck, record))
    | New original ->
      let submit = `Assoc ["kind", `String "submit"; "request", Exact.request_to_json request] in
      (match invoke submit with
       | Ok (state, evidence) -> received original ~submission:true state evidence
       | Error (Unsent error) ->
         (* The host refused before the RPC, so this intent admitted nothing.
            Decline it in place: the next pass reads absence and may submit. *)
         let* _ = publish ~store original
           (Progress.Admission_declined (`Assoc ["not_sent", `String (error_to_string error)])) in
         Error error
       | Error (Unknown error) ->
         (* A missing or malformed reply can follow durable admission. Keep
            the original intent; no later absence grants another submit. *)
         unknown original error) in
  match Progress.phase original.progress with
  | Progress.Judged judgment ->
    let* result = rejected (Exact.final_of_json ~schema judgment) in
    (match result with
     | Exact.Call_final (Exact.Answered _) -> final original result
     | Exact.Call_final (Exact.Invalid_output _ | Exact.Input_refused _ | Exact.Output_limit_reached _)
     | Exact.Outcome_unknown | Exact.Not_allowed _ | Exact.Request_id_reused ->
       Error (Rejected ("Original " ^ label ^ " judgment does not contain an answered result")))
  | Progress.Committing _ | Progress.Commit_unknown _ -> Ok (Commit_pending original)
  | Progress.Rejected {stage = Progress.Execution; evidence}
  | Progress.Subdividing ({stage = Progress.Execution; evidence}, _)
  | Progress.Subdivided ({stage = Progress.Execution; evidence}, _) ->
    let* retained = rejected (Exact.retained_final_of_json ~schema evidence) in
    let result = Exact.delivered retained in
    (match result with
     | Exact.Call_final (Exact.Answered _) ->
       Error (Rejected ("Refused original " ^ label ^ " work cannot contain an answered judgment"))
     | Exact.Call_final (Exact.Invalid_output _ | Exact.Input_refused _ | Exact.Output_limit_reached _)
     | Exact.Outcome_unknown | Exact.Not_allowed _ | Exact.Request_id_reused -> final original result)
  | Progress.Finished _ | Progress.Conflicted _ | Progress.Rejected {stage = Progress.Before_dispatch; _}
  | Progress.Subdividing ({stage = Progress.Before_dispatch; _}, _)
  | Progress.Subdivided ({stage = Progress.Before_dispatch; _}, _) -> Ok (Settled original)
  | Progress.Captured | Progress.Admission_wait _ ->
    (match invoke read with
     | Error (Unsent error) -> wait_before_send original error
     | Error (Unknown error) -> Error error
     | Ok (Absent, _) -> admit original
     | Ok ((Pending | Capacity_wait | Finished _), _) ->
       Error (Rejected ("Worker state contradicts original " ^ label ^ " pre-admission progress")))
  | Progress.Dispatch_pending _ ->
    let* retained = observe_host original in
    (match retained with
     | Exact.Retained_terminal result -> finish original result
     | Exact.Retained_absent | Exact.Retained_open ->
       match invoke read with
       | Ok (state, evidence) -> received original ~submission:false state evidence
       (* The worker that may hold this request cannot be reached now. That
          is no new fact about it; wait without a journal write. A refused
          destination or owner is not a wait and is returned. *)
       | Error (Unsent error) -> wait_before_send original error
       | Error (Unknown error) -> unknown original error)
