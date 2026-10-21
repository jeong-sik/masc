(** Actual filed evidence plus the server's workspace admission, typed envelope
    decoder and original TUI request state. Responses are controlled protocol
    frames; no HTTP server, TUI process, converter or screen is exercised. *)
open Alcotest
open Masc_tui_types
module F = Masc_tui_fetched
module Read = Masc_tui_workspace_read
module Store = Workspace_verification_store
module Operator = Workspace_verification_operator_evidence
module Picture = Masc_tui_evidence_picture
module Failure = Verification_evidence_read
module Results = Masc_tui_workspace_result
module Protocol = Masc_tui_async_protocol

let bytes = Base64.decode_exn
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jk1cAAAAASUVORK5CYII="
let sha256 = Digestif.SHA256.(to_hex (digest_string bytes))
let task_id = "task-original"
let key verification_id = {vek_request_id=verification_id;vek_task_id=task_id}
let with_root f =
  let root = Filename.temp_dir "tui-evidence-resource-" "" in
  let rec remove path = match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR -> Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
    | _ -> Unix.unlink path in
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    Unix.mkdir (Filename.concat root ".masc") 0o700;
    f root)
let identity base : Masc.Tui_decode.server_identity =
  {sid_version="0.24.0";sid_binary_commit="evidence-resource";sid_binary_commit_age_s=None;
   sid_base_path=Masc.Tui_decode.Canonical_path.of_path (Unix.realpath base);sid_masc_root=Masc.Tui_decode.Canonical_path.of_path (Unix.realpath (Filename.concat base ".masc"));
   sid_executable_in_worktree=None;sid_state_ready=Some true;sid_uptime=None;
   sid_sse_clients=None;sid_gc=None;sid_scheduler=None}
let packet base verification_id =
  let body = Store.persist_binary_body ~base_path:base ~request_id:verification_id ~index:0 bytes in
  check bool "original image body was actually filed" true (Option.is_some body);
  let request : Store.request_header = {id=verification_id;task_id;worker="original-producer";created_at=1.} in
  let item = Store.Evidence_artifact_binary {reference="artifact:" ^ verification_id ^ ".png";
      bytes=String.length bytes;sha256;format="png";body} in
  `Assoc ["ok",`Bool true;"result",`Assoc ["task_id",`String task_id;
    "verification_id",`String verification_id;"evidence",Operator.access_to_yojson ~base_path:base
      (Store.Evidence_available {request;items=[item]})]]
let frame ?(receipts=[Masc.Workspace.read_precondition_admission_header]) packet : Masc_http_client.response =
  {status=200;headers=receipts;body=Yojson.Safe.to_string packet}
let bound expected read = Read.with_binding ~host:"127.0.0.1" ~port:8935 ~expected
    ~proof:Read.Request_precondition read
let read config expected key response = bound expected (fun () ->
  let send ~path =
    let request = Httpun.Request.create `GET path in
    match Server_auth.validate_read_workspace_precondition ~config request with
    | Ok Server_auth.Workspace_read_matched -> Ok response
    | Ok Workspace_read_unbound
    | Error (Masc.Workspace.Invalid_workspace_precondition | Workspace_precondition_failed) ->
      Ok {Masc_http_client.status=409;headers=[];body="foreign workspace refused"} in
  match Read.read_response ~host:"127.0.0.1" ~port:8935
      ~path:("/api/v1/verification/evidence?task_id=" ^ key.vek_task_id) ~send with
  | Error (Read.Transport_failed reason) -> Error (Failure.Transport reason)
  | Error (Workspace_refused reason) -> Error (Failure.Workspace_unconfirmed reason)
  | Ok response when response.status <> 200 -> Error (Failure.Http_error response.body)
  | Ok response ->
    let json = Yojson.Safe.from_string response.body in
    Masc.Tui_decode.decode_verification_evidence_for_request
      ~task_id:key.vek_task_id ~verification_id:key.vek_request_id json
    |> Result.map_error (fun detail -> Failure.Invalid_payload detail)
    |> Result.map (fun decoded ->
      (match decoded with
       | Masc.Tui_decode.Evidence_items items ->
         (match items with
          | [item] -> (match item with
            | Ev_binary {ev_b_preview;_} -> (match ev_b_preview with
              | Preview_image {ev_data;_} ->
                check string "filed original image bytes survive admission and decode" bytes ev_data
              | Preview_withheld _ | Preview_defective _ -> fail "original filed preview lost")
            | Ev_collaboration _ | Ev_note _ | Ev_artifact _ | Ev_artifact_unreadable _ ->
              fail "original filed image changed kind")
          | [] | _ :: _ -> fail "original filed image membership changed")
       | Evidence_access_unavailable _ -> fail "original filed image lost");
      Picture.prepare ~display:Masc_tui_portrait_view.No_picture
        ~convert:(fun _ -> fail "no-picture evidence cannot launch a converter") decoded))
