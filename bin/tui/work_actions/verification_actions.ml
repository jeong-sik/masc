module T = Masc_tui_types
module P = Masc_tui_async_protocol
module Tui_decode = Masc.Tui_decode
module Verification_evidence_read = Masc_tui_types.Verification_evidence_read

let ensure_img_cache_dir () =
  let dir = Filename.concat (Filename.get_temp_dir_name ()) "masc_img_cache" in
  (try Unix.mkdir dir 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  dir

(* An evidence image that is not a PNG, made into one. Kitty takes PNG
   (f=100) and drops anything else without saying so, so the converters the
   link preview already uses (sips, ImageMagick, ffmpeg) run first. They block
   on child processes: only the evidence loader's systhread calls this. An
   artifact's author chooses the bytes, so each converter runs with no
   terminal to read and is killed at the deadline: a decompression bomb costs
   that image, not the evidence pane. A converter that cannot start is that
   image's failure, not the bundle's. *)
let image_process_deadline_seconds = 10.

let convert_evidence_image bytes =
  match
    Masc_tui_image_cache.prepare_payload
      ~run:(Masc_tui_image_cache.run_bounded ~deadline_seconds:image_process_deadline_seconds)
      ~cache_dir:(ensure_img_cache_dir ()) bytes
  with
  | result -> result
  | exception ((Unix.Unix_error _ | Sys_error _) as failure) ->
      Error (Printexc.to_string failure)

let verification_evidence_outcome = function
  | Ok _ -> "received"
  | Error (Verification_evidence_read.Transport _) -> "transport_failed"
  | Error (Verification_evidence_read.Http_error _) -> "http_refused"
  | Error (Verification_evidence_read.Invalid_json _) -> "invalid_json"
  | Error (Verification_evidence_read.Invalid_payload _) -> "invalid_payload"
  | Error (Verification_evidence_read.Launch_failure _) -> "boundary_failed"
  | Error (Verification_evidence_read.Workspace_unconfirmed _) -> "workspace_unconfirmed"
  | Error (Verification_evidence_read.Interrupted _) -> "interrupted"
  | Error (Verification_evidence_read.Kept_back _) -> "kept_back"

let log_verification_evidence_read (request : T.verification_evidence_request) ~phase ~outcome =
  Log.Transport.routine_lazy (fun () ->
    let key = Masc_tui_fetched.request_key request.T.ver_ticket in
    let field get = match request.T.ver_workspace with None -> `Null | Some identity -> `String (Tui_decode.Canonical_path.to_string (get identity)) in
    "tui_verification_evidence=" ^ Yojson.Safe.to_string (`Assoc [
      "pid",`Int (Unix.getpid ());
      "task_id",`String key.T.vek_task_id;"verification_id",`String key.T.vek_request_id;
      "request",`Intlit (Int64.to_string (Masc_tui_fetched.request_id request.T.ver_ticket));
      "base_path",field (fun identity -> identity.Tui_decode.sid_base_path);
      "masc_root",field (fun identity -> identity.Tui_decode.sid_masc_root);
      "observed_ns",`Intlit (Int64.to_string (Mtime_clock.elapsed_ns ()));
      "phase",`String phase;"outcome",`String outcome]))

(* Original detail request and Task own this observation. A later visit to the
   same Task creates a fresh ticket; cancellation and reply admission are distinct. *)
let cancel_verification_evidence_load (state : T.state) ~reason =
  Option.iter (fun request ->
    Masc_tui_workspace_job.cancel_observation state ~key:request.T.ver_job)
    state.T.verification_evidence_request;
  T.retire_verification_evidence_read state ~reason

