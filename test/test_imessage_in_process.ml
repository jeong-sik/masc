(* The parts of the iMessage connector that do not need a Mac.

   Only two things in this connector actually touch macOS: opening
   Messages.app's SQLite file, and spawning osascript. Everything else — which
   rows count as inbound, how Apple's clock converts, what argv is handed to
   the child, when the cursor advances — is ordinary code, and this suite
   proves it against a fixture database on any platform. That split is the
   reason the connector could move in-process at all: this repository has no
   macOS CI runner (0 of 34 [runs-on] declarations), so anything that could
   only be checked on a Mac would ship unchecked. *)

open Alcotest
module Db = Imessage_chat_db
module Gw = Server_imessage_in_process_gateway

let contains haystack needle =
  let n = String.length needle and h = String.length haystack in
  let rec at i =
    i + n <= h && (String.equal (String.sub haystack i n) needle || at (i + 1))
  in
  n = 0 || at 0
;;

let temp_counter = ref 0

let with_temp_db f =
  incr temp_counter;
  let path =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "imessage-fixture-%d-%06d.db" (Unix.getpid ()) !temp_counter)
  in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
    (fun () -> f path)
;;

(* The columns the two queries actually read, with Apple's names. A fixture
   rather than a captured chat.db: the real one is 240MB of personal
   correspondence and cannot go in a repository. *)
let create_fixture path =
  let db = Sqlite3.db_open path in
  let exec sql =
    let rc = Sqlite3.exec db sql in
    if not (Sqlite3.Rc.is_success rc) then
      failf "fixture setup failed: %s (%s)" (Sqlite3.Rc.to_string rc)
        (Sqlite3.errmsg db)
  in
  exec "CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT, service TEXT)";
  exec
    "CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, chat_identifier \
     TEXT, display_name TEXT, service_name TEXT, account_login TEXT)";
  exec
    "CREATE TABLE message (ROWID INTEGER PRIMARY KEY, text TEXT, date INTEGER, \
     is_from_me INTEGER, service TEXT, handle_id INTEGER)";
  exec "CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER)";
  exec
    "INSERT INTO handle (ROWID, id, service) VALUES \
     (1, 'friend@example.com', 'iMessage'), (2, '+821012345678', 'iMessage')";
  exec
    "INSERT INTO chat (ROWID, guid, chat_identifier, display_name, \
     service_name, account_login) VALUES \
     (1, 'iMessage;-;friend@example.com', 'friend@example.com', '', \
     'iMessage', 'E:me@example.com'), \
     (2, 'iMessage;+;chat42', 'chat42', 'Lunch crew', 'iMessage', \
     'E:me@example.com'), \
     (3, 'iMessage;-;me@example.com', 'me@example.com', '', 'iMessage', \
     'E:me@example.com')";
  (* 1 inbound; 2 outbound; 3 empty; 4 NULL text; 5 SMS; 6 inbound, group. *)
  exec
    "INSERT INTO message (ROWID, text, date, is_from_me, service, handle_id) \
     VALUES \
     (1, 'hello', 1000000000, 0, 'iMessage', 1), \
     (2, 'my own reply', 2000000000, 1, 'iMessage', 1), \
     (3, '', 3000000000, 0, 'iMessage', 1), \
     (4, NULL, 4000000000, 0, 'iMessage', 1), \
     (5, 'texted not imessaged', 5000000000, 0, 'SMS', 2), \
     (6, 'second one', 6000000000, 0, 'iMessage', 2)";
  exec
    "INSERT INTO chat_message_join (chat_id, message_id) VALUES \
     (1, 1), (1, 2), (1, 3), (1, 4), (2, 5), (2, 6)";
  if not (Sqlite3.db_close db) then failf "fixture db did not close"
;;

let test_apple_epoch_conversion () =
  (* 2001-01-01T00:00:00Z is 978307200 in Unix seconds, and [message.date]
     counts nanoseconds from there. *)
  check (float 0.000001) "the epoch itself" 978307200. (Db.apple_ns_to_unix 0L);
  check (float 0.000001) "one second in" 978307201.
    (Db.apple_ns_to_unix 1_000_000_000L)
;;

