module Fetched = Masc_tui_fetched
module Reading = Masc_tui_detail_reading
module Dispatch = Masc_tui_task_dispatch
type receipt = Unobserved of int
  | Recorded of { task_id : string; backlog_version : int }
  | Ambiguous of { task_ids : string list; backlog_version : int }
type error = Workspace_unconfirmed of string | Read_failed of string
  | Invalid_reply of string | Interrupted
type request = string Fetched.request
type t = {
  origin : Dispatch.intent;
  fetched : (string,receipt,error) Fetched.source;
  transport : Dispatch.progress;
  document : Reading.t;
}
let origin t = t.origin
let arguments t = match t.origin.workspace with
  | None -> Error (Workspace_unconfirmed "The original creation has no confirmed workspace.")
  | Some expected -> Ok ["creation_request_id",`String t.origin.request_id;
      "expected_workspace",`Assoc ["base_path",`String (Masc.Tui_decode.Canonical_path.to_string expected.Masc.Tui_decode.sid_base_path);
                                   "masc_root",`String (Masc.Tui_decode.Canonical_path.to_string expected.sid_masc_root)]]
let invalid detail = Error (Invalid_reply detail)
let ( let* ) = Result.bind
let field key = function
  | `Assoc fields ->
    (match List.filter (fun (name,_) -> String.equal name key) fields with
     | [_,value] -> Ok value
     | _ -> invalid ("Missing or duplicate creation receipt field: " ^ key))
  | _ -> invalid "Creation receipt must be an object"
let string = function `String value -> Ok value | _ -> invalid "Creation receipt field must be a string"
let decode t (answer : Masc_tui_mcp.outcome) =
  if answer.is_error then Error (Read_failed answer.text)
  else match t.origin.workspace with
  | None -> Error (Workspace_unconfirmed "The original workspace is unavailable.")
  | Some expected ->
    (try
      let json = Yojson.Safe.from_string answer.text in
      let* ok = field "ok" json in
      let* () = match ok with `Bool true -> Ok () | _ -> invalid "Creation receipt is not successful" in
      let* raw = field "creation_request_id" json in
      let* request_id = string raw in
      let* () = if String.equal request_id t.origin.request_id then Ok ()
        else invalid "Creation receipt names another original request" in
      let* workspace = field "workspace" json in
      let* () = match workspace with `Assoc fields when List.length fields=2 -> Ok ()
        | _ -> invalid "Creation receipt workspace shape is invalid" in
      let* base = field "base_path" workspace in let* base = string base in
      let* root = field "masc_root" workspace in let* root = string root in
      let* () = if String.equal base (Masc.Tui_decode.Canonical_path.to_string expected.sid_base_path) && String.equal root (Masc.Tui_decode.Canonical_path.to_string expected.sid_masc_root)
        then Ok () else invalid "Creation receipt names another workspace" in
      let* version = field "backlog_version" json in
      let* version = match version with `Int version when version>0 -> Ok version
        | _ -> invalid "Creation receipt has no positive backlog revision" in
      let* receipt = field "creation_receipt" json in
      let* () = match receipt with `Assoc fields when List.length fields=2 -> Ok ()
        | _ -> invalid "Creation receipt shape is invalid" in
      let* state = field "state" receipt in let* state = string state in
      let* ids = field "task_ids" receipt in
      let* ids = match ids with
        | `List values ->
          let rec collect acc = function
            | [] -> Ok (List.rev acc)
            | `String id :: rest when String.trim id<>"" -> collect (id::acc) rest
            | _ -> invalid "Creation receipt contains an invalid Task identity" in
          collect [] values
        | _ -> invalid "Creation receipt Task identities must be a list" in
      match state,ids with
      | "not_observed",[] -> Ok (Unobserved version)
      | "recorded",[task_id] -> Ok (Recorded {task_id;backlog_version=version})
      | "ambiguous",(_::_::_ as task_ids) -> Ok (Ambiguous {task_ids;backlog_version=version})
      | _ -> invalid "Creation receipt state or cardinality is invalid"
    with Yojson.Json_error detail -> invalid detail)