let start state key = begin_verification_evidence_read state key
  |> function Some request -> request | None -> fail "explicit original read did not start"
let view state key = F.view_for ~equal:equal_verification_evidence_key state.verification_evidence ~key
let expect_original verification_id evidence = match evidence with
  | Picture.Items items -> (match items with
    | [item] -> (match item with
      | Binary_item {reference;sha256=actual;_} ->
        check string "the exact original evidence reference remains" ("artifact:" ^ verification_id ^ ".png") reference;
        check string "the original content identity remains" sha256 actual
      | Text_item _ -> fail "original filed image changed kind")
    | [] | _ :: _ -> fail "original filed evidence membership changed")
  | Access_unavailable _ -> fail "original filed evidence did not remain usable"
let state base =
  let state = create_state ~workspace:"evidence-resource" ~local_base_path:base ~port:8935 ~refresh_interval:2. () in
  state.server_identity <- Some (identity base);
  state

let test_original_request_survives_new_submission_and_late_reply () = with_root @@ fun base ->
  let config = Masc.Workspace.default_config base and expected = identity base in
  let state = state base in
  let original = key "verification-original" and newer = key "verification-new-submission" in
  let original_wire = packet base original.vek_request_id in
  let first = start state original in
  check bool "first actual evidence result admitted" true
    (complete_verification_evidence_read state first (read config expected original (frame original_wire)));
  let refresh = start state original in
  let newer_wire = packet base newer.vek_request_id in
  let changed = read config expected original (frame newer_wire) in
  (match changed with Error (Failure.Invalid_payload _) -> ()
   | Ok _ | Error (Transport _ | Http_error _ | Invalid_json _ | Launch_failure _
       | Workspace_unconfirmed _ | Interrupted _) -> fail "new submission borrowed old detail");
  ignore (complete_verification_evidence_read state refresh changed);
  (match view state original with
   | F.Stale (evidence,error) -> (match error with
      | Failure.Invalid_payload _ -> expect_original original.vek_request_id evidence
      | Transport _ | Http_error _ | Invalid_json _ | Launch_failure _ | Workspace_unconfirmed _ | Interrupted _ ->
        fail "refresh changed its actual refusal")
   | Absent | Loading | Ready _ | Failed _ -> fail "failed refresh discarded original evidence");
  let retired = start state newer in
  let late = read config expected newer (frame newer_wire) in
  let current = start state newer in
  check bool "late original visit cannot finish the reopened same Task detail" false
    (complete_verification_evidence_read state retired late);
  check bool "replacement read retains settlement ownership" true (F.in_flight state.verification_evidence);
  check bool "reopened original request admits its own real evidence" true
    (complete_verification_evidence_read state current (read config expected newer (frame newer_wire)));
  (match view state newer with Ready evidence -> expect_original newer.vek_request_id evidence
   | Absent | Loading | Stale _ | Failed _ -> fail "new original result unavailable");
  let waiting = start state newer in
  suspend_verification_evidence_read state;
  check bool "suspended original response cannot acquire reply authority" false
    (complete_verification_evidence_read state waiting late);
  (match view state newer with
   | Stale (evidence,error) -> (match error with
      | Failure.Workspace_unconfirmed _ -> expect_original newer.vek_request_id evidence
      | Transport _ | Http_error _ | Invalid_json _ | Invalid_payload _ | Launch_failure _ | Interrupted _ ->
        fail "suspension changed its actual refusal")
   | Absent | Loading | Ready _ | Failed _ -> fail "suspension lost original evidence or hid its refusal")