let test_redaction_keeps_the_routing_prefix () =
  check string "one-to-one chat" "iMessage;-;[redacted]"
    (Db.redact_chat_guid "iMessage;-;friend@example.com");
  check string "group chat" "iMessage;+;[redacted]"
    (Db.redact_chat_guid "iMessage;+;chat42");
  check string "nothing to split on is redacted whole" "[redacted]"
    (Db.redact_chat_guid "bare");
  check string "empty stays empty" "" (Db.redact_chat_guid "   ")
;;

let test_missing_database_is_not_a_denial () =
  (* The two have different fixes — install nothing vs. grant Full Disk Access
     — so they are different constructors rather than one "unavailable". *)
  match Db.check_access ~db_path:"/nonexistent/chat.db" with
  | Error (Db.Db_missing path) -> check string "carries the path it tried"
                                    "/nonexistent/chat.db" path
  | Error other -> failf "expected Db_missing, got %s" (Db.error_to_string other)
  | Ok () -> fail "a nonexistent database reported readable"
;;

(* The branch that actually fires on a Mac without Full Disk Access, and the
   only reason [Access_denied] is a separate constructor. Written as "the
   module agrees with the OS" rather than "the module says denied", because a
   CI runner that happens to be root can read a mode-000 file and a test that
   asserted the verdict outright would be lying about what it proved. *)
let test_access_verdict_matches_the_os () =
  incr temp_counter;
  let path =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "imessage-unreadable-%d-%06d.db" (Unix.getpid ())
         !temp_counter)
  in
  let oc = open_out path in
  output_string oc "not really a database";
  close_out oc;
  Unix.chmod path 0o000;
  Fun.protect
    ~finally:(fun () ->
      Unix.chmod path 0o600;
      Sys.remove path)
    (fun () ->
      let os_says_readable =
        match Unix.access path [ Unix.R_OK ] with
        | () -> true
        | exception Unix.Unix_error _ -> false
      in
      match Db.check_access ~db_path:path, os_says_readable with
      | Ok (), true -> ()
      | Error (Db.Access_denied reported), false ->
        check string "the denial names the file the operator has to grant"
          path reported
      | Ok (), false -> fail "the OS refuses the read and check_access allowed it"
      | Error other, true ->
        failf "the OS allows the read and check_access refused it (%s)"
          (Db.error_to_string other)
      | Error other, false ->
        failf "expected Access_denied, got %s" (Db.error_to_string other))
;;

let test_poll_selects_only_inbound_imessages () =
  with_temp_db @@ fun path ->
  create_fixture path;
  match Db.read_new ~db_path:path ~after_rowid:0 with
  | Error e -> failf "read_new failed: %s" (Db.error_to_string e)
  | Ok rows ->
    check (list int) "own replies, empty bodies, NULL text and SMS are excluded"
      [ 1; 6 ]
      (List.map (fun (r : Db.inbound_row) -> r.rowid) rows);
    (match rows with
     | [ first; second ] ->
       check string "sender comes from the handle" "friend@example.com"
         first.sender;
       check string "chat identifier is the binding key" "friend@example.com"
         first.chat_identifier;
       check string "chat guid addresses the reply"
         "iMessage;-;friend@example.com" first.chat_guid;
       check string "one-to-one chats have no display name" "" first.display_name;
       check string "group chats do" "Lunch crew" second.display_name;
       check (float 0.000001) "date is converted, not passed through"
         (978307200. +. 1.) first.sent_at_unix
     | _ -> fail "expected exactly two rows")
;;

let test_cursor_excludes_what_was_delivered () =
  with_temp_db @@ fun path ->
  create_fixture path;
  match Db.read_new ~db_path:path ~after_rowid:1 with
  | Error e -> failf "read_new failed: %s" (Db.error_to_string e)
  | Ok rows ->
    check (list int) "rows at or below the cursor are gone" [ 6 ]
      (List.map (fun (r : Db.inbound_row) -> r.rowid) rows);
    (match Db.read_new ~db_path:path ~after_rowid:6 with
     | Ok [] -> ()
     | Ok rows ->
       failf "expected nothing past the last row, got %d" (List.length rows)
     | Error e -> failf "read_new failed: %s" (Db.error_to_string e))
;;