let observation t = Fetched.view_for ~equal:String.equal t.fetched ~key:t.origin.request_id
let pending t = Fetched.in_flight t.fetched
let section heading body = {Reading.heading;body}
let error_text = function
  | Workspace_unconfirmed detail -> "Workspace unconfirmed: " ^ detail
  | Read_failed detail -> "Read failed: " ^ detail
  | Invalid_reply detail -> "Reply refused: " ^ detail
  | Interrupted -> "Inspection interrupted; no creation was repeated."
let receipt_sections = function
  | Unobserved version -> [section "Not observed"
      (Printf.sprintf "No creation fact was observed at backlog revision %d. This does not prove that no Task was created; do not repeat creation to find out." version)]
  | Recorded {task_id;backlog_version} ->
      [section "Creation recorded" (Printf.sprintf "%s · backlog revision %d. This is a creation fact, not current Task status, existence or completion." task_id backlog_version)]
  | Ambiguous {task_ids;backlog_version} ->
      [section "Multiple creation facts"
        (Printf.sprintf "Backlog revision %d names multiple Tasks for this request. No Task is selected automatically.\n%s"
          backlog_version (String.concat "\n" task_ids))]
let transport_text = function
  | Dispatch.Not_started -> "Not started"
  | Reserved -> "Reserved; preparation has not started"
  | Preparing -> "Preparing the original creation"
  | Sending -> "Creation send callback entered; no result yet"
  | Completed {outcome=Created {task_id;_};_} -> "Original response confirmed " ^ task_id
  | Completed {outcome=Not_sent detail;_} -> "Original creation was not sent: " ^ detail
  | Completed {outcome=Server_error detail;_} -> "Original response was an error, not proof of no creation: " ^ detail
  | Completed {outcome=Unconfirmed detail;_} -> "Original transport outcome remains unconfirmed: " ^ detail
let refresh_document t =
  let read = match observation t with
    | Fetched.Absent -> [section "Not read" "No creation fact has been requested."]
    | Loading -> [section "Read requested" "Waiting for the exact original creation lookup."]
    | Failed error -> [section "Inspection failed" (error_text error)]
    | Ready receipt -> receipt_sections receipt
    | Stale (receipt,error) -> receipt_sections receipt @ [section "Last reading · refresh unavailable" (error_text error)] in
  let read = if pending t then section "Lookup pending" "A read is pending; any retained fact and failure remain below." :: read else read in
  let sections = [section "Original Task" t.origin.title;section "Original Keeper" t.origin.keeper;
      section "Original creation transport" (transport_text t.transport)] @ read @
    [section "Original body" t.origin.body;section "Original request" t.origin.request_id;
     section "Original workspace" (match t.origin.workspace with None -> "Not confirmed"
       | Some workspace -> Masc.Tui_decode.Canonical_path.to_string workspace.sid_base_path ^ "\n" ^ Masc.Tui_decode.Canonical_path.to_string workspace.sid_masc_root);
     section "Actions" "[: older retained request · ]: newer · r: read again · o: inspect the current Task after a single ready creation fact · Esc: close. No creation, handoff or input recovery is performed here."] in
  {t with document=Reading.replace ~title:"Original Task creation · [/] requests · r read · o Task · Esc close" sections t.document}
let create origin = {origin;fetched=Fetched.initial;transport=Dispatch.Not_started;
  document=Reading.create_observation ~title:"Original Task creation" []}
let capture_transport transport t = refresh_document {t with transport}
let start t = match Fetched.refresh ~equal:String.equal t.fetched ~key:t.origin.request_id with
  | Fetched.Already_loading -> t,None
  | Started (fetched,request) -> refresh_document {t with fetched},Some request
let is_current t request = Fetched.is_current ~equal:String.equal t.fetched request
let complete t request result =
  if not (is_current t request) then t
  else refresh_document {t with fetched=Fetched.complete ~equal:String.equal t.fetched request result}
let suspend ~reason t = refresh_document {t with fetched=Fetched.suspend_with ~reason t.fetched}
let recorded_task t = match observation t with
  | Fetched.Ready (Recorded {task_id;_}) when not (pending t) -> Some task_id
  | Absent | Loading | Failed _ | Ready (Unobserved _ | Ambiguous _ | Recorded _) | Stale _ -> None
let document t = t.document
let move ~count ~height movement t = {t with document=Reading.move ~count ~height movement t.document}