let test_workspace_and_receipt_cannot_borrow_filed_evidence () = with_root @@ fun base_a -> with_root @@ fun base_b ->
  let config_a = Masc.Workspace.default_config base_a and config_b = Masc.Workspace.default_config base_b in
  let expected_a = identity base_a and expected_b = identity base_b in
  let key = key "same-verification-coordinates" in
  let wire_a = packet base_a key.vek_request_id and wire_b = packet base_b key.vek_request_id in
  let state = state base_a in
  let first = start state key in
  ignore (complete_verification_evidence_read state first (read config_a expected_a key (frame wire_a)));
  let original = match view state key with Ready value -> value | Absent | Loading | Stale _ | Failed _ -> fail "original evidence missing" in
  let foreign = read config_b expected_a key (frame wire_b) in
  (match foreign with Error (Failure.Http_error _) -> ()
   | Ok _ | Error (Transport _ | Invalid_json _ | Invalid_payload _ | Launch_failure _
       | Workspace_unconfirmed _ | Interrupted _) -> fail "foreign root supplied original evidence");
  List.iter (fun receipts ->
    let refresh = start state key in
    let refused = read config_a expected_a key (frame ~receipts wire_a) in
    (match refused with Error (Failure.Workspace_unconfirmed _) -> ()
     | Ok _ | Error (Transport _ | Http_error _ | Invalid_json _ | Invalid_payload _
         | Launch_failure _ | Interrupted _) -> fail "unattested evidence became current");
    ignore (complete_verification_evidence_read state refresh refused);
    match view state key with
    | Stale (value,error) -> (match error with
      | Failure.Workspace_unconfirmed _ -> check bool "unattested read retains exact original evidence" true (value==original)
      | Transport _ | Http_error _ | Invalid_json _ | Invalid_payload _ | Launch_failure _ | Interrupted _ ->
        fail "receipt failure changed its actual refusal")
    | Absent | Loading | Ready _ | Failed _ -> fail "receipt failure erased or replaced original evidence")
    [[];[Masc.Workspace.read_precondition_admission_header;Masc.Workspace.read_precondition_admission_header]];
  let old = start state key in
  state.workspace_authority <- Workspace_authority 1;
  state.workspace_read_authority <- ref ();
  state.server_identity <- Some expected_b;
  state.verification_evidence <- F.clear state.verification_evidence;
  state.verification_evidence_request <- None;
  let current = start state key in
  check bool "same coordinates on successor root cannot admit old response" false
    (complete_verification_evidence_read state old (Ok original));
  check bool "successor receives its own admitted resource" true
    (complete_verification_evidence_read state current (read config_b expected_b key (frame wire_b)));
  (match view state key with Ready evidence -> expect_original key.vek_request_id evidence
   | Absent | Loading | Stale _ | Failed _ -> fail "successor original evidence missing")

(* The production launcher and drain policy meet actual filed evidence. The
   full stream is a fixture resource boundary, not a new product queue limit. *)
let take_publication results shared round =
  Protocol.Delivery_round.take round ~can_take:(fun () -> true)
    ~queued:(fun () -> Eio.Stream.length shared)
    ~take_shared:(fun () -> Eio.Stream.take_nonblocking shared)
    ~collect_owned:(fun () -> Results.take_ready results |> List.map
      (fun (ready : Protocol.async_msg Results.ready) ->
        {Protocol.ready_at_ns=ready.ready_at_ns;message=ready.message}))
let original_reply state = function
  | Protocol.Workspace_scoped (authority,reading,(Verification_evidence_loaded (request,result) as message)) ->
      if Protocol.workspace_message_admitted state ~authority ~reading message
      then complete_verification_evidence_read state request result else false
  | _ -> fail "original evidence envelope lost"
let launch_evidence ?observe_job state results request perform =
  let envelope = Protocol.capture_workspace_message state in
  Results.launch ~key:request.ver_job ~observation:true ?observe_job state ~results
    ~boundary_error:(fun detail -> Failure.Launch_failure detail)
    ~deliver:(fun result -> envelope (Protocol.Verification_evidence_loaded (request,result))) perform
let released () =
  let promise,resolver = Eio.Promise.create () in
  let observe = function
    | Masc_tui_workspace_job.Registration_released -> Eio.Promise.resolve resolver ()
    | Cancellation_requested -> () in
  promise,observe
let require_publication = function Some ready -> ready | None -> fail "original result was not retained"

let test_launch_failure_with_full_notifications () = with_root @@ fun base ->
  let snapshot = Eio_context.snapshot_state () in
  Fun.protect ~finally:(fun () -> Eio_context.restore_state snapshot) @@ fun () ->
  Eio_context.For_testing.clear_root_switch ();
  check bool "fixture has no dispatch switch" true (Option.is_none (Eio_context.get_switch_opt ()));
  let state = state base and expected = identity base and config = Masc.Workspace.default_config base in
  let key = key "verification-no-switch" in
  let wire = packet base key.vek_request_id in
  ignore (complete_verification_evidence_read state (start state key) (read config expected key (frame wire)));
  let original = match view state key with Ready value -> value | _ -> fail "filed original evidence missing" in
  let request = start state key and results = Results.create () in
  Fun.protect ~finally:(fun () -> Results.close results) @@ fun () ->
  let shared = Eio.Stream.create 1 in
  let notification = {Protocol.ready_at_ns=0L;message=Protocol.Harness_label_done (Ok "unrelated-original")} in
  Eio.Stream.add shared notification;
  let forbidden = Filename.concat base "unstarted-resource-effect" in
  launch_evidence state results request (fun () ->
    Fs_compat.save_file forbidden "must not run without its switch";
    read config expected key (frame wire));
  check bool "no-switch failure does not execute the resource effect" false (Sys.file_exists forbidden);
  let shared_ready,round = take_publication results shared Protocol.Delivery_round.empty in
  check bool "existing notification remains the original stream value" true
    (require_publication shared_ready == notification);
  let ready,_ = take_publication results shared round in
  check bool "original launch failure settles its own request" true
    (original_reply state (require_publication ready).message);
  (match view state key with
   | F.Stale (evidence,Failure.Launch_failure _) ->
       check bool "launch failure preserves the original filed evidence" true (evidence == original)
   | _ -> fail "launch failure became Loading, empty success or replacement evidence");
  expect_original key.vek_request_id original