let test_self_chat_resolution () =
  with_temp_db @@ fun path ->
  create_fixture path;
  (* The account login is stored with an "E:"/"P:" kind prefix; the
     note-to-self chat is the one whose identifier equals it with the prefix
     stripped. *)
  match Db.resolve_self_chat_guid ~db_path:path with
  | Ok (Some guid) ->
    check string "found the note-to-self conversation"
      "iMessage;-;me@example.com" guid
  | Ok None -> fail "no self chat resolved from the fixture"
  | Error e -> failf "resolve failed: %s" (Db.error_to_string e)
;;

let test_applescript_passes_text_as_an_argument () =
  (* The body is user text. Building the script by concatenation would make
     every reply an injection site, so the script is constant and the varying
     parts are argv entries. *)
  let nasty = "\" & (do shell script \"whoami\") & \"\nsecond line" in
  match Imessage_applescript.send_argv ~chat_guid:"iMessage;-;x" ~text:nasty with
  | [ "osascript"; "-e"; script; guid; text ] ->
    check string "the body is passed through untouched" nasty text;
    check string "the guid is its own argument" "iMessage;-;x" guid;
    check string "the script is the module constant"
      Imessage_applescript.script script;
    check bool "and the script itself carries none of the body" true
      (not (contains script "whoami"))
  | argv -> failf "unexpected argv shape (%d entries)" (List.length argv)
;;

let test_empty_chat_guid_refuses_to_send () =
  match Imessage_applescript.send ~chat_guid:"  " ~text:"hi" () with
  | Error Imessage_applescript.Missing_chat_guid -> ()
  | Error other ->
    failf "expected Missing_chat_guid, got %s"
      (Imessage_applescript.error_to_string other)
  | Ok () -> fail "sending with no chat guid was allowed"
;;

let test_cursor_codec () =
  check bool "round trips" true
    (Gw.For_testing.cursor_of_json (Gw.For_testing.cursor_to_json 4242) = Ok 4242);
  (* Restarting from zero would redeliver every message Messages.app has ever
     stored, so a file that cannot be read is an error, not a fresh start. *)
  List.iter
    (fun (label, content) ->
      check bool label true
        (Result.is_error (Gw.For_testing.cursor_of_json content)))
    [ "not json", "{"
    ; "not an object", "[1]"
    ; "missing the field", "{\"other\":1}"
    ; "wrong type", "{\"last_rowid\":\"12\"}"
    ; "negative", "{\"last_rowid\":-1}"
    ]
;;

let sample_row : Db.inbound_row =
  { rowid = 77
  ; text = "ping"
  ; sent_at_unix = 978307200.
  ; service = "iMessage"
  ; sender = "friend@example.com"
  ; chat_guid = "iMessage;-;friend@example.com"
  ; chat_identifier = "friend@example.com"
  ; display_name = ""
  }
;;

