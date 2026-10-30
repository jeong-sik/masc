open Alcotest

module E = Masc.Keeper_chat_events
module L = Masc.Keeper_chat_event_log
module R = Masc.Keeper_secret_redaction
module Projection = Server_keeper_chat_agui_projection
module Replay = Server_keeper_chat_replay
module Autonomous = Masc.Keeper_autonomous_stream

let private_secret = "orchid river seventy nine"
let private_path = "/private/example/.masc/keepers/alpha/events"
let private_detail = private_secret ^ " at " ^ private_path

let assert_private_absent wire =
  List.iter
    (fun value -> check bool "private diagnostic stays internal" false
       (Astring.String.is_infix ~affix:value wire))
    [private_secret; private_path]
;;

let started = E.Run_started {run_id="keeper-operation-run-public"; thread_id="keeper:public"}

let entries ending : L.journaled_event list =
  [{seq=0;ts=10.;event=started}; {seq=1;ts=11.;event=ending}]
;;

let test_public_terminal_is_safe_and_matches_replay () =
  let ending = E.Event_error {message=private_detail} in
  let state,_ = Projection.project ~timestamp:10. ~redact_text:Fun.id Projection.initial started in
  let _,live = Projection.project ~timestamp:11. ~redact_text:Fun.id state ending in
  let live = Option.get live in
  let replayed = Replay.replay ~redact_text:Fun.id ~since_seq:(L.After_seq 0) (entries ending) in
  (match replayed with
   | [1,event] -> check string "live and replay share exact safe bytes"
       (Ag_ui.event_to_sse ~id:1 live) (Ag_ui.event_to_sse ~id:1 event)
   | _ -> fail "replay lost the actual terminal");
  check (option string) "stable public code" (Some E.public_error_code) live.Ag_ui.code;
  check (option string) "fixed public message" (Some E.public_error_message) live.Ag_ui.message;
  check (option string) "actual run correlation" (Some "keeper-operation-run-public") live.Ag_ui.run_id;
  assert_private_absent (Ag_ui.event_to_sse live);
  check bool "public projection never mutates the private event" true
    (E.redact_content ~redact_text:Fun.id ending = E.Event_error {message=private_detail})
;;

let rec remove_tree path =
  match Unix.lstat path with
  | {Unix.st_kind=Unix.S_DIR;_} ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT,_,_) -> ()
;;

let with_base f =
  let base = Filename.temp_file "keeper-public-errors-" "" in
  Unix.unlink base;
  Unix.mkdir base 0o700;
  Fun.protect ~finally:(fun () -> remove_tree base) (fun () -> f base)
;;

let read_journal path =
  match L.read_journal_path_result path with
  | Ok entries -> entries
  | Error L.Journal_missing -> fail "actual journal was not written"
  | Error (Journal_unreadable detail | Journal_corrupt detail) -> fail detail
  | Error (Journal_unsupported_version version) -> fail (L.version_mismatch_to_string version)
;;

let test_public_journal_copy_redacts_captured_exact_secret () =
  with_base @@ fun base_path ->
  let secret_file = Filename.concat base_path "captured-secret.txt" in
  let channel = open_out_bin secret_file in
  output_string channel (private_secret ^ "\n");
  close_out channel;
  let redaction = R.snapshot_with_additional_secret_files
      ~redact_identity_scalars:true ~additional_secret_files:[secret_file]
      ~base_path ~keeper_name:"public" in
  let redact_text = R.redact_text redaction in
  check string "non-prefix exact secret is actually captured" "[REDACTED]" (redact_text private_secret);
  let journal = L.open_journal ~base_dir:base_path ~keeper_name:"public" ~operation_id:"public-operation" () in
  let bus = E.create ~on_publish:(fun ~seq ~ts event ->
      L.append journal ~seq ~ts (E.public_content ~redact_text event)) () in
  List.iter (E.publish bus)
    [started; E.Text_delta {text="answer " ^ private_secret;response=Unobserved_scope None};
     E.Event_error {message=private_detail}];
  let path = L.journal_path ~base_dir:base_path ~keeper_name:"public" ~operation_id:"public-operation" in
  let persisted = read_journal path in
  check int "actual journal retains all event facts" 3 (List.length persisted);
  List.iter (fun row -> assert_private_absent (Yojson.Safe.to_string (L.journaled_event_to_json row))) persisted;
  let first = E.subscribe bus in
  let second = E.subscribe bus in
  let third = E.subscribe bus in
  (match first,second,third with
   | E.Next _,E.Next _,E.Next (E.Event_error {message}) ->
     check string "internal bus still carries its original diagnostic" private_detail message
   | _ -> fail "internal event order or diagnostic changed");
  let frames = Replay.replay ~redact_text ~since_seq:L.Whole_turn persisted in
  check int "safe journal remains replayable" 3 (List.length frames);
  List.iter (fun (seq,event) -> assert_private_absent (Ag_ui.event_to_sse ~id:seq event)) frames
