type intent = {
  request_id : string; keeper : string; title : string; body : string;
  original : string; workspace : Masc.Tui_decode.server_identity option;
}
type outcome =
  | Created of { task_id : string; workspace : Masc.Tui_decode.server_identity }
  | Not_sent of string | Server_error of string | Unconfirmed of string
type completion = { ready_at_ns : int64; outcome : outcome }
type progress = Not_started | Reserved | Preparing | Sending | Completed of completion
type t = { intent : intent; progress : progress Atomic.t }
let create intent = { intent; progress = Atomic.make Not_started }
let intent t = t.intent
let progress t = Atomic.get t.progress
let complete t outcome =
  let completion = { ready_at_ns = Mtime_clock.elapsed_ns (); outcome } in
  let rec commit () =
    let before = progress t in
    match before with
    | Completed _ -> ()
    | Not_started | Reserved | Preparing | Sending ->
        if not (Atomic.compare_and_set t.progress before (Completed completion)) then commit () in
  commit ()
let reject t detail =
  let completion = { ready_at_ns = Mtime_clock.elapsed_ns (); outcome = Not_sent detail } in
  ignore (Atomic.compare_and_set t.progress Not_started (Completed completion))
let boundary_failure t detail = match progress t with
  | Not_started | Reserved | Preparing -> complete t (Not_sent detail)
  | Sending -> complete t (Unconfirmed detail)
  | Completed _ -> ()
let launch t ~prepare ~send =
  if Atomic.compare_and_set t.progress Not_started Reserved then begin
    let run () =
      if Atomic.compare_and_set t.progress Reserved Preparing then begin
      try
        match t.intent.workspace with
        | None -> complete t (Not_sent "workspace identity is not verified")
        | Some workspace ->
          (match prepare () with
           | Error detail -> complete t (Not_sent detail)
           | Ok session_id ->
             let arguments =
               ("expected_workspace", `Assoc
                 ["base_path", `String (Masc.Tui_decode.Canonical_path.to_string workspace.sid_base_path);
                  "masc_root", `String (Masc.Tui_decode.Canonical_path.to_string workspace.sid_masc_root)])
               :: ("title", `String t.intent.title)
               :: (if String.trim t.intent.body = "" then []
                   else ["description", `String t.intent.body]) in
             Atomic.set t.progress Sending;
             let outcome = match send ~session_id ~request_id:t.intent.request_id ~arguments with
               | Error detail -> Unconfirmed detail
               | Ok answer when answer.Masc_tui_mcp.is_error -> Server_error answer.text
               | Ok answer ->
                 (match Masc_tui_mcp.task_id_of_add_task answer.text with
                  | Error detail -> Unconfirmed detail
                  | Ok task_id -> Created {task_id;workspace}) in
             complete t outcome)
      with
      | Eio.Cancel.Cancelled _ as exn ->
          boundary_failure t "Task creation was interrupted.";
          raise exn
      | exn -> boundary_failure t (Printexc.to_string exn)
      end
    in
    match Eio_context.get_switch_opt () with
    | None -> boundary_failure t "Eio switch is unavailable"
    | Some sw ->
      (match (Eio.Switch.check sw; Eio.Fiber.fork_daemon ~sw (fun () -> run (); `Stop_daemon)) with
       | () -> ()
       | exception (Eio.Cancel.Cancelled _ as exn) ->
           boundary_failure t "Task creation launch was interrupted."; raise exn
       | exception exn -> boundary_failure t (Printexc.to_string exn))
  end
