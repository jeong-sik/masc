module Fetched = Masc_tui_fetched
module Reading = Masc_tui_detail_reading
module Dispatch = Masc_tui_task_dispatch
type receipt = Unobserved of int
  | Recorded of { task_id : string; backlog_version : int }
  | Ambiguous of { task_ids : string list; backlog_version : int }
type error = Workspace_unconfirmed of string | Read_failed of string
  | Invalid_reply of string | Interrupted
type request = string Fetched.request
type ask_origin = {
  ao_keeper : string; ao_ask_id : string; ao_task_id : string;
  ao_answered_at : float; ao_stimulus_id : string;
  ao_workspace : Masc.Tui_decode.server_identity;
}
type origin = Task_creation of Dispatch.intent | Answered_ask of ask_origin
type creation = { intent : Dispatch.intent; fetched : (string,receipt,error) Fetched.source;
  transport : Dispatch.progress }
type root = Creation_root of creation | Ask_root of ask_origin * unit ref
type binding = Creation_binding of request | Ask_binding of unit ref
type task_request = { task_ticket : string Fetched.request; task_binding : binding }
type task_snapshot = {
  task_id : string;
  task_observation : Masc.Tui_decode_task_inspection.observation;
  task_sections : Reading.section list;
}
type source = Origin | Task | History | Evidence
type history_request = {
  history_ticket : string Fetched.request;
  history_page : Masc.Tui_decode_task_inspection.history_request;
  history_binding : binding;
}
type history_snapshot = {
  history_value : Masc.Tui_decode_task_inspection.history;
  history_sections : Reading.section list;
}
type evidence_key = { evidence_task : string; verification_id : string }
type evidence_source = From_task | From_history
type selection_observation =
  | Selection_observed
  | Selection_refreshing
  | Selection_retained of error
  | Selection_retrying of error
type evidence_basis = {
  eb_source : evidence_source;
  eb_observation : selection_observation;
}
type evidence_anchor = { ea_key : evidence_key; ea_basis : evidence_basis }
type evidence_request = { evidence_ticket : evidence_anchor Fetched.request; evidence_binding : binding }
type evidence_snapshot = {
  evidence_key : evidence_key;
  evidence_value : Masc.Tui_decode.verification_evidence;
  evidence_sections : Reading.section list;
}
type t = {
  root : root;
  task_fetched : (string,task_snapshot,error) Fetched.source;
  displayed : source;
  history_fetched : (string,history_snapshot,error) Fetched.source;
  evidence_fetched : (evidence_anchor,evidence_snapshot,error) Fetched.source;
  document : Reading.t;
}
let origin t = match t.root with
  | Creation_root creation -> Task_creation creation.intent
  | Ask_root (ask,_) -> Answered_ask ask
let workspace t = match origin t with
  | Task_creation intent -> intent.workspace | Answered_ask ask -> Some ask.ao_workspace
