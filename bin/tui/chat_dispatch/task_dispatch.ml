(** Original task / verification inspection readers and /task creation
    dispatch. *)

module T = Masc_tui_types
module P = Masc_tui_async_protocol
module Admission = Masc_tui_transport.Workspace_admission

(* Exact original Task inspection is a read-only workspace observation. *)
let cancel_task_inspection_read (state : T.state) =
  Option.iter (fun reader ->
    let original=reader.T.tci_original in
    let pending=T.task_inspection_pending original in
    T.retire_task_inspection_owner original ~reason:Masc_tui_original_task_read.Interrupted;
    Option.iter (fun request -> Masc_tui_workspace_job.cancel_observation state ~key:request.T.tcr_job) pending)
    state.task_inspection_reader

let close_task_inspection_reader (state : T.state) =
  cancel_task_inspection_read state;
  T.close_task_inspection state ~reason:Masc_tui_original_task_read.Interrupted

let launch_task_creation_read (state : T.state) ~mailbox =
  cancel_task_inspection_read state;
  Option.iter (fun request ->
    let source=T.task_inspection_source request.T.tcr_original in
    match Masc_tui_original_task_read.origin source with
    | Masc_tui_original_task_read.Answered_ask _ -> ()
    | Masc_tui_original_task_read.Task_creation intent ->
    let identity=intent.Masc_tui_task_dispatch.workspace and authority=request.T.tcr_authority in
    let host=Admission.server_peer_host and port=state.port and session=state.mcp_session in
    let rpc_id=Printf.sprintf "%s:creation-read:%Ld" intent.Masc_tui_task_dispatch.request_id
      (match request.T.tcr_query with T.Creation_query ticket -> Masc_tui_fetched.request_id ticket
        | T.Original_task_query ticket -> Masc_tui_original_task_read.task_request_id ticket
        | T.Original_history_query ticket -> Masc_tui_original_task_read.history_request_id ticket
        | T.Original_evidence_query ticket -> Masc_tui_original_task_read.evidence_request_id ticket) in
    let kept_back refusal=Masc_tui_original_task_read.Kept_back
      (T.workspace_refusal_text ~ko:(state.ui_language = T.Lang_ko)
         ~request:Masc_tui_words.Kept_request.Task_creation_read refusal) in
    Admission.launch_result ~key:request.T.tcr_job ~observation:true state ~mailbox
      ~boundary_error:(fun detail -> Masc_tui_original_task_read.Read_failed detail)
      ~withdrawn:kept_back
      ~deliver:(fun result -> P.Task_msg (P.Task_creation_read_done (request,result))) (fun () ->
        let open Result.Syntax in
        (* The guard's refusal is the kept-back notice, never a failed read
           (RFC §2). *)
        let* arguments=Masc_tui_original_task_read.arguments source in
        let* ()=Admission.admit_request state ~mailbox ~authority ~identity ~host ~port ()
          |> Result.map_error kept_back in
        let* session_id=(match session with Some id -> Ok id
          | None -> Masc_tui_http.open_mcp_session ~host ~port ~client_version:Build_version.current)
          |> Result.map_error (fun detail -> Masc_tui_original_task_read.Read_failed detail) in
        let* ()=Admission.admit_request ~prior_contact:Masc_tui_server_lifecycle.Server_reached
          state ~mailbox ~authority ~identity ~host ~port () |> Result.map_error kept_back in
        let* answer=Masc_tui_http.call_mcp_tool ~host ~port ~session_id ~request_id:rpc_id
          ~tool:"masc_tasks" ~arguments
          |> Result.map_error (fun detail -> Masc_tui_original_task_read.Read_failed detail) in
        Masc_tui_response_decode.run ~name:"tui.task_creation.decode"
          (fun () -> Masc_tui_original_task_read.decode source answer)))
    (T.begin_task_creation_inspection state)

(* An original inspection read the workspace guard stopped: the reader holds
   text, so the kept-back notice is worded here, in the screen's language,
   and drawn alone (RFC §2). *)
let original_read_kept_back (state : T.state) refusal =
  Masc_tui_original_task_read.Kept_back
    (T.workspace_refusal_text ~ko:(state.ui_language = T.Lang_ko)
       ~request:Masc_tui_words.Kept_request.Original_task_read refusal)