let launch_verification_evidence_load (state : T.state) ~mailbox (key : T.verification_evidence_key) =
  if T.server_authority_ready state then begin
    Option.iter (fun request ->
      Masc_tui_workspace_job.cancel_observation state ~key:request.T.ver_job)
      state.T.verification_evidence_request;
    match T.begin_verification_evidence_read state key with
    | None -> ()
    | Some request ->
      log_verification_evidence_read request ~phase:"requested" ~outcome:"pending";
      let host = Masc_tui_transport.Workspace_admission.server_peer_host and port = state.T.port in
      let read = Masc_tui_transport.Workspace_admission.capture_json_read state (fun () ->
        Masc_tui_http.fetch_verification_evidence ~host ~port ~task_id:key.T.vek_task_id
          ~verification_id:key.T.vek_request_id
          |> Result.map (fun evidence ->
            Eio_guard.run_in_systhread ~label:"tui-evidence-pictures" (fun () ->
              Masc_tui_evidence_picture.prepare
                ~layout:Masc_tui_evidence_picture.One_at_a_time
                ~display:(Masc_tui_portrait_view.current_display ())
                ~convert:convert_evidence_image evidence))) in
      Masc_tui_transport.Workspace_admission.launch_result ~key:request.T.ver_job ~observation:true state ~mailbox
        ~on_not_run:(fun () -> log_verification_evidence_read request ~phase:"not_run" ~outcome:"not_started")
        ~observe_job:(fun event -> log_verification_evidence_read request
          ~phase:(match event with Masc_tui_workspace_job.Cancellation_requested -> "cancellation_requested"
            | Masc_tui_workspace_job.Registration_released -> "registration_released") ~outcome:"observed")
        ~boundary_error:(fun detail -> Verification_evidence_read.Launch_failure detail)
        ~withdrawn:(fun refusal -> Verification_evidence_read.Kept_back refusal)
        ~deliver:(fun result ->
          log_verification_evidence_read request ~phase:"delivery_formed" ~outcome:(verification_evidence_outcome result);
          P.Verification_msg (P.Verification_evidence_loaded (request,result)))
        (fun () ->
          log_verification_evidence_read request ~phase:"caller_entered" ~outcome:"pending";
          try
            let result = match read () with
              | Ok result -> result
              | Error refusal -> Error (Verification_evidence_read.Kept_back refusal) in
            log_verification_evidence_read request ~phase:"caller_observed" ~outcome:(verification_evidence_outcome result);
            result
          with Eio.Cancel.Cancelled _ as exn ->
            let backtrace = Printexc.get_raw_backtrace () in
            log_verification_evidence_read request ~phase:"caller_interrupted" ~outcome:"interrupted";
            Printexc.raise_with_backtrace exn backtrace)
  end

(* Send the operator's verdict through the verification route. Same
   fiber-and-mailbox shape as the other writes; whether the task still awaits
   verification is the route's store rules to say, so the TUI does not
   pre-guess from the row it rendered a moment ago. *)
let start_verification_verdict (state : T.state) ~mailbox ~(task_id : string)
    ~(verification_id : string) ~(verdict : [ `Approve | `Reject of string ]) =
  if Option.is_some state.T.verification_verdict_inflight then ()
  else begin
  let authority = state.T.workspace_authority in
  let identity = state.T.server_identity in
  state.T.verification_verdict_error <- None;
  state.T.verification_verdict_inflight <- Some (task_id, verification_id);
  let verb = match verdict with `Approve -> "approving" | `Reject _ -> "rejecting" in
  Masc_tui_loader.report_action state "system" (Printf.sprintf "%s %s" verb task_id);
  let host = Masc_tui_transport.Workspace_admission.server_peer_host in
  let port = state.T.port in
  let deliver result = P.Verification_msg (P.Verification_verdict_done result) in
  let cancelled =
    deliver (Error (T.Request_failed "Verification verdict cancelled"))
  in
  let on_not_run () =
    state.T.verification_verdict_inflight <- None;
    state.T.verification_verdict_error <-
      Some (T.Request_failed "Verification verdict could not start")
  in
  Masc_tui_transport.Workspace_admission.launch_result ~operation:true ~cancelled ~on_not_run state ~mailbox
    ~boundary_error:(fun detail -> T.Request_failed detail)
    ~withdrawn:(fun refusal -> T.Request_withdrawn refusal)
    ~deliver
    (fun () ->
      match Masc_tui_transport.Workspace_admission.admit_request state ~mailbox ~authority ~identity ~host ~port () with
      | Error refusal -> Error (T.Request_withdrawn refusal)
      | Ok () ->
          (match
             Masc_tui_http.post_verification_verdict ~host ~port ~task_id
               ~verification_id ~verdict
           with
           | Error err -> Error err
           | Ok json -> Tui_decode.verification_verdict_outcome json)
          |> Result.map_error (fun detail -> T.Request_failed detail))
  end

(* The row under the Verification cursor, if the list has one. *)
let verification_cursor_row (state : T.state) =
  let requests =
    match state.T.verification with
    | None -> []
    | Some s -> s.Tui_decode.vs_requests
  in
  match state.T.verification_detail_request_id with
  | Some request_id ->
      List.find_opt
        (fun row ->
           String.equal row.Tui_decode.vr_request_id request_id)
        requests
  | None -> List.nth_opt requests state.T.verification_cursor

let selected_verification_evidence (state : T.state) =
  match (if Option.is_some state.T.verification_detail_request_id then verification_cursor_row state else None) with
  | None -> None
  | Some row ->
    let key = {T.vek_request_id=row.Tui_decode.vr_request_id;vek_task_id=row.Tui_decode.vr_task_id} in
    match Masc_tui_fetched.view_for ~equal:T.equal_verification_evidence_key state.T.verification_evidence ~key with
    | Masc_tui_fetched.Ready (Masc_tui_evidence_picture.Items items) ->
      let index = max 0 (min (List.length items - 1) state.T.verification_evidence_cursor) in
      Option.map (fun item -> key, index, List.length items, item) (List.nth_opt items index)
    | Masc_tui_fetched.Absent | Masc_tui_fetched.Loading | Masc_tui_fetched.Failed _
    | Masc_tui_fetched.Stale _ | Masc_tui_fetched.Ready (Masc_tui_evidence_picture.Access_unavailable _) -> None

