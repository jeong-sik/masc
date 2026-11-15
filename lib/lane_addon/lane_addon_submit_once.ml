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
type ('original, 'final) result =
  | Awaiting of wait * 'original
  | Final of 'final
  | Commit_pending of 'original
  | Settled of 'original

(* A finished reply keeps its result as the worker wrote it. Reading it needs
   the original's body, which the caller of [reply] reads only then. *)
type worker_state = Absent | Pending | Capacity_wait | Finished of Yojson.Safe.t
let reply ~label ~request_id (response : Mcp_protocol.Mcp_types.tool_result) =
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
        let* result, fields = Candle_json.field ~context "result" (fun json -> Ok json) fields in
        Ok (Finished result, fields)
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
type stored = Fresh of Owner.Record.t | Seen of Owner.Record.t
let stored_record = function Fresh record | Seen record -> record
let publish ~store original event =
  Systhread_host.run ~label:"addon-submit-once-advance" (fun () ->
    match Owner.advance_record ~store ~expected:original ~event with
    | Ok (Owner.Record_stored record) -> Ok (Fresh record)
    | Ok (Owner.Record_already_stored record) -> Ok (Seen record)
    | Ok (Owner.Record_unconfirmed detail) -> Error (Uncertain detail)
    | Error error -> Error (Unavailable (Owner.update_error_to_string error)))

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

type 'body source = {
  identity : Exact.identity;
  load : unit -> ('body, error) Stdlib.result;
  request : 'body -> Exact.request;
  schema : 'body -> Yojson.Safe.t;
}

let resume ~store ~label ~(original : Owner.Record.t) ~(source : _ source) ~decode_final ~prepare
    ~(call : call) ~terminal =
  let request_id = Owner.Record.request_id original in
  (* The body is read on entering a branch that needs it, once for the pass.
     A failed read is this pass's error and leaves the journal as it was. *)
  let loaded = ref None in
  let body () = match !loaded with
    | Some body -> Ok body
    | None ->
      let* body = source.load () in
      loaded := Some body;
      Ok body in
  let final body original final =
    let* value = terminal body original final in
    Ok (Final value) in
  let declaration_id () =
    let* installation = rejected (Owner.installation_of_id (Owner.Record.installation_id original)) in
    match installation with
    | Owner.Configuration id -> Ok id
    | Owner.Manual _ ->
      Error (Rejected ("Original " ^ label ^ " work requires its configured installation")) in
  let recovery_error = function
    (* A record that exists but is not a trustworthy original can never
       become one by waiting, so it is refused. Only a record this read
       could not reach stays a retryable unavailability. *)
    | Exact.Recovery_invalid detail -> Rejected detail
    | Exact.Recovery_unavailable detail -> Unavailable detail in
  let observe_host body =
    let* declaration_id = declaration_id () in
    Eio.Cancel.protect (fun () -> Systhread_host.run ~label:"addon-submit-once-recover" (fun () ->
      Exact.recover_retained ~store ~declaration_id ~schema:(source.schema body) (source.request body)))
    |> Result.map_error recovery_error in
  let observe_open () =
    let* declaration_id = declaration_id () in
    Systhread_host.run ~label:"addon-submit-once-observe-open" (fun () ->
      Exact.observe_open ~store ~declaration_id source.identity)
    |> Result.map_error recovery_error in
  let observe original reason observation evidence =
    let observation = observation evidence in
    match Progress.phase (Owner.Record.progress original) with
    | Progress.Dispatch_pending (Some previous) when same_observation previous observation ->
      Ok (Awaiting (reason, original))
    | Progress.Captured | Progress.Admission_wait _ | Progress.Dispatch_pending (None | Some _)
    | Progress.Judged _ | Progress.Committing _ | Progress.Commit_unknown _ | Progress.Finished _
    | Progress.Conflicted _ | Progress.Rejected _ | Progress.Subdividing _ | Progress.Subdivided _ ->
      let* published = publish ~store original (Progress.Execution_observed observation) in
      Ok (Awaiting (reason, stored_record published)) in
  let unknown original error =
    observe original Worker_unknown (fun value -> Progress.Outcome_unknown value)
      (`Assoc ["detail", `String (error_to_string error)]) in
  let finish body original result =
    let delivered = Exact.delivered result in
    let* _ = terminal body original delivered in
    let event = match result with
      | Exact.Retained_call (Exact.Answered _) ->
        Progress.Judgment_retained (Exact.retained_final_to_json result)
      | Exact.Retained_call (Exact.Invalid_output _ | Exact.Input_refused _ | Exact.Output_limit_reached _)
      | Exact.Retained_unknown _ | Exact.Retained_not_allowed _ | Exact.Retained_request_id_reused ->
        Progress.Refused {stage = Progress.Execution; evidence = Exact.retained_final_to_json result} in
    let* published = publish ~store original event in
    final body (stored_record published) delivered in
  let finish_worker body original = function
    | Exact.Call_final result -> finish body original (Exact.Retained_call result)
    | Exact.Not_allowed {reason} -> finish body original (Exact.Retained_not_allowed {reason})
    | Exact.Request_id_reused -> finish body original Exact.Retained_request_id_reused
    | Exact.Outcome_unknown ->
      (* The worker has no authority to name the cause. It can only echo a
         terminal the host retained before delivery. Re-read that authority
         after the RPC, including a synchronous submission completion. *)
      let* retained = observe_host body in
      (match retained with
       | Exact.Retained_terminal (Exact.Retained_unknown _ as result) -> finish body original result
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
        Ok (Awaiting (Capacity, stored_record published))
      else Error (Rejected (label ^ " read cannot grant a pre-admission capacity refusal"))
    | Finished result ->
      (* The body is read before the result is. A body that cannot be read
         ends the pass with nothing written; a result that cannot be read is
         a reply of unknown meaning, as it was when one step read both. *)
      let* body = body () in
      (* A dispatched original used to have its schema checked against its
         request before every worker read. That check now runs here, where
         the body is first read for it; a mismatch can never be cured by
         waiting and is refused before anything is published. *)
      let* () = if submission then Ok () else
        let* declaration_id = declaration_id () in
        rejected (Exact.confirm_original_schema ~declaration_id ~schema:(source.schema body)
          (source.request body)) in
      (match decode_final body result with
       | Ok result -> finish_worker body original result
       | Error detail ->
         (* The words one step wrote when it read state and result together,
            so an observation stored before this split still compares equal. *)
         unknown original (Rejected (Printf.sprintf "%s Add-on reply.result: %s" label detail))) in
  let invoke arguments =
    match call ~arguments with
    | Error (Not_sent error) -> Error (Unsent error)
    | Error (Sent_unknown detail) -> Error (Unknown (Uncertain detail))
    | Ok response ->
      reply ~label ~request_id response |> Result.map_error (fun error -> Unknown error) in
  let read = `Assoc ["kind", `String "read"; "request_id", `String request_id] in
  let wait_before_send original = function
    | Unavailable _ -> Ok (Awaiting (Worker_unreachable, original))
    | (Rejected _ | Uncertain _) as error -> Error error in
  let admit original =
    match prepare () with
    | Error error -> wait_before_send original error
    | Ok () ->
    (* No intent is stored for a body that cannot be read. *)
    let* body = body () in
    let* published = publish ~store original Progress.Dispatch_intended in
    match published with
    | Seen record -> Ok (Awaiting (Journal_recheck, record))
    | Fresh original ->
      let submit = `Assoc ["kind", `String "submit";
        "request", Exact.request_to_json (source.request body)] in
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
  let read_worker original =
    match invoke read with
    | Ok (state, evidence) -> received original ~submission:false state evidence
    (* The worker that may hold this request cannot be reached now. That
       is no new fact about it; wait without a journal write. A refused
       destination or owner is not a wait and is returned. *)
    | Error (Unsent error) -> wait_before_send original error
    | Error (Unknown error) -> unknown original error in
  match Progress.phase (Owner.Record.progress original) with
  | Progress.Judged judgment ->
    let* body = body () in
    let* result = rejected (decode_final body judgment) in
    (match result with
     | Exact.Call_final (Exact.Answered _) -> final body original result
     | Exact.Call_final (Exact.Invalid_output _ | Exact.Input_refused _ | Exact.Output_limit_reached _)
     | Exact.Outcome_unknown | Exact.Not_allowed _ | Exact.Request_id_reused ->
       Error (Rejected ("Original " ^ label ^ " judgment does not contain an answered result")))
  | Progress.Committing _ | Progress.Commit_unknown _ -> Ok (Commit_pending original)
  | Progress.Rejected {stage = Progress.Execution; evidence}
  | Progress.Subdividing ({stage = Progress.Execution; evidence}, _)
  | Progress.Subdivided ({stage = Progress.Execution; evidence}, _) ->
    let* body = body () in
    let* retained = rejected (Exact.retained_final_of_json ~schema:(source.schema body) evidence) in
    let result = Exact.delivered retained in
    (match result with
     | Exact.Call_final (Exact.Answered _) ->
       Error (Rejected ("Refused original " ^ label ^ " work cannot contain an answered judgment"))
     | Exact.Call_final (Exact.Invalid_output _ | Exact.Input_refused _ | Exact.Output_limit_reached _)
     | Exact.Outcome_unknown | Exact.Not_allowed _ | Exact.Request_id_reused -> final body original result)
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
    let* observed = observe_open () in
    (match observed with
     | Exact.No_record | Exact.Open -> read_worker original
     | Exact.Needs_request ->
       (* A final or an execution link exists. Reading either needs the whole
          request, so this is where a waiting original's body is read. *)
       let* body = body () in
       let* retained = observe_host body in
       (match retained with
        | Exact.Retained_terminal result -> finish body original result
        | Exact.Retained_absent | Exact.Retained_open -> read_worker original))

(* For an owner that already holds the body: nothing is read, and each record
   the machine returns is put back beside that body. *)
let resume_retained ~store ~label ~(original : Owner.retained) ~request ~schema ~decode_final ~prepare
    ~call ~terminal =
  let rebind record = match Owner.rebind original record with
    | Some retained -> Ok retained
    | None -> Error (Rejected ("Original " ^ label ^ " record names another request")) in
  let source = {identity = Exact.identity request; load = (fun () -> Ok ());
    request = (fun () -> request); schema = (fun () -> schema)} in
  let* result = resume ~store ~label ~original:(Owner.listed original) ~source
    ~decode_final:(fun () json -> decode_final json) ~prepare ~call
    ~terminal:(fun () record final ->
      let* retained = rebind record in
      terminal retained final) in
  match result with
  | Final value -> Ok (Final value)
  | Awaiting (wait, record) -> let* retained = rebind record in Ok (Awaiting (wait, retained))
  | Commit_pending record -> let* retained = rebind record in Ok (Commit_pending retained)
  | Settled record -> let* retained = rebind record in Ok (Settled retained)