let arguments t = match origin t with
  | Answered_ask _ -> Error (Invalid_reply "An answered Ask has no creation lookup.")
  | Task_creation intent -> match intent.workspace with
    | None -> Error (Workspace_unconfirmed "The original creation has no confirmed workspace.")
    | Some expected -> Ok ["creation_request_id",`String intent.request_id;
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
  else match origin t with
  | Answered_ask _ -> invalid "An answered Ask has no creation receipt"
  | Task_creation intent -> match intent.workspace with
  | None -> Error (Workspace_unconfirmed "The original workspace is unavailable.")
  | Some expected ->
    (try
      let json = Yojson.Safe.from_string answer.text in
      let* ok = field "ok" json in
      let* () = match ok with `Bool true -> Ok () | _ -> invalid "Creation receipt is not successful" in
      let* raw = field "creation_request_id" json in
      let* request_id = string raw in
      let* () = if String.equal request_id intent.request_id then Ok ()
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
let observation t = match t.root with
  | Ask_root _ -> None
  | Creation_root creation -> Some (Fetched.view_for ~equal:String.equal creation.fetched ~key:creation.intent.request_id)
let pending t = match t.root with Ask_root _ -> false | Creation_root creation -> Fetched.in_flight creation.fetched
let section heading body = {Reading.heading;body}
let error_text = function
  | Workspace_unconfirmed detail -> "Workspace unconfirmed: " ^ detail
  | Read_failed detail -> "Read failed: " ^ detail
  | Invalid_reply detail -> "Reply refused: " ^ detail
  | Interrupted -> "Inspection interrupted; the original operation was not repeated."
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

let recorded_task t = match t.root with
  | Ask_root (ask,_) -> Some ask.ao_task_id
  | Creation_root _ -> match observation t with
    | Some (Fetched.Ready (Recorded {task_id;_})) when not (pending t) -> Some task_id
    | Some _ | None -> None
let task_binding t = match t.root,recorded_task t with
  | Ask_root (_,anchor),Some task_id -> Some (task_id,Ask_binding anchor)
  | Creation_root creation,Some task_id -> Option.map (fun ticket -> task_id,Creation_binding ticket)
      (Fetched.current_request creation.fetched)
  | (Ask_root _ | Creation_root _),None -> None
let same_binding t = function
  | Ask_binding anchor -> (match t.root with Ask_root (_,current) -> current==anchor | Creation_root _ -> false)
  | Creation_binding ticket -> (match t.root with
    | Ask_root _ -> false
    | Creation_root creation -> match Fetched.current_request creation.fetched with
      | Some current -> Fetched.same_request ~equal:String.equal current ticket | None -> false)
let task_view t = match recorded_task t with
  | None -> Fetched.Absent
  | Some key -> Fetched.view_for ~equal:String.equal t.task_fetched ~key
let history_view t = match recorded_task t with
  | None -> Fetched.Absent
  | Some key -> Fetched.view_for ~equal:String.equal t.history_fetched ~key
let evidence_view t = match recorded_task t,Fetched.current t.evidence_fetched with
  | Some task_id,Some (key,value) when key.ea_key.evidence_task=task_id -> value
  | (Some _ | None),(Some _ | None) -> Fetched.Absent
let evidence_basis t = match recorded_task t,Fetched.current_key t.evidence_fetched with
  | Some task_id,Some anchor when anchor.ea_key.evidence_task=task_id -> Some anchor.ea_basis
  | (Some _ | None),(Some _ | None) -> None
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
    | Fetched.Absent -> [section "Task not read" "Press o to inspect the original linked Task."]
    | Loading -> [section "Task read requested" "Waiting for the exact original Task observation."]
    | Failed error -> [section "Task inspection failed" (error_text error)]
    | Ready value -> value.task_sections
    | Stale (value,error) -> value.task_sections @ [section "Last Task observation · refresh unavailable" (error_text error)] in
  if task_pending t then section "Task lookup pending" "Any retained original Task observation remains below." :: rows else rows
let evidence_basis_sections t = match evidence_basis t with
  | None -> [section "Verification selection"
      "No submission ID has been selected from this original Task or its observed history. This is not absence of stored evidence."]
  | Some basis ->
    [section "Submission selection source" (match basis.eb_source with
       | From_task -> "Original Task observation" | From_history -> "Original stored history observation");
     section "Selection-time observation" (match basis.eb_observation with
       | Selection_observed -> "A completed source observation was available at selection; this does not assert current Task status."
       | Selection_refreshing -> "The previous source observation was available; its refresh was pending at selection."
       | Selection_retained error -> "The previous source observation was retained after an unavailable refresh at selection.\n" ^ error_text error
       | Selection_retrying error -> "The retained source observation had a retry pending at selection. Its prior failure remains:\n" ^ error_text error)]
let refresh_document t =
  let facts,tail,neighbors=match t.root with
    | Creation_root creation ->
      let read=match observation t with
        | Some Fetched.Absent | None -> [section "Not read" "No creation fact has been requested."]
        | Some Loading -> [section "Read requested" "Waiting for the exact original creation lookup."]
        | Some (Failed error) -> [section "Inspection failed" (error_text error)]
        | Some (Ready receipt) -> receipt_sections receipt
        | Some (Stale (receipt,error)) -> receipt_sections receipt @ [section "Last reading · refresh unavailable" (error_text error)] in
      let read=if pending t then section "Lookup pending" "A read is pending; any retained fact and failure remain below." :: read else read in
      [section "Original Task" creation.intent.title;section "Original Keeper" creation.intent.keeper;
       section "Original creation transport" (transport_text creation.transport)] @ read,
      [section "Original body" creation.intent.body;section "Original request" creation.intent.request_id],
      "[: older retained request · ]: newer · "
    | Ask_root (ask,_) ->
      [section "Original answered Ask" ask.ao_ask_id;section "Original Keeper" ask.ao_keeper;
       section "Canonical Task link" ask.ao_task_id;
       section "Recorded answer identity" (Printf.sprintf "%.17g\nStimulus: %s" ask.ao_answered_at ask.ao_stimulus_id);
       section "Origin boundary" "The canonical answered Ask records this Task link. This is not a creation receipt or current Task status."],[],"" in
  let sections=facts @ (match t.displayed with
    | Origin -> [] | Task -> task_sections t
    | History -> part_sections ~label:"Stored history" ~pending:(Fetched.in_flight t.history_fetched)
        (history_view t) (fun value -> value.history_sections)
    | Evidence -> evidence_basis_sections t @ part_sections ~label:"Verification evidence" ~pending:(Fetched.in_flight t.evidence_fetched)
        (evidence_view t) (fun value -> value.evidence_sections)) @ tail @
    [section "Original workspace" (match workspace t with None -> "Not confirmed"
       | Some workspace -> Masc.Tui_decode.Canonical_path.to_string workspace.sid_base_path ^ "\n" ^ Masc.Tui_decode.Canonical_path.to_string workspace.sid_masc_root);
     section "Actions" (neighbors ^ "r: refresh displayed source · o: original Task · h: fresh history · H: earlier history · v: next observed verification · b: origin facts · Esc: close. No answer, creation, handoff or input recovery is performed here.")] in
  {t with document=Reading.replace ~title:"Original Task · o Task · h/H history · v evidence · r refresh · Esc close" sections t.document}
let initial root = {root;task_fetched=Fetched.initial;displayed=Origin;history_fetched=Fetched.initial;evidence_fetched=Fetched.initial;
  document=Reading.create_observation ~title:"Original Task" []}
let create intent = initial (Creation_root {intent;fetched=Fetched.initial;transport=Dispatch.Not_started})
let create_ask ~keeper ~ask_id ~workspace ~identity ~task =
  let module Ask = Masc.Tui_decode_asks in
  let task_id=match task with Ask.Ask_task_observed value -> Some value.akt_task_id
    | Ask_task_missing id | Ask_task_unavailable id -> Some id | Ask_task_unlinked -> None in
  match task_id with
  | Some ao_task_id when String.trim keeper<>"" && String.trim ask_id<>"" && String.trim ao_task_id<>"" ->
    let ask={ao_keeper=keeper;ao_ask_id=ask_id;ao_task_id;ao_workspace=workspace;
      ao_answered_at=identity.Ask.afi_answered_at;ao_stimulus_id=identity.afi_stimulus_id} in
    Ok (refresh_document (initial (Ask_root (ask,ref ()))))
  | Some _ | None -> invalid "No exact canonical answered Ask Task link is available"
let capture_transport transport t = match t.root with
  | Ask_root _ -> t | Creation_root creation -> refresh_document {t with root=Creation_root {creation with transport}}
let start t = match t.root with
  | Ask_root _ -> t,None
  | Creation_root creation ->
    let t={t with displayed=Origin;task_fetched=Fetched.suspend_with ~reason:Interrupted t.task_fetched;
      history_fetched=Fetched.suspend_with ~reason:Interrupted t.history_fetched;
      evidence_fetched=Fetched.suspend_with ~reason:Interrupted t.evidence_fetched} in
    match Fetched.refresh ~equal:String.equal creation.fetched ~key:creation.intent.request_id with
    | Fetched.Already_loading -> t,None
    | Started (fetched,request) -> refresh_document {t with root=Creation_root {creation with fetched}},Some request
let is_current t request = match t.root with Ask_root _ -> false
  | Creation_root creation -> Fetched.is_current ~equal:String.equal creation.fetched request
let complete t request result = match t.root with
  | Creation_root creation when is_current t request ->
    refresh_document {t with root=Creation_root {creation with fetched=Fetched.complete ~equal:String.equal creation.fetched request result}}
  | Ask_root _ | Creation_root _ -> t
let suspend ~reason t =
  let root=match t.root with Ask_root _ -> t.root | Creation_root creation ->
    Creation_root {creation with fetched=Fetched.suspend_with ~reason creation.fetched} in
  refresh_document {t with root;task_fetched=Fetched.suspend_with ~reason t.task_fetched;
    history_fetched=Fetched.suspend_with ~reason t.history_fetched;
    evidence_fetched=Fetched.suspend_with ~reason t.evidence_fetched}
let document t = t.document
let move ~count ~height movement t = {t with document=Reading.move ~count ~height movement t.document}

let displayed_source t = t.displayed
let task_request_id request = Fetched.request_id request.task_ticket
let task_request_key request = Fetched.request_key request.task_ticket
let start_task t = match task_binding t with
  | Some (task_id,task_binding) ->
    (match Fetched.refresh ~equal:String.equal t.task_fetched ~key:task_id with
     | Fetched.Already_loading -> t,None
     | Started (task_fetched,task_ticket) ->
       refresh_document {t with task_fetched;displayed=Task;
         history_fetched=Fetched.suspend_with ~reason:Interrupted t.history_fetched;
         evidence_fetched=Fetched.suspend_with ~reason:Interrupted t.evidence_fetched},Some {task_ticket;task_binding})
  | None -> t,None
let task_is_current t request =
  t.displayed=Task && Fetched.is_current ~equal:String.equal t.task_fetched request.task_ticket
  && same_binding t request.task_binding
  && recorded_task t=Some (task_request_key request)
let complete_task t request result =
  if not (task_is_current t request) then t
  else
    let result=Result.bind result (fun snapshot ->
      if snapshot.task_id=task_request_key request then Ok snapshot
      else Error (Invalid_reply "Prepared Task snapshot belongs to another original Task")) in
    refresh_document {t with task_fetched=Fetched.complete ~equal:String.equal t.task_fetched request.task_ticket result}
let back_to_origin t = refresh_document {t with displayed=Origin;
  task_fetched=Fetched.suspend_with ~reason:Interrupted t.task_fetched;
  history_fetched=Fetched.suspend_with ~reason:Interrupted t.history_fetched;
  evidence_fetched=Fetched.suspend_with ~reason:Interrupted t.evidence_fetched}

let history_page_request request = request.history_page
let history_request_id request = Fetched.request_id request.history_ticket
let start_history ~earlier ~limit t = match task_binding t with
  | Some (task_id,history_binding) ->
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
        Some {history_ticket;history_page;history_binding})
  | None -> t,None