let test_inbound_projection () =
  let msg = Gw.For_testing.inbound_message_of_row ~keeper_name:"claude" sample_row in
  check string "channel" "imessage" msg.Channel_gate.channel;
  check string "keeper" "claude" msg.Channel_gate.keeper_name;
  check string "content" "ping" msg.Channel_gate.content;
  (* The ROWID is the message's identity in Messages.app, so keying on it makes
     a redelivered row collapse into the same turn instead of running twice. *)
  check string "idempotency key is the rowid" "imessage-msg-77"
    msg.Channel_gate.idempotency_key;
  check bool "conversation id names the chat" true
    (List.assoc_opt "conversation_id" msg.Channel_gate.metadata
     = Some (Gw.For_testing.conversation_id ~chat_identifier:"friend@example.com"));
  check bool "iMessage has no workspace" true
    (String.equal msg.Channel_gate.channel_workspace_id "");
  (* A gate contract check the projection must not violate. *)
  check bool "the projection passes gate validation" true
    (Result.is_ok (Channel_gate.validate msg));
  (* A group chat's name travels; a one-to-one chat has none to send. *)
  check bool "no display name key when there is no group name" true
    (Option.is_none
       (List.assoc_opt "imessage.chat_display_name" msg.Channel_gate.metadata));
  let group =
    Gw.For_testing.inbound_message_of_row ~keeper_name:"claude"
      { sample_row with chat_identifier = "chat42"; display_name = "Lunch crew" }
  in
  check bool "and one when there is" true
    (List.assoc_opt "imessage.chat_display_name" group.Channel_gate.metadata
     = Some "Lunch crew")
;;

let outbound : Channel_gate.outbound_message =
  { keeper_name = "claude"
  ; content = "pong"
  ; structured = None
  ; turn_stats = None
  ; message_request = None
  }
;;

(* This mapping is the whole at-least-once guarantee, so it is asserted
   directly rather than inferred from the loop's behaviour. *)
let test_cursor_advances_only_on_a_terminal_outcome () =
  let consumes outcome = Gw.For_testing.disposition_of_outcome outcome = Gw.Consume in
  check bool "an accepted turn advances the cursor" true (consumes (Ok outbound));
  (* A validation failure is permanent: the same row fails the same way
     forever, so leaving the cursor on it would wedge the conversation behind
     one bad message. *)
  check bool "a permanently invalid row advances past itself" true
    (consumes (Error (Channel_gate.Validation Channel_gate.Empty_content)));
  check bool "a too-long body also advances" true
    (consumes (Error (Channel_gate.Validation (Channel_gate.Content_too_long 99))));
  (* These three mean the accept did not happen, so the row is still owed. *)
  List.iter
    (fun (label, error) ->
      check bool label false (consumes (Error error)))
    [ "an offline keeper leaves the row", Channel_gate.Dispatch_unavailable
    ; "a keeper error leaves the row", Channel_gate.Keeper_error "boom"
    ; "an internal error leaves the row", Channel_gate.Internal "boom"
    ]
;;

let test_poll_interval_is_bounded () =
  check bool "unset takes the default" true
    (Gw.resolved_poll_interval_sec () = Ok Gw.default_poll_interval_sec);
  let with_interval value f =
    let previous = Sys.getenv_opt "MASC_IMESSAGE_POLL_INTERVAL_SEC" in
    Unix.putenv "MASC_IMESSAGE_POLL_INTERVAL_SEC" value;
    Fun.protect
      ~finally:(fun () ->
        Unix.putenv "MASC_IMESSAGE_POLL_INTERVAL_SEC"
          (Option.value previous ~default:""))
      f
  in
  with_interval "5" (fun () ->
    check bool "a valid value is taken" true
      (Gw.resolved_poll_interval_sec () = Ok 5.));
  (* Refused rather than replaced by the default: a cadence the operator did
     not choose is worse than a startup that says why it stopped. *)
  List.iter
    (fun (label, value) ->
      with_interval value (fun () ->
        check bool label true (Result.is_error (Gw.resolved_poll_interval_sec ()))))
    [ "not a number", "soon"; "below the floor", "0.01"; "absurdly slow", "86400" ]
;;

let () =
  run "imessage_in_process"
    [ ( "chat.db"
      , [ test_case "apple epoch conversion" `Quick test_apple_epoch_conversion
        ; test_case "redaction keeps the routing prefix" `Quick
            test_redaction_keeps_the_routing_prefix
        ; test_case "a missing database is not a denial" `Quick
            test_missing_database_is_not_a_denial
        ; test_case "the access verdict matches the OS" `Quick
            test_access_verdict_matches_the_os
        ; test_case "the poll selects only inbound iMessages" `Quick
            test_poll_selects_only_inbound_imessages
        ; test_case "the cursor excludes what was delivered" `Quick
            test_cursor_excludes_what_was_delivered
        ; test_case "self-chat resolution" `Quick test_self_chat_resolution
        ] )
    ; ( "applescript"
      , [ test_case "text is passed as an argument, never interpolated" `Quick
            test_applescript_passes_text_as_an_argument
        ; test_case "an empty chat guid refuses to send" `Quick
            test_empty_chat_guid_refuses_to_send
        ] )
    ; ( "gateway"
      , [ test_case "cursor codec" `Quick test_cursor_codec
        ; test_case "inbound projection" `Quick test_inbound_projection
        ; test_case "the cursor advances only on a terminal outcome" `Quick
            test_cursor_advances_only_on_a_terminal_outcome
        ; test_case "the poll interval is bounded" `Quick
            test_poll_interval_is_bounded
        ] )
    ]
