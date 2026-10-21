module Fetched = Masc_tui_fetched
module Reading = Masc_tui_detail_reading
module Dispatch = Masc_tui_task_dispatch
type receipt = Unobserved of int
  | Recorded of { task_id : string; backlog_version : int }
  | Ambiguous of { task_ids : string list; backlog_version : int }
type error = Workspace_unconfirmed of string | Read_failed of string
  | Invalid_reply of string | Interrupted
type request = string Fetched.request
type task_request = { task_ticket : string Fetched.request; creation_ticket : request }
type task_snapshot = {
  task_id : string;
  task_observation : Masc.Tui_decode_task_inspection.observation;
  task_sections : Reading.section list;
}
type source = Creation | Task | History | Evidence
type history_request = {
  history_ticket : string Fetched.request;
  history_page : Masc.Tui_decode_task_inspection.history_request;
  history_creation : request;
}
type history_snapshot = {
  history_value : Masc.Tui_decode_task_inspection.history;
  history_sections : Reading.section list;
}
type evidence_key = { evidence_task : string; verification_id : string }
type evidence_request = { evidence_ticket : evidence_key Fetched.request; evidence_creation : request }
type evidence_snapshot = {
  evidence_key : evidence_key;
  evidence_value : Masc.Tui_decode.verification_evidence;
  evidence_sections : Reading.section list;
}
type t = {
  origin : Dispatch.intent;
  fetched : (string,receipt,error) Fetched.source;
  transport : Dispatch.progress;
  task_fetched : (string,task_snapshot,error) Fetched.source;
  displayed : source;
  history_fetched : (string,history_snapshot,error) Fetched.source;
  evidence_fetched : (evidence_key,evidence_snapshot,error) Fetched.source;
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
let prepare_task ~task_id task_observation =
  let module Task = Masc.Tui_decode_task_inspection in
  let present_sections location detail =
    if detail.Task.task.id<>task_id then Error (Invalid_reply "Task observation names another original Task")
    else Ok [section "Task observation" location;
      section "Task identity" detail.task.id;
      section "Observed status" (Masc_domain.task_status_to_string detail.task.task_status);
      section "Task title" detail.task.title;section "Task description" detail.task.description;
      section "Canonical Goal observation" (match detail.canonical_goal_id with Some id -> id | None -> "No canonical Goal link observed");
      section "Complete decoded Task fields" (Yojson.Safe.pretty_to_string (Masc_domain.task_to_yojson detail.task))] in
  let sections=match task_observation with
    | Task.In_backlog detail -> present_sections "Observed in live backlog" detail
    | In_archive detail -> present_sections "Observed in archive" detail
    | Not_observed -> Ok [section "Task not observed"
        "No exact Task was observed in the strict live backlog or archive. This is not deletion or completion proof."]
    | Deletion_recorded deletion ->
      Ok [section "Deletion recorded" (deletion.deletion_id ^ "\n" ^ deletion.requested_at);
       section "Deletion cleanup observation" (match deletion.cleanup with
         | Cleanup_required -> "Cleanup remains required; no physical cleanup success is implied."
         | Cleanup_verified -> "The retained deletion record reports verified cleanup.")] in
  Result.map (fun task_sections -> {task_id;task_observation;task_sections}) sections

let recorded_task t = match observation t with
  | Fetched.Ready (Recorded {task_id;_}) when not (pending t) -> Some task_id
  | Absent | Loading | Failed _ | Ready (Unobserved _ | Ambiguous _ | Recorded _) | Stale _ -> None
let task_view t = match recorded_task t with
  | None -> Fetched.Absent
  | Some key -> Fetched.view_for ~equal:String.equal t.task_fetched ~key
let history_view t = match recorded_task t with
  | None -> Fetched.Absent
  | Some key -> Fetched.view_for ~equal:String.equal t.history_fetched ~key
let evidence_view t = match recorded_task t,Fetched.current t.evidence_fetched with
  | Some task_id,Some (key,value) when key.evidence_task=task_id -> value
  | (Some _ | None),(Some _ | None) -> Fetched.Absent
let task_observation t = match task_view t with
  | Fetched.Absent -> Fetched.Absent | Loading -> Loading | Failed error -> Failed error
  | Ready value -> Ready value.task_observation
  | Stale (value,error) -> Stale (value.task_observation,error)
let history_observation t = match history_view t with
  | Fetched.Absent -> Fetched.Absent | Loading -> Loading | Failed error -> Failed error
  | Ready value -> Ready value.history_value
  | Stale (value,error) -> Stale (value.history_value,error)
let evidence_observation t = match evidence_view t with
  | Fetched.Absent -> Fetched.Absent | Loading -> Loading | Failed error -> Failed error
  | Ready value -> Ready value.evidence_value
  | Stale (value,error) -> Stale (value.evidence_value,error)
let prepare_history history_value =
  let ids=history_value.Masc.Tui_decode_task_inspection.history_verifications in
  let history_sections=[section "Stored history boundary"
    (match history_value.history_next_cursor with Some _ -> "Older stored events remain; H reads the next page."
     | None -> "This observed stored prefix has no older cursor; r reads a fresh prefix.");
    section "Observed verification submissions" (match ids with [] -> "No verification identity observed in this prefix."
      | _ -> String.concat "\n" ids)] @
    List.map (fun row -> section "Complete stored Task event" (Yojson.Safe.pretty_to_string row)) history_value.history_records in
  {history_value;history_sections}
let prepare_evidence ~task_id ~verification_id evidence_value =
  let module Decode = Masc.Tui_decode in
  let sections=match evidence_value with
    | Decode.Evidence_access_unavailable reason -> Error (Read_failed reason)
    | Evidence_items [] -> Ok [section "Submitted evidence" "The recorded submission has no inspectable items."]
    | Evidence_items items -> Ok (List.concat_map (function
      | Decode.Ev_note text -> [section "Submitted note" text]
      | Ev_collaboration {ev_reference;ev_content;ev_sha256} ->
        [section "Submitted collaboration source" (ev_reference ^ "\nSHA-256: " ^ ev_sha256);section "Captured source content" ev_content]
      | Ev_artifact {ev_reference;ev_content;ev_bytes;ev_truncated} ->
        [section "Submitted text artifact" (Printf.sprintf "%s\n%d bytes · %s" ev_reference ev_bytes
          (if ev_truncated then "captured excerpt; artifact was truncated" else "captured content"));section "Captured artifact content" ev_content]
      | Ev_artifact_unreadable {ev_u_reference;ev_u_reason} ->
        [section "Submitted artifact unavailable" ((match ev_u_reference with None -> "Reference unavailable" | Some value -> value) ^ "\n" ^ ev_u_reason)]
      | Ev_binary {ev_b_reference;ev_b_bytes;ev_b_sha256;ev_b_format;ev_b_preview} ->
        [section "Submitted binary artifact" (Masc_tui_evidence_picture.caption_of_preview
          ~reference:ev_b_reference ~bytes:ev_b_bytes ~sha256:ev_b_sha256 ~format:ev_b_format ev_b_preview);
         section "Binary artifact identity" (ev_b_reference ^ "\nSHA-256: " ^ ev_b_sha256 ^
           "\nThis diagnostic reading shows metadata; image pixels are not drawn here.")]) items) in
  Result.map (fun evidence_sections -> {evidence_key={evidence_task=task_id;verification_id};evidence_value;
    evidence_sections=section "Exact verification submission" verification_id :: evidence_sections}) sections
let part_sections ~label ~pending view sections =
  let rows=match view with
    | Fetched.Absent -> [section (label ^ " not read") "No observation requested from an available original source."]
    | Loading -> [section (label ^ " requested") "Waiting for this original source."]
    | Failed error -> [section (label ^ " failed") (error_text error)]
    | Ready value -> sections value
    | Stale (value,error) -> sections value @ [section (label ^ " · last observation; refresh unavailable") (error_text error)] in
  if pending then section (label ^ " pending") "Any retained observation remains below." :: rows else rows
let task_pending t = Fetched.in_flight t.task_fetched
let task_sections t =
  let rows=match task_view t with
    | Fetched.Absent -> [section "Task not read" "Press o to inspect the original recorded Task."]
    | Loading -> [section "Task read requested" "Waiting for the exact original Task observation."]
    | Failed error -> [section "Task inspection failed" (error_text error)]
    | Ready value -> value.task_sections
    | Stale (value,error) -> value.task_sections @ [section "Last Task observation · refresh unavailable" (error_text error)] in
  if task_pending t then section "Task lookup pending" "Any retained original Task observation remains below." :: rows else rows
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
    (match t.displayed with
     | Creation -> [] | Task -> task_sections t
     | History -> part_sections ~label:"Stored history" ~pending:(Fetched.in_flight t.history_fetched)
         (history_view t) (fun value -> value.history_sections)
     | Evidence -> part_sections ~label:"Verification evidence" ~pending:(Fetched.in_flight t.evidence_fetched)
         (evidence_view t) (fun value -> value.evidence_sections)) @
    [section "Original body" t.origin.body;section "Original request" t.origin.request_id;
     section "Original workspace" (match t.origin.workspace with None -> "Not confirmed"
       | Some workspace -> Masc.Tui_decode.Canonical_path.to_string workspace.sid_base_path ^ "\n" ^ Masc.Tui_decode.Canonical_path.to_string workspace.sid_masc_root);
     section "Actions" "[: older retained request · ]: newer · r: read the displayed source again · o: original Task · h: fresh history · H: earlier history · v: next observed verification · b: creation facts · Esc: close. No creation, handoff or input recovery is performed here."] in
  {t with document=Reading.replace ~title:"Original Task · o Task · h/H history · v evidence · r refresh · Esc close" sections t.document}
let create origin = {origin;fetched=Fetched.initial;transport=Dispatch.Not_started;task_fetched=Fetched.initial;displayed=Creation;history_fetched=Fetched.initial;evidence_fetched=Fetched.initial;
  document=Reading.create_observation ~title:"Original Task creation" []}
let capture_transport transport t = refresh_document {t with transport}
let start t =
  let t={t with displayed=Creation;task_fetched=Fetched.suspend_with ~reason:Interrupted t.task_fetched;
    history_fetched=Fetched.suspend_with ~reason:Interrupted t.history_fetched;
    evidence_fetched=Fetched.suspend_with ~reason:Interrupted t.evidence_fetched} in
  match Fetched.refresh ~equal:String.equal t.fetched ~key:t.origin.request_id with
  | Fetched.Already_loading -> t,None
  | Started (fetched,request) -> refresh_document {t with fetched},Some request
let is_current t request = Fetched.is_current ~equal:String.equal t.fetched request
let complete t request result =
  if not (is_current t request) then t
  else refresh_document {t with fetched=Fetched.complete ~equal:String.equal t.fetched request result}
let suspend ~reason t = refresh_document {t with fetched=Fetched.suspend_with ~reason t.fetched;
  task_fetched=Fetched.suspend_with ~reason t.task_fetched;
  history_fetched=Fetched.suspend_with ~reason t.history_fetched;
  evidence_fetched=Fetched.suspend_with ~reason t.evidence_fetched}
let document t = t.document
let move ~count ~height movement t = {t with document=Reading.move ~count ~height movement t.document}

let displayed_source t = t.displayed
let task_request_id request = Fetched.request_id request.task_ticket
let task_request_key request = Fetched.request_key request.task_ticket
let start_task t = match recorded_task t,Fetched.current_request t.fetched with
  | Some task_id,Some creation_ticket ->
    (match Fetched.refresh ~equal:String.equal t.task_fetched ~key:task_id with
     | Fetched.Already_loading -> t,None
     | Started (task_fetched,task_ticket) ->
       refresh_document {t with task_fetched;displayed=Task;
         history_fetched=Fetched.suspend_with ~reason:Interrupted t.history_fetched;
         evidence_fetched=Fetched.suspend_with ~reason:Interrupted t.evidence_fetched},Some {task_ticket;creation_ticket})
  | (Some _ | None),(Some _ | None) -> t,None
let task_is_current t request =
  t.displayed=Task && Fetched.is_current ~equal:String.equal t.task_fetched request.task_ticket
  && (match Fetched.current_request t.fetched with
      | Some current -> Fetched.same_request ~equal:String.equal current request.creation_ticket
      | None -> false)
  && recorded_task t=Some (task_request_key request)
let complete_task t request result =
  if not (task_is_current t request) then t
  else
    let result=Result.bind result (fun snapshot ->
      if snapshot.task_id=task_request_key request then Ok snapshot
      else Error (Invalid_reply "Prepared Task snapshot belongs to another original Task")) in
    refresh_document {t with task_fetched=Fetched.complete ~equal:String.equal t.task_fetched request.task_ticket result}
let back_to_creation t = refresh_document {t with displayed=Creation;
  task_fetched=Fetched.suspend_with ~reason:Interrupted t.task_fetched;
  history_fetched=Fetched.suspend_with ~reason:Interrupted t.history_fetched;
  evidence_fetched=Fetched.suspend_with ~reason:Interrupted t.evidence_fetched}

let history_page_request request = request.history_page
let history_request_id request = Fetched.request_id request.history_ticket
let same_creation t ticket = match Fetched.current_request t.fetched with
  | Some current -> Fetched.same_request ~equal:String.equal current ticket
  | None -> false
let start_history ~earlier ~limit t = match recorded_task t,Fetched.current_request t.fetched with
  | Some task_id,Some history_creation ->
    let page=if earlier then
      match Fetched.value (history_view t) with None -> None
      | Some snapshot -> Masc.Tui_decode_task_inspection.history_earlier ~task_id ~limit snapshot.history_value
    else Some (Masc.Tui_decode_task_inspection.history_first ~task_id ~limit) in
    (match page with None -> t,None | Some history_page ->
      match Fetched.refresh ~equal:String.equal t.history_fetched ~key:task_id with
      | Fetched.Already_loading -> t,None
      | Started (history_fetched,history_ticket) ->
        refresh_document {t with history_fetched;displayed=History;
          task_fetched=Fetched.suspend_with ~reason:Interrupted t.task_fetched;
          evidence_fetched=Fetched.suspend_with ~reason:Interrupted t.evidence_fetched},
        Some {history_ticket;history_page;history_creation})
  | (Some _ | None),(Some _ | None) -> t,None
let history_is_current t request = t.displayed=History
  && Fetched.is_current ~equal:String.equal t.history_fetched request.history_ticket
  && same_creation t request.history_creation && recorded_task t=Some request.history_page.hr_task_id
let complete_history t request result =
  if not (history_is_current t request) then t else
    let result=Result.bind result (fun value ->
      if value.history_value.history_task_id=request.history_page.hr_task_id then Ok value
      else Error (Invalid_reply "Prepared history names another original Task")) in
    refresh_document {t with history_fetched=Fetched.complete ~equal:String.equal t.history_fetched request.history_ticket result}
let equal_evidence_key a b = a.evidence_task=b.evidence_task && a.verification_id=b.verification_id
let verification_candidates t =
  let current=match task_observation t with
    | Fetched.Ready (Masc.Tui_decode_task_inspection.In_backlog detail | In_archive detail) ->
      (match detail.task.task_status with
       | Masc_domain.AwaitingVerification {verification_id;_} -> [verification_id]
       | Todo | Claimed _ | InProgress _ | Done _ | Cancelled _ -> [])
    | Absent | Loading | Failed _ | Stale _ | Ready (Not_observed | Deletion_recorded _) -> [] in
  let history=match history_observation t with
    | Fetched.Ready history -> history.history_verifications
    | Absent | Loading | Failed _ | Stale _ -> [] in
  current @ List.filter (fun id -> not (List.mem id current)) history
let start_evidence ~next t = match recorded_task t,Fetched.current_request t.fetched with
  | Some evidence_task,Some evidence_creation ->
    let current=match Fetched.current_key t.evidence_fetched with
      | Some key when key.evidence_task=evidence_task -> Some key.verification_id
      | Some _ | None -> None in
    let ids=verification_candidates t in
    let chosen=if not next && t.displayed=Evidence then current else
      match current with
      | None -> List.nth_opt ids 0
      | Some current ->
        (match List.find_index (String.equal current) ids with
         | Some index -> (match List.nth_opt ids (index+1) with Some id -> Some id | None -> List.nth_opt ids 0)
         | None -> List.nth_opt ids 0) in
    (match chosen with
     | None -> refresh_document {t with displayed=Evidence},None
     | Some verification_id ->
       let key={evidence_task;verification_id} in
       match Fetched.refresh ~equal:equal_evidence_key t.evidence_fetched ~key with
       | Fetched.Already_loading -> t,None
       | Started (evidence_fetched,evidence_ticket) ->
         refresh_document {t with evidence_fetched;displayed=Evidence;
           task_fetched=Fetched.suspend_with ~reason:Interrupted t.task_fetched;
           history_fetched=Fetched.suspend_with ~reason:Interrupted t.history_fetched},
         Some {evidence_ticket;evidence_creation})
  | (Some _ | None),(Some _ | None) -> t,None
let evidence_task_id request = (Fetched.request_key request.evidence_ticket).evidence_task
let evidence_verification_id request = (Fetched.request_key request.evidence_ticket).verification_id
let evidence_request_id request = Fetched.request_id request.evidence_ticket
let evidence_is_current t request = t.displayed=Evidence
  && Fetched.is_current ~equal:equal_evidence_key t.evidence_fetched request.evidence_ticket
  && same_creation t request.evidence_creation && recorded_task t=Some (evidence_task_id request)
let complete_evidence t request result =
  if not (evidence_is_current t request) then t else
    let result=Result.bind result (fun value ->
      if equal_evidence_key value.evidence_key (Fetched.request_key request.evidence_ticket) then Ok value
      else Error (Invalid_reply "Prepared evidence names another original Task or submission")) in
    refresh_document {t with evidence_fetched=Fetched.complete ~equal:equal_evidence_key t.evidence_fetched request.evidence_ticket result}