let launch_original_task_read (state : T.state) ~mailbox =
  cancel_task_inspection_read state;
  Option.iter (fun request -> match request.T.tcr_query with
    | T.Creation_query _ | T.Original_history_query _ | T.Original_evidence_query _ -> ()
    | T.Original_task_query ticket ->
      let task_id=Masc_tui_original_task_read.task_request_key ticket in
      let host=Admission.server_peer_host and port=state.port in
      let read=Admission.capture_json_read state (fun () ->
        Masc_tui_http.fetch_original_task_inspection ~host ~port ~task_id) in
      Admission.launch_result ~key:request.T.tcr_job ~observation:true state ~mailbox
        ~boundary_error:(fun detail -> Masc_tui_original_task_read.Read_failed detail)
        ~withdrawn:(original_read_kept_back state)
        ~deliver:(fun result -> Admission.wrap_original (Masc_tui_original_results.Original_task_read_done (request,result))) (fun () ->
          match read () with
          | Error refusal -> Error (original_read_kept_back state refusal)
          | Ok (Error detail) -> Error (Masc_tui_original_task_read.Read_failed detail)
          | Ok (Ok result) -> result)) (T.begin_original_task_inspection state)

let launch_original_history_read (state : T.state) ~mailbox ~earlier ~limit =
  cancel_task_inspection_read state;
  Option.iter (fun request -> match request.T.tcr_query with
    | T.Creation_query _ | T.Original_task_query _ | T.Original_evidence_query _ -> ()
    | T.Original_history_query ticket ->
      let host=Admission.server_peer_host and port=state.port in
      let page=Masc_tui_original_task_read.history_page_request ticket in
      let read=Admission.capture_json_read state (fun () ->
        Masc_tui_http.fetch_original_task_history ~host ~port ~request:page) in
      Admission.launch_result ~key:request.T.tcr_job ~observation:true state ~mailbox
        ~boundary_error:(fun detail -> Masc_tui_original_task_read.Read_failed detail)
        ~withdrawn:(original_read_kept_back state)
        ~deliver:(fun result -> Admission.wrap_original (Masc_tui_original_results.Original_task_history_done (request,result))) (fun () ->
          match read () with
          | Error refusal -> Error (original_read_kept_back state refusal)
          | Ok result -> Result.map_error (fun detail -> Masc_tui_original_task_read.Read_failed detail) result))
    (T.begin_original_history_inspection state ~earlier ~limit)
let original_evidence_failure ~ko = function
  | T.Verification_evidence_read.Transport detail | T.Verification_evidence_read.Http_error detail | T.Verification_evidence_read.Launch_failure detail -> Masc_tui_original_task_read.Read_failed detail
  | T.Verification_evidence_read.Invalid_json detail | T.Verification_evidence_read.Invalid_payload detail -> Masc_tui_original_task_read.Invalid_reply detail
  | T.Verification_evidence_read.Workspace_unconfirmed detail -> Masc_tui_original_task_read.Workspace_unconfirmed detail
  | T.Verification_evidence_read.Interrupted _ -> Masc_tui_original_task_read.Interrupted
  | T.Verification_evidence_read.Kept_back refusal ->
      Masc_tui_original_task_read.Kept_back
        (T.workspace_refusal_text ~ko ~request:Masc_tui_words.Kept_request.Verification_evidence_read refusal)

