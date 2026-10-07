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
let read base_path ?(now = 100.) ?before () = Room.read ~base_path ~now ~before |> ok
let texts snapshot = List.map (fun (m : Room.message) -> m.text) snapshot.Room.messages
let names snapshot = List.map (fun (m : Room.member) -> m.name) snapshot.Room.members

let test_shared_room () = workspace (fun base ->
  ignore (perform base ~speaker:Room.Keeper "keeper-a" (action "join"));
  ignore (perform base ~speaker:Room.Keeper "keeper-b" (action ~machine:"msx" "join"));
  ignore (perform base "player" (action ~id:"one" ~text:"같이 해요" "say"));
  let snapshot = perform base ~speaker:Room.Keeper "keeper-a" (action ~id:"reply" ~text:"좋아요" "say") in
  check (list string) "all joined identities" ["keeper-a"; "keeper-b"; "player"] (names snapshot);
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

let test_presence () = workspace (fun base ->
  check (list string) "reading alone does not join" [] (names (read base ()));
  ignore (perform base "alice" (action "join"));
  ignore (perform base "alice" (action ~client:"tab2" "join"));
  check (list string) "one name for two windows" ["alice"] (names (read base ()));
  let left = perform base "alice" (action "leave") in
  check (list string) "leaving one window retains the other" ["alice"] (names left);
  check (list string) "crashed clients expire" [] (names (read base ~now:161. ()));
  let back = perform base ~now:170. "alice" (action "read") in
  check (list string) "read renews explicit client" ["alice"] (names back))

let test_invalid () =
  List.iter (fun args -> check bool (Yojson.Safe.to_string args) true
    (match Room.parse_action args with Error (Room.Invalid_request _) -> true | _ -> false))
    [action ~id:"x" ~text:"   " "say"; action ~id:"x" ~text:(String.make 4097 'a') "say";
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
  let context : Masc.Tool_misc.context = {
    config = Masc.Workspace.default_config base; agent_name = "session-alias"; help_schemas = [] } in
  let args = action ~id:"keeper-message" ~text:"Hello from the game" "say" in
  let result = Masc.Tool_misc.dispatch ~lane_access:(Masc.Lane_addon_sources.Keeper "real-keeper")
    context ~name:"masc_play_room" ~args in
  (match result with
   | Some result -> check bool "tool succeeds" true (Masc.Tool_result.is_success result)
   | None -> fail "public room tool was not dispatched");
  let snapshot = read base ~now:(Unix.gettimeofday ()) () in
  let message = List.hd snapshot.messages in
  check string "verified principal wins over the session alias" "real-keeper" message.who;
  check bool "Keeper speaker mark" true (message.speaker = Room.Keeper);
  match Room.snapshot_of_json (Room.snapshot_json snapshot) with
  | Ok decoded -> check (list string) "wire readback" (texts snapshot) (texts decoded)
  | Error message -> fail message)

let () = run "public play room" ["room", [
  test_case "shared durable conversation" `Quick test_shared_room;
  test_case "uncertain send deduplicates; conflicts do not write" `Quick test_idempotency;
  test_case "presence across tabs, expiry and rejoin" `Quick test_presence;
  test_case "strict public request" `Quick test_invalid;
  test_case "older history remains available" `Quick test_pagination;
  test_case "concurrent Keepers preserve messages" `Quick test_concurrent;
  test_case "Keeper tool uses verified identity and shared wire format" `Quick test_keeper_dispatch;
]]