;;

let test_legacy_empty_error_has_safe_public_terminal () =
  with_base @@ fun base_path ->
  let journal = L.open_journal ~base_dir:base_path ~keeper_name:"public" ~operation_id:"legacy-operation" () in
  List.iter (fun (row:L.journaled_event) -> L.append journal ~seq:row.seq ~ts:row.ts row.event)
    (entries (E.Event_error {message=""}));
  let persisted = read_journal (L.journal_path ~base_dir:base_path ~keeper_name:"public" ~operation_id:"legacy-operation") in
  (match Replay.replay ~redact_text:Fun.id ~since_seq:(L.After_seq 0) persisted with
   | [1,event] ->
     check bool "actual terminal fact remains RUN_ERROR" true (event.Ag_ui.event_type=Ag_ui.Run_error);
     check (option string) "empty private diagnostic maps to safe message"
       (Some E.public_error_message) event.message
   | _ -> fail "empty diagnostic lost its valid terminal fact");
  check bool "malformed journal schema remains rejected" true
    (Result.is_error (L.journaled_event_of_json (`Assoc ["v",`Int 2;"seq",`Int 0])))
;;

let test_public_protocol_error_keeps_kind_without_diagnostic () =
  let error : E.stream_protocol_error =
    {kind=Media_persist_failed;quarantined_occurrence=None;index=Some 3;
     tool_call_id=Some "call-public";event_type=Some private_path;
     reason=Some private_detail;raw_bytes=Some 64} in
  let original = E.Agent_core_stream_protocol_error error in
  let public = E.public_content ~redact_text:Fun.id original in
  (match public with
   | E.Agent_core_stream_protocol_error safe ->
     check bool "closed protocol kind remains authoritative" true (safe.kind=error.kind);
     check (option string) "actual tool correlation remains" error.tool_call_id safe.tool_call_id;
     check (option string) "public protocol message is fixed"
       (Some E.public_protocol_error_message) safe.reason;
     check (option string) "provider diagnostic event text stays internal" None safe.event_type
   | _ -> fail "public projection changed the event kind");
  let _,projected = Projection.project ~timestamp:11. ~redact_text:Fun.id Projection.initial original in
  assert_private_absent (Ag_ui.event_to_sse (Option.get projected));
  check bool "internal typed protocol diagnostic remains exact" true
    (E.redact_content ~redact_text:Fun.id original = original)
;;

let rec ensure_dir path =
  if not (Sys.file_exists path) then begin
    ensure_dir (Filename.dirname path);
    Unix.mkdir path 0o700
  end
;;

let write_secret path value =
  ensure_dir (Filename.dirname path);
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out channel)
    (fun () -> output_string channel (value ^ "\n"))
;;

let turn_error_logs since =
  Log.Ring.recent ~since_seq:since ()
  |> List.filter (fun (entry : Log.Ring.entry) ->
      Astring.String.is_infix ~affix:"keeper_turn_error incident_id=" entry.message)
;;

let test_autonomous_failure_redacts_log_with_captured_snapshot () =
  Eio_main.run @@ fun _ ->
  with_base @@ fun base_path ->
  let keeper_name = "autonomous-public" in
  let turn_ref = Ids.Turn_ref.make ~trace_id:"public-autonomous-trace" ~absolute_turn:3 in
  let secret_file = R.ssh_remote_token_file ~base_path ~keeper_name in
  write_secret secret_file private_secret;
  let stream = Autonomous.create ~base_path ~keeper_name ~turn_ref in
  (* Rotation after admission cannot remove a secret from this turn's snapshot. *)
  write_secret secret_file "replacement credential thirty seven";
  let before = (Log.Ring.bounds ()).total - 1 in
  Autonomous.finish stream (Autonomous.Failed ("provider rejected " ^ private_secret));
  let logs = turn_error_logs before in
  check int "one real autonomous diagnostic" 1 (List.length logs);
  let diagnostic = (List.hd logs).Log.Ring.message in
  check bool "captured exact secret stays out of operator log" false
    (Astring.String.is_infix ~affix:private_secret diagnostic);
  check bool "useful diagnostic survives" true
    (Astring.String.is_infix ~affix:"provider rejected [REDACTED]" diagnostic);
  check bool "actual turn correlates the diagnostic" true
    (Astring.String.is_infix ~affix:(Ids.Turn_ref.to_string turn_ref) diagnostic);
  let persisted = read_journal
      (L.turn_journal_path ~base_dir:base_path ~keeper_name ~turn_ref) in
  check bool "actual journal retains the safe terminal" true
    (List.exists (fun (row : L.journaled_event) -> match row.event with
      | E.Event_error {message} -> String.equal message E.public_error_message
      | _ -> false) persisted);
  List.iter (fun row -> assert_private_absent
    (Yojson.Safe.to_string (L.journaled_event_to_json row))) persisted;
  check bool "finished autonomous identity released" true
    (Option.is_none (Autonomous.current ~base_path ~keeper_name));
  Autonomous.finish stream (Autonomous.Failed "late duplicate");
  check int "closed producer cannot log a second failure" 1
    (List.length (turn_error_logs before))
;;

let test_autonomous_cancel_has_no_failure_diagnostic () =
  Eio_main.run @@ fun _ ->
  with_base @@ fun base_path ->
  let keeper_name = "autonomous-cancel" in
  let turn_ref = Ids.Turn_ref.make ~trace_id:"public-autonomous-cancel" ~absolute_turn:4 in
  let stream = Autonomous.create ~base_path ~keeper_name ~turn_ref in
  let before = (Log.Ring.bounds ()).total - 1 in
  Autonomous.finish stream Autonomous.Cancelled;
  check int "cancellation invents no failed-turn diagnostic" 0
    (List.length (turn_error_logs before));
  check bool "cancelled autonomous identity released" true
    (Option.is_none (Autonomous.current ~base_path ~keeper_name));
  let persisted = read_journal
      (L.turn_journal_path ~base_dir:base_path ~keeper_name ~turn_ref) in
  check bool "cancelled producer retains its terminal fact" true
    (List.exists (fun (row : L.journaled_event) -> match row.event with
      | E.Event_error _ -> true
      | _ -> false) persisted)
;;

let () =
  run "Keeper public error boundaries"
    ["public copies",[
      test_case "terminal live/replay bytes are safe and identical" `Quick test_public_terminal_is_safe_and_matches_replay;
      test_case "real journal captures exact-secret public copies" `Quick test_public_journal_copy_redacts_captured_exact_secret;
      test_case "legacy empty error preserves a safe terminal fact" `Quick test_legacy_empty_error_has_safe_public_terminal;
      test_case "protocol error retains typed kind and safe message" `Quick test_public_protocol_error_keeps_kind_without_diagnostic;
      test_case "autonomous failure log keeps captured exact secrets private" `Quick test_autonomous_failure_redacts_log_with_captured_snapshot;
      test_case "autonomous cancellation has no failed-turn diagnostic" `Quick test_autonomous_cancel_has_no_failure_diagnostic]]
