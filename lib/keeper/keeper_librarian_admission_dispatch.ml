module Capture = Keeper_librarian_admission_capture
module Owner = Lane_addon_tool_request_owner
module Exact = Lane_addon_exact
module Submit = Lane_addon_submit_once
open Result.Syntax

type error = Submit.error = Unavailable of string | Rejected of string | Uncertain of string
let error_to_string = Submit.error_to_string

type wait = Submit.wait = Capacity | Worker_pending | Worker_unknown | Worker_unreachable
  | Missing_after_dispatch | Journal_recheck
type result =
  | Pending of wait * Owner.retained
  | Answered of Exact.final * Owner.retained
  | Refused of Exact.final * Owner.retained
  | Commit_pending of Owner.retained
  | Settled of Owner.retained

type call = expected:Capture.destination -> original:Owner.retained ->
  arguments:Yojson.Safe.t -> (Mcp_protocol.Mcp_types.tool_result, Submit.call_error) Stdlib.result

let rejected value = Result.map_error (fun detail -> Rejected detail) value

let check_identity ~(destination : Capture.destination) (original : Owner.retained)
    (exact : Exact.request) =
  if original.request_id = exact.request_id
     && original.installation_id = destination.installation_id
     && original.package_id = destination.package_id && original.tool = destination.tool
  then
    let* installation = rejected (Owner.installation_of_id original.installation_id) in
    match installation with
    | Owner.Configuration _ -> Ok ()
    | Owner.Manual _ -> Error (Rejected "Original admission requires its configured installation")
  else Error (Rejected "Original admission destination or Exact request identity differs")

let confirm_destination ~config ~reserved ~(destination : Capture.destination) =
  Submit.confirm_destination ~config ~reserved ~label:"admission" destination

let resume ~store ~config ~reserved ~destination ~(original : Owner.retained)
    ~capture ~exact ~schema ~validate_answer ~(call : call) =
  let* () = check_identity ~destination original exact in
  let* captured = rejected (Capture.request capture) in
  let* actual = rejected (Lane_addon_action.canonical original.request) in
  let* expected = rejected (Lane_addon_action.canonical (Capture.to_json capture)) in
  let* original_schema = match captured.schema with
    | Some original_schema -> rejected (Lane_addon_action.canonical original_schema)
    | None -> Error (Rejected "Original admission capture has no schema") in
  let* supplied_schema = rejected (Lane_addon_action.canonical schema) in
  let* () = if Yojson.Safe.equal actual expected && Exact.digest captured=Exact.digest exact
    && Yojson.Safe.equal original_schema supplied_schema then Ok ()
    else Error (Rejected "Admission dispatch differs from its original capture") in
  let terminal original final =
    let* () = Systhread_host.run ~label:"librarian-admission-confirm-final" (fun () ->
        Capture.confirm_final ~store capture final)
      |> Result.map_error (fun detail -> Rejected detail) in
    match final with
    | Exact.Call_final (Exact.Answered {output; _}) ->
      let* () = rejected (validate_answer (Exact.checked_json output)) in
      Ok (Answered (final, original))
    | Exact.Call_final (Exact.Invalid_output _ | Exact.Input_refused _ | Exact.Output_limit_reached _)
    | Exact.Outcome_unknown | Exact.Not_allowed _ | Exact.Request_id_reused ->
      Ok (Refused (final, original)) in
  let prepare () = confirm_destination ~config ~reserved ~destination in
  let call ~arguments = match prepare () with
    | Error error -> Error (Submit.Not_sent error)
    | Ok () -> call ~expected:destination ~original ~arguments in
  let decode_final json = Systhread_host.run ~label:"librarian-admission-decode-final"
    (fun () -> Capture.decode_final ~store capture json) in
  (* Nothing re-creates an admission part, so none is ended here. [prepare]
     refuses a changed destination, as before. *)
  let* resumed = Submit.resume_retained ~store ~label:"Admission" ~original ~request:exact ~schema
    ~decode_final ~unadmitted:(fun () -> Ok Submit.Admit) ~prepare ~call ~terminal in
  match resumed with
  | Submit.Awaiting (wait, record) -> Ok (Pending (wait, record))
  | Submit.Final result -> Ok result
  | Submit.Commit_pending record -> Ok (Commit_pending record)
  | Submit.Settled record -> Ok (Settled record)
