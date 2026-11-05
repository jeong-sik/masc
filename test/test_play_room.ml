open Alcotest
module Room = Masc.Play_room
let ok = function Ok value -> value | Error error -> fail (Room.error_message error)
let rec remove_tree path =
  if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  end else Unix.unlink path
let workspace fn =
  let base_path = Filename.temp_dir "play-room-" "" in
  Fun.protect ~finally:(fun () -> remove_tree base_path) (fun () ->
    Eio_main.run (fun _ -> fn base_path))
let action ?(client = "tab1") ?(machine = "dos") ?text ?id ?before name =
  `Assoc (["action", `String name; "client_id", `String client; "machine", `String machine]
    @ (match text with None -> [] | Some s -> ["text", `String s])
    @ (match id with None -> [] | Some s -> ["message_id", `String s])
    @ (match before with None -> [] | Some n -> ["before", `Int n]))
let perform base_path ?(speaker = Room.Participant) ?(now = 100.) who args =
  Room.perform ~base_path ~who ~speaker ~now (ok (Room.parse_action args)) |> ok
let perform_change ~base_path:base_path ?(speaker = Room.Participant) ?(now = 100.) who args =
  Room.perform_with_change ~base_path ~who ~speaker ~now (ok (Room.parse_action args)) |> ok
let read base_path ?(now = 100.) ?before () = Room.read ~base_path ~now ~before |> ok
let texts snapshot = List.map (fun (m : Room.message) -> m.text) snapshot.Room.messages
let names snapshot = List.map (fun (m : Room.member) -> m.name) snapshot.Room.members

let test_shared_room () = workspace (fun base ->
  ignore (perform base ~speaker:Room.Keeper "keeper-a" (action "join"));
  ignore (perform base ~speaker:Room.Keeper "keeper-b" (action ~machine:"msx" "join"));
  ignore (perform base "player" (action ~id:"one" ~text:"같이 해요" "say"));
  let snapshot = perform base ~speaker:Room.Keeper "keeper-a" (action ~id:"reply" ~text:"좋아요" "say") in
  check (list string) "only explicit joins are members" ["keeper-a"; "keeper-b"] (names snapshot);
  check (list string) "one conversation across machines" ["같이 해요"; "좋아요"] (texts snapshot);
  check bool "verified Keeper attribution" true ((List.nth snapshot.messages 1).speaker = Room.Keeper);
  check (list string) "fresh database connection reads durable messages" (texts snapshot) (texts (read base ())))

let test_idempotency () = workspace (fun base ->
  let request = action ~id:"send-1" ~text:"hello" "say" in
  let first = perform base "alice" request in
  let retry = perform base ~now:105. "alice" request in
  check int "one durable message" 1 (List.length retry.messages);
  check int "same receipt id" (List.hd first.messages).id (List.hd retry.messages).id;
  let conflict = ok (Room.parse_action (action ~id:"send-1" ~text:"changed" "say")) in
  check bool "changed retry conflicts" true
    (match Room.perform ~base_path:base ~who:"alice" ~speaker:Room.Participant ~now:200. conflict with
     | Error (Room.Conflict _) -> true | _ -> false);
  check (list string) "conflict wrote nothing" ["hello"] (texts (read base ~now:200. ()));
  check (list string) "conflict did not renew membership" [] (names (read base ~now:200. ()));
  let other = perform base "bob" request in
  check int "another authenticated actor owns its own ids" 2 (List.length other.messages))

let flags (change : Room.change) =
  change.message_committed, change.membership_changed

let test_change_metadata () = workspace (fun base ->
  let _, join = perform_change ~base_path:base "alice" (action "join") in
  check (pair bool bool) "the first public member is a membership change" (false, true) (flags join);
  let _, first = perform_change ~base_path:base "alice" (action ~id:"first" ~text:"hello" "say") in
  check (pair bool bool) "a new message does not alter membership" (true, false) (flags first);
  let _, retry = perform_change ~base_path:base ~now:105. "alice" (action ~id:"first" ~text:"hello" "say") in
  check (pair bool bool) "an identical retry has no new effect" (false, false) (flags retry);
  let conflict = ok (Room.parse_action (action ~id:"first" ~text:"changed" "say")) in
  check bool "a conflicting retry cannot write" true
    (match Room.perform_with_change ~base_path:base ~who:"alice" ~speaker:Room.Participant ~now:106. conflict with
     | Error (Room.Conflict _) -> true | Ok _ | Error _ -> false);
  let _, renewal = perform_change ~base_path:base ~now:105. "alice" (action "join") in
  check (pair bool bool) "seen_at renewal is not a public change" (false, false) (flags renewal);
  let _, moved = perform_change ~base_path:base ~now:110. "alice" (action ~machine:"msx" "join") in
  check (pair bool bool) "changing the public machine is a membership change" (false, true) (flags moved);
  let _, left = perform_change ~base_path:base ~now:111. "alice" (action "leave") in
  check (pair bool bool) "the last Leave removes the public member" (false, true) (flags left);
  let reread, reread_change = perform_change ~base_path:base ~now:150. "alice" (action "read") in
  check (pair bool bool) "Read neither revives nor moves presence" (false, false) (flags reread_change);
  check (list string) "Read leaves no membership behind" [] (names reread))

let test_tab_membership_changes () = workspace (fun base ->
  ignore (perform base "alice" (action "join"));
  let _, second_tab = perform_change ~base_path:base ~now:100. "alice" (action ~client:"tab2" "join") in
  check (pair bool bool) "same-time joins do not duplicate the public member" (false, false) (flags second_tab);
  let remaining, first_leave = perform_change ~base_path:base ~now:100. "alice" (action "leave") in
  check (pair bool bool) "one tab leaving is not a public change" (false, false) (flags first_leave);
  check (list string) "the other tab retains public membership" ["alice"] (names remaining);
  let empty, final_leave = perform_change ~base_path:base ~now:100. "alice" (action ~client:"tab2" "leave") in
  check (pair bool bool) "the final tab leaving is a public change" (false, true) (flags final_leave);
  check (list string) "the final tab removes public membership" [] (names empty))

let test_expiry_announces_once () = workspace (fun base ->
  ignore (perform_change ~base_path:base "expiring" (action ~client:"expiry" "join"));
  let expired, expired_change = perform_change ~base_path:base ~now:160.5 "expiring" (action ~client:"expiry" "read") in
  check (pair bool bool) "a public member expiring is a change" (false, true) (flags expired_change);
  check (list string) "the expired public member is gone" [] (names expired);
  let _, repeated = perform_change ~base_path:base ~now:161. "expiring" (action ~client:"expiry" "read") in
  check (pair bool bool) "an already invisible member is not announced again" (false, false) (flags repeated))

let test_backward_clock_expiry () = workspace (fun base ->
  ignore (perform_change ~base_path:base ~now:200. "alice" (action "join"));
  ignore (perform_change ~base_path:base ~now:100. "alice" (action "join"));
  let expired, change = perform_change ~base_path:base ~now:161. "alice" (action "read") in
  check (pair bool bool) "a backward-clock Join still expires after its committed snapshot" (false, true) (flags change);
  check (list string) "the expired member is absent" [] (names expired))

let test_conflict_preserves_expiry () = workspace (fun base ->
  ignore (perform_change ~base_path:base "alice" (action "join"));
  ignore (perform_change ~base_path:base "alice" (action ~id:"first" ~text:"hello" "say"));
  let _, before = perform_change ~base_path:base ~now:150. "alice" (action "read") in
  check (pair bool bool) "the member is present before expiry" (false, false) (flags before);
  let conflict = ok (Room.parse_action (action ~id:"first" ~text:"changed" "say")) in
  (match Room.perform_with_change ~base_path:base ~who:"alice" ~speaker:Room.Participant ~now:160.5 conflict with
   | Error (Room.Conflict _) -> ()
   | Ok _ | Error _ -> fail "the conflicting retry must not commit");
  let expired, change = perform_change ~base_path:base ~now:160.5 "alice" (action "read") in
  check (pair bool bool) "a rollback does not consume the pending expiry" (false, true) (flags change);
  check (list string) "the successful read still removes the expired member" [] (names expired))

let test_first_stale_cleanup_is_silent () = workspace (fun base ->
  ignore (read base ());
  let directory = Filename.concat (Common.masc_dir_from_base_path ~base_path:base) "play" in
  let db = Sqlite3.db_open (Filename.concat directory "room.sqlite3") in
  Fun.protect ~finally:(fun () -> ignore (Sqlite3.db_close db : bool)) (fun () ->
    let rc = Sqlite3.exec db
      "INSERT INTO members(who,client_id,speaker,machine,seen_at) VALUES ('stale','raw','participant','dos',100.)" in
    check bool "seed an already stale raw row" true (Sqlite3.Rc.is_success rc));
  let expired, change = perform_change ~base_path:base ~now:160.5 "reader" (action "read") in
  check (pair bool bool) "first cleanup of an already invisible row is silent" (false, false) (flags change);
  check (list string) "stale raw membership remains invisible" [] (names expired))

let test_presence () = workspace (fun base ->
  check (list string) "reading alone does not join" [] (names (read base ()));
  ignore (perform base "alice" (action "join"));
  ignore (perform base "alice" (action ~client:"tab2" "join"));
  check (list string) "one name for two windows" ["alice"] (names (read base ()));
  let left = perform base "alice" (action "leave") in
  check (list string) "leaving one window retains the other" ["alice"] (names left);
  check (list string) "crashed clients expire" [] (names (read base ~now:161. ()));
  let back = perform base ~now:170. "alice" (action "read") in
  check (list string) "read does not renew explicit client" [] (names back);
  let joined = perform base ~now:171. "alice" (action "join") in
  check (list string) "an explicit join can rejoin" ["alice"] (names joined))

let test_unicode_space_with_text () = workspace (fun base ->
  let text = "\u{00A0}가\u{3000}" in
  let snapshot = perform base "player" (action ~id:"spaced" ~text "say") in
  check (list string) "spaces beside a letter are kept as written" [text] (texts snapshot))

let test_invalid () =
  List.iter (fun args -> check bool (Yojson.Safe.to_string args) true
    (match Room.parse_action args with Error (Room.Invalid_request _) -> true | _ -> false))
    [action ~id:"x" ~text:"   " "say"; action ~id:"x" ~text:"\u{00A0}\u{3000}\u{2003} \u{205F}" "say";
     action ~id:"x" ~text:(String.make 4097 'a') "say";
     action ~id:"x" ~text:"\255" "say"; action ~client:"../elsewhere" "join";
     action ~machine:"other" "join"; action ~before:0 "read"; action ~text:"unused" "join";
     `Assoc ["action", `String "join"; "client_id", `String "a"; "machine", `String "dos"; "who", `String "forged"]]

let test_pagination () = workspace (fun base ->
  for n = 1 to Room.history_page_size + 1 do
    ignore (perform base "alice" (action ~id:(string_of_int n) ~text:(string_of_int n) "say"))
  done;
  let latest = read base () in
  check int "bounded page" Room.history_page_size (List.length latest.messages);
  check bool "older messages indicated" true latest.has_more;
  let older = read base ~before:(List.hd latest.messages).id () in
  check (list string) "older message remains available" ["1"] (texts older);
  check bool "history ends" false older.has_more)

let test_concurrent () = workspace (fun base ->
  ignore (read base ());
  let send who () = for n = 1 to 5 do
    ignore (perform base who (action ~id:(string_of_int n) ~text:who "say")) done in
  Eio.Fiber.both (send "keeper-a") (send "keeper-b");
  let snapshot = read base () in
  check int "concurrent messages preserved" 10 (List.length snapshot.messages);
  let ids = List.map (fun (m : Room.message) -> m.id) snapshot.messages in
  check (list int) "one ordered sequence" (List.sort_uniq Int.compare ids) ids)

let test_keeper_dispatch () = workspace (fun base ->
  let heard = ref [] in
  let subscription = "play-room-tool-observer" in
  Masc.Sse.subscribe_external
    ~runtime_authority:(Masc.Sse.runtime_authority_exn ~base_path:base)
    ~id:subscription
    ~callback:(fun (event : Masc.Sse.external_event) ->
      match event.ext_payload with
      | `Assoc fields ->
          (match Masc.Workspace_dataset_event.of_fields fields with
           | Ok dataset -> heard := Masc.Workspace_dataset_event.dataset_name dataset :: !heard
           | Error _ -> ())
      | _ -> ())
    ();
  Fun.protect ~finally:(fun () -> Masc.Sse.unsubscribe_external subscription) (fun () ->
    let context : Masc.Tool_misc.context = {
      config = Masc.Workspace.default_config base; agent_name = "session-alias"; help_schemas = [] } in
    let args = action ~id:"keeper-message" ~text:"Hello from the game" "say" in
    let result = Masc.Tool_misc.dispatch ~lane_access:(Masc.Lane_addon_sources.Keeper "real-keeper")
      context ~name:"masc_play_room" ~args in
    (match result with
     | Some result ->
         check bool "tool succeeds" true (Tool_result.is_success result);
         (match Room.view_of_json (Tool_result.data result) with
          | Ok (viewer, _) -> check string "response viewer is the verified Keeper" "real-keeper" viewer
          | Error message -> fail message)
     | None -> fail "public room tool was not dispatched");
    check (list string) "the tool write announces Play room" ["play_room"] (List.rev !heard);
    let snapshot = read base ~now:(Unix.gettimeofday ()) () in
    let message = List.hd snapshot.messages in
    check string "verified principal wins over the session alias" "real-keeper" message.who;
    check bool "Keeper speaker mark" true (message.speaker = Room.Keeper);
    match Room.snapshot_of_json (Room.snapshot_json snapshot) with
    | Ok decoded ->
        check (list string) "wire readback" (texts snapshot) (texts decoded);
        check bool "a bare stored snapshot cannot invent a viewer" true
          (Result.is_error (Room.view_of_json (Room.snapshot_json snapshot)))
    | Error message -> fail message))

let () = run "public play room" ["room", [
  test_case "shared durable conversation" `Quick test_shared_room;
  test_case "uncertain send deduplicates; conflicts do not write" `Quick test_idempotency;
  test_case "actual changes carry message and public membership effects" `Quick test_change_metadata;
  test_case "only the final tab leaving changes public membership" `Quick test_tab_membership_changes;
  test_case "public expiry announces once" `Quick test_expiry_announces_once;
  test_case "backward-clock presence expires after its committed snapshot" `Quick test_backward_clock_expiry;
  test_case "a conflict does not consume public expiry" `Quick test_conflict_preserves_expiry;
  test_case "first stale raw cleanup is silent" `Quick test_first_stale_cleanup_is_silent;
  test_case "presence across tabs, expiry and read-only reads" `Quick test_presence;
  test_case "strict public request" `Quick test_invalid;
  test_case "unicode spaces beside text are kept" `Quick test_unicode_space_with_text;
  test_case "older history remains available" `Quick test_pagination;
  test_case "concurrent Keepers preserve messages" `Quick test_concurrent;
  test_case "Keeper tool uses verified identity and shared wire format" `Quick test_keeper_dispatch;
]]