let launch_original_evidence_read (state : T.state) ~mailbox ~next =
  cancel_task_inspection_read state;
  Option.iter (fun request -> match request.T.tcr_query with
    | T.Creation_query _ | T.Original_task_query _ | T.Original_history_query _ -> ()
    | T.Original_evidence_query ticket ->
      let host=Admission.server_peer_host and port=state.port in
      let task_id=Masc_tui_original_task_read.evidence_task_id ticket in
      let verification_id=Masc_tui_original_task_read.evidence_verification_id ticket in
      let read=Admission.capture_json_read state (fun () ->
        Masc_tui_http.fetch_original_verification_evidence ~host ~port ~task_id ~verification_id
        |> Result.map_error (original_evidence_failure ~ko:(state.ui_language = T.Lang_ko))
        |> fun result -> Result.bind result Fun.id) in
      Admission.launch_result ~key:request.T.tcr_job ~observation:true state ~mailbox
        ~boundary_error:(fun detail -> Masc_tui_original_task_read.Read_failed detail)
        ~withdrawn:(original_read_kept_back state)
        ~deliver:(fun result -> Admission.wrap_original (Masc_tui_original_results.Original_task_evidence_done (request,result))) (fun () ->
          match read () with
          | Error refusal -> Error (original_read_kept_back state refusal)
          | Ok result -> result)) (T.begin_original_evidence_inspection state ~next)

(* /task in the composer or the chat pane: create the task first, then hand
   the keeper the operator's words with the task id in front. Creation runs
   on the original switch; only its request-owned receipt mutates UI state. The MCP session
   is the one the observer feed keeps; without one, this call opens one and
   the observer reuses it. *)
let launch_task_dispatch (state : T.state) ~mailbox ~keeper_name ~title ~body ~original =
  let authority = state.workspace_authority in
  let identity = state.server_identity in
  let workspace = match state.workspace_identity, identity with
    | T.Workspace_identity_match, Some expected -> Some expected
    | (T.Workspace_identity_unread | T.Workspace_identity_match_unconfirmed _ | T.Workspace_identity_mismatch _), _
    | T.Workspace_identity_match, None -> None in
  let intent : Masc_tui_task_dispatch.intent = {
    Masc_tui_task_dispatch.request_id="tui-task-" ^ Random_id.uuid_v7 ();
    keeper=keeper_name;title;body;original;workspace} in
  let request = T.begin_task_dispatch state intent in
  (* The guard's refusal is the kept-back notice, drawn alone when the
     completion is handled (RFC §2). *)
  let kept_back refusal =
    T.workspace_refusal_text ~ko:(state.ui_language = T.Lang_ko) ~request:Masc_tui_words.Kept_request.Task_creation refusal in
  if not (T.keeper_available_for_new_message state keeper_name) then
    Masc_tui_task_dispatch.reject request.T.tdr_dispatch "waiting for the current Keeper roster"
  else match workspace with
  | None -> Masc_tui_task_dispatch.keep_back request.T.tdr_dispatch (kept_back T.Workspace_identity_not_confirmed)
  | Some _ ->
    let host = Admission.server_peer_host and port = state.port and session = state.mcp_session in
    (* Preparing and sending run on the dispatch's own fiber, each in the
       scope of the workspace captured here. *)
    let in_scope ~withdrawn request =
      Admission.in_request_scope ~kind:Masc_tui_workspace_precondition.Operation
        state ~mailbox ~authority ~identity ~host ~port ~withdrawn request in
    Masc_tui_task_dispatch.launch request.T.tdr_dispatch
      ~prepare:(fun () ->
        in_scope ~withdrawn:(fun refusal ->
          Error (Masc_tui_task_dispatch.Preparation_kept_back (kept_back refusal))) @@ fun () ->
        let open Result.Syntax in
        let admit ?prior_contact () =
          Admission.admit_request ?prior_contact state ~mailbox ~authority ~identity ~host ~port ()
          |> Result.map_error (fun refusal -> Masc_tui_task_dispatch.Preparation_kept_back (kept_back refusal)) in
        let* () = admit () in
        let* session_id = match session with
          | Some session_id -> Ok session_id
          | None -> Masc_tui_http.open_mcp_session ~host ~port ~client_version:Build_version.current
              |> Result.map_error (fun detail -> Masc_tui_task_dispatch.Preparation_failed detail) in
        let* () = admit ~prior_contact:Masc_tui_server_lifecycle.Server_reached () in
        Ok session_id)
      ~send:(fun ~session_id ~request_id ~arguments ->
        in_scope ~withdrawn:(fun (_ : T.workspace_refusal) -> Error Admission.workspace_scope_refused_english) @@ fun () ->
        Masc_tui_http.call_mcp_tool ~host ~port ~session_id ~request_id ~tool:"masc_add_task" ~arguments)