let test_worker_cleanup_read_retirement_and_session_close () = with_root @@ fun base ->
  let state = state base and expected = identity base and config = Masc.Workspace.default_config base in
  let key = key "verification-cleanup" in
  let wire = packet base key.vek_request_id in
  let results = Results.create () and shared = Eio.Stream.create 1 in
  Fun.protect ~finally:(fun () -> Results.close results) @@ fun () ->
  Eio.Switch.run @@ fun sw -> Eio_context.with_turn_switch sw @@ fun () ->
  let first = start state key and finished,observe = released () in
  launch_evidence ~observe_job:observe state results first (fun () -> read config expected key (frame wire));
  Eio.Promise.await finished;
  let ready,_ = take_publication results shared Protocol.Delivery_round.empty in
  check bool "worker registration release does not discard original ready evidence" true
    (original_reply state (require_publication ready).message);
  (match view state key with Ready evidence -> expect_original key.vek_request_id evidence
   | _ -> fail "released reader lost its filed evidence");
  let old = start state key and finished,observe = released () in
  launch_evidence ~observe_job:observe state results old (fun () -> read config expected key (frame wire));
  Eio.Promise.await finished;
  state.workspace_read_authority <- ref ();
  suspend_verification_evidence_read state;
  let current = start state key in
  let stale,_ = take_publication results shared Protocol.Delivery_round.empty in
  check bool "old read cannot borrow the reconfirmed read epoch or reopened request" false
    (original_reply state (require_publication stale).message);
  check bool "reopened original source retains settlement ownership" true (F.in_flight state.verification_evidence);
  let finished,observe = released () in
  launch_evidence ~observe_job:observe state results current (fun () -> read config expected key (frame wire));
  Eio.Promise.await finished;
  let ready,_ = take_publication results shared Protocol.Delivery_round.empty in
  check bool "late cleanup cannot remove the successor resource result" true
    (original_reply state (require_publication ready).message);
  let cancelled = start state key and entered,enter = Eio.Promise.create () in
  let gate,_release = Eio.Promise.create () and finished,observe = released () in
  launch_evidence ~observe_job:observe state results cancelled (fun () ->
    Eio.Promise.resolve enter ();
    Eio.Promise.await gate;
    read config expected key (frame wire));
  Eio.Promise.await entered;
  Masc_tui_workspace_job.cancel_observation state ~key:cancelled.ver_job;
  Eio.Promise.await finished;
  suspend_verification_evidence_read state;
  check bool "cancelled read cannot synthesize a terminal reply" true (Results.take_ready results = []);
  let late = start state key and entered,enter = Eio.Promise.create () in
  let gate,release = Eio.Promise.create () and finished,observe = released () in
  launch_evidence ~observe_job:observe state results late (fun () ->
    Eio.Promise.resolve enter ();
    Eio.Promise.await gate;
    read config expected key (frame wire));
  Eio.Promise.await entered;
  Results.close results;
  Eio.Promise.resolve release ();
  Eio.Promise.await finished;
  check bool "ended session does not retain a late resource reply" true (Results.take_ready results = []);
  let successor = Results.create () in
  Fun.protect ~finally:(fun () -> Results.close successor) @@ fun () ->
  let request = start state key and finished,observe = released () in
  launch_evidence ~observe_job:observe state successor request (fun () -> read config expected key (frame wire));
  Eio.Promise.await finished;
  let ready,_ = take_publication successor shared Protocol.Delivery_round.empty in
  check bool "successor session receives only its own resource reply" true
    (original_reply state (require_publication ready).message);
  (match view state key with Ready evidence -> expect_original key.vek_request_id evidence
   | _ -> fail "successor session lost original filed evidence")

let () = Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Fun.protect ~finally:Fs_compat.clear_fs (fun () ->
    run "verification evidence original resource reads"
      ["resources",[test_case "original submission and reopened detail retain exact evidence" `Quick
        test_original_request_survives_new_submission_and_late_reply;
        test_case "root replacement and admission receipts cannot borrow evidence" `Quick
        test_workspace_and_receipt_cannot_borrow_filed_evidence;
        test_case "launch failure settles filed evidence despite full notifications" `Quick
          test_launch_failure_with_full_notifications;
        test_case "worker cleanup, read retirement and session close preserve evidence ownership" `Quick
          test_worker_cleanup_read_retirement_and_session_close]])