let history_is_current t request = t.displayed=History
  && Fetched.is_current ~equal:String.equal t.history_fetched request.history_ticket
  && same_binding t request.history_binding && recorded_task t=Some request.history_page.hr_task_id
let complete_history t request result =
  if not (history_is_current t request) then t else
    let result=Result.bind result (fun value ->
      if value.history_value.history_task_id=request.history_page.hr_task_id then Ok value
      else Error (Invalid_reply "Prepared history names another original Task")) in
    refresh_document {t with history_fetched=Fetched.complete ~equal:String.equal t.history_fetched request.history_ticket result}
let equal_evidence_key a b = a.evidence_task=b.evidence_task && a.verification_id=b.verification_id
let equal_evidence_anchor a b = equal_evidence_key a.ea_key b.ea_key
let selection_value source ~pending = function
  | Fetched.Ready value -> Some (value,{eb_source=source;
      eb_observation=(if pending then Selection_refreshing else Selection_observed)})
  | Stale (value,error) -> Some (value,{eb_source=source;
      eb_observation=(if pending then Selection_retrying error else Selection_retained error)})
  | Absent | Loading | Failed _ -> None
let verification_candidates t =
  let current=match selection_value From_task ~pending:(Fetched.in_flight t.task_fetched)
      (task_observation t) with
    | Some ((Masc.Tui_decode_task_inspection.In_backlog detail | In_archive detail),basis) ->
      (match detail.task.task_status with
       | Masc_domain.AwaitingVerification {verification_id;_} -> [verification_id,basis]
       | Todo | Claimed _ | InProgress _ | Done _ | Cancelled _ -> [])
    | Some ((Not_observed | Deletion_recorded _),_) | None -> [] in
  let history=match selection_value From_history ~pending:(Fetched.in_flight t.history_fetched)
      (history_observation t) with
    | Some (history,basis) -> List.map (fun id -> id,basis) history.history_verifications
    | None -> [] in
  current @ List.filter (fun (id,_) -> not (List.exists (fun (known,_) -> String.equal id known) current)) history