let step_verification_evidence (state : T.state) delta =
  match selected_verification_evidence state with
  | None ->
      Masc_tui_loader.report_action state "system"
        (T.ui_text state
           ~ko:"증거 내용을 먼저 불러와야 합니다. r로 다시 읽을 수 있습니다."
           ~en:"Load evidence content first. Press r to reload.")
  | Some (_, index, count, _) ->
    state.T.verification_evidence_cursor <- max 0 (min (count - 1) (index + delta));
    state.T.verification_evidence_index_open <- false;
    state.T.verification_detail_scroll <- 0

let export_verification_evidence (state : T.state) ~mailbox ~open_file =
  match selected_verification_evidence state, Eio_context.get_env_opt () with
  | None, _ ->
      Masc_tui_loader.report_action state "error"
        (T.ui_text state ~ko:"현재 제출의 증거를 먼저 불러오세요." ~en:"Load evidence for the current submission first.")
  | Some _, None ->
      Masc_tui_loader.report_action state "error"
        (T.ui_text state ~ko:"이 기기의 파일 시스템을 사용할 수 없습니다." ~en:"File system access is unavailable on this device.")
  | Some (key, index, _, _), Some env ->
    let request = {T.vex_key=key;vex_index=index;vex_authority=state.T.workspace_authority;
      vex_reading=state.T.workspace_read_authority;vex_progress=Atomic.make Masc_tui_evidence_file.Not_started} in
    let host=Masc_tui_transport.Workspace_admission.server_peer_host and port=state.T.port in
    let read = Masc_tui_transport.Workspace_admission.capture_json_read state (fun () ->
      Masc_tui_http.fetch_verification_evidence_file ~host ~port ~task_id:key.T.vek_task_id
        ~verification_id:key.T.vek_request_id ~index) in
    let current () =
      if request.T.vex_authority = state.T.workspace_authority
         && request.T.vex_reading == state.T.workspace_read_authority
      then Ok () else Error "Workspace changed before the evidence file operation" in
    Masc_tui_loader.report_action state "system"
      (if state.T.ui_language = T.Lang_ko then "선택한 증거 사본을 내려받는 중"
       else "Downloading selected evidence copy");
    Masc_tui_transport.Workspace_admission.launch_guarded_request ~operation:true state ~mailbox
      ~boundary_error:(fun detail -> T.Request_failed detail)
      ~withdrawn:(fun refusal -> T.Request_withdrawn refusal)
      ~cancelled:(P.Verification_msg (P.Verification_evidence_exported (request, Error (T.Request_failed "File operation interrupted; a local copy or opened viewer may exist. Inspect before retrying."))))
      ~deliver:(fun result -> P.Verification_msg (P.Verification_evidence_exported (request,result)))
      (fun () ->
        match read () with
        | Error refusal -> Error (T.Request_withdrawn refusal)
        | Ok file ->
        Result.map_error (fun detail -> T.Request_failed detail) @@
        let open Result.Syntax in
        let* file = file in
        let open_file = if not open_file then None else Some (fun path ->
          Eio_guard.run_in_systhread ~label:"tui-evidence-open" (fun () ->
            Masc_tui_browser.open_url (Uri.to_string (Uri.make ~scheme:"file" ~path ())))
          |> Result.map (fun _ -> ())) in
        Masc_tui_evidence_file.export ~fs:env#fs
          ~registry_root:(Common.masc_dir_from_base_path ~base_path:state.T.local_base_path)
          ~directory:(Filename.get_temp_dir_name ())
          ~progress:request.T.vex_progress ~admitted:current ~open_file file)

(* The approve key on the row under the cursor. Two presses, like the cancel
   and vote keys: the first names the task and request, the same press again
   sends the verdict. A reload can replace a request for the same task; a
   press on that new request re-arms instead of approving it. Reject is not
   armed -- its $EDITOR reason form is the confirmation. *)
let handle_verification_approve_key (state : T.state) ~mailbox =
  match verification_cursor_row state with
  | None -> ()
  | Some row -> (
      let task_id = row.Tui_decode.vr_task_id in
      let request_id = row.Tui_decode.vr_request_id in
      match state.T.verification_verdict_armed with
      | Some (armed_task, armed_request)
        when String.equal armed_task task_id
             && String.equal armed_request request_id ->
          state.T.verification_verdict_armed <- None;
          start_verification_verdict state ~mailbox ~task_id
            ~verification_id:request_id ~verdict:`Approve
      | Some _ | None ->
          state.T.verification_verdict_armed <- Some (task_id, request_id);
          state.T.verification_verdict_error <- None;
          Masc_tui_loader.report_action state "system"
            (Printf.sprintf "press a again to approve %s [%s]" task_id request_id))