let start_evidence ~next t = match task_binding t with
  | Some (evidence_task,evidence_binding) ->
    let current=match Fetched.current_key t.evidence_fetched with
      | Some anchor when anchor.ea_key.evidence_task=evidence_task -> Some anchor
      | Some _ | None -> None in
    let ids=verification_candidates t in
    let candidate row=Option.map (fun (verification_id,ea_basis) ->
      {ea_key={evidence_task;verification_id};ea_basis}) row in
    let chosen=if not next && t.displayed=Evidence then current else
      match current with
      | None -> candidate (List.nth_opt ids 0)
      | Some anchor ->
        (match List.find_index (fun (id,_) -> String.equal anchor.ea_key.verification_id id) ids with
         | Some index -> candidate (match List.nth_opt ids (index+1) with Some row -> Some row | None -> List.nth_opt ids 0)
         | None -> candidate (List.nth_opt ids 0)) in
    (match chosen with
     | None -> refresh_document {t with displayed=Evidence},None
     | Some key ->
       match Fetched.refresh ~equal:equal_evidence_anchor t.evidence_fetched ~key with
       | Fetched.Already_loading -> t,None
       | Started (evidence_fetched,evidence_ticket) ->
         refresh_document {t with evidence_fetched;displayed=Evidence;
           task_fetched=Fetched.suspend_with ~reason:Interrupted t.task_fetched;
           history_fetched=Fetched.suspend_with ~reason:Interrupted t.history_fetched},
         Some {evidence_ticket;evidence_binding})
  | None -> t,None
let evidence_task_id request = (Fetched.request_key request.evidence_ticket).ea_key.evidence_task
let evidence_verification_id request = (Fetched.request_key request.evidence_ticket).ea_key.verification_id
let evidence_request_id request = Fetched.request_id request.evidence_ticket
let evidence_is_current t request = t.displayed=Evidence
  && Fetched.is_current ~equal:equal_evidence_anchor t.evidence_fetched request.evidence_ticket
  && same_binding t request.evidence_binding && recorded_task t=Some (evidence_task_id request)
let complete_evidence t request result =
  if not (evidence_is_current t request) then t else
    let result=Result.bind result (fun value ->
      if equal_evidence_key value.evidence_key (Fetched.request_key request.evidence_ticket).ea_key then Ok value
      else Error (Invalid_reply "Prepared evidence names another original Task or submission")) in
    refresh_document {t with evidence_fetched=Fetched.complete ~equal:equal_evidence_anchor t.evidence_fetched request.evidence_ticket result}
