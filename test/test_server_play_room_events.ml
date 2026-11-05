open Alcotest
module Events = Server_play_room_events
module Room = Masc.Play_room

let ok = function Ok value -> value | Error error -> fail (Room.error_message error)

let rec remove_tree path =
  if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  end else Unix.unlink path

let workspace fn =
  let base_path = Filename.temp_dir "play-room-events-" "" in
  Fun.protect ~finally:(fun () -> remove_tree base_path) (fun () ->
    Eio_main.run (fun _ -> fn base_path))

let with_events base_path fn =
  let heard = ref [] in
  let subscription = "play-room-events-" ^ Random_id.hex ~bytes:6 in
  Masc.Sse.subscribe_external
    ~runtime_authority:(Masc.Sse.runtime_authority_exn ~base_path)
    ~id:subscription
    ~callback:(fun (event : Masc.Sse.external_event) ->
      match event.ext_payload with
      | `Assoc fields ->
        (match Masc.Workspace_dataset_event.of_fields fields with
         | Ok (Masc.Workspace_dataset_event.Play_room _) ->
           heard := "play_room" :: !heard
         | Ok _ | Error _ -> ())
      | _ -> ())
    ();
  Fun.protect ~finally:(fun () -> Masc.Sse.unsubscribe_external subscription)
    (fun () -> fn heard)

let scope ?(client = "tab1") ?(machine = Masc.Machine_lane.Dos) () =
  { Events.play_client = client; machine }

let connect base_path ?(agent_name = "player") ?(role = Masc_domain.Player) ?(sse_client_id = 1) room_scope =
  match Events.connect ~base_path ~agent_name ~role ~scope:room_scope ~sse_client_id with
  | Ok Events.Connected -> ()
  | Ok Events.Stale -> fail "a stale connect was accepted as the successor"
  | Error error -> fail (Room.error_message error)

let disconnect base_path ?(agent_name = "player") ?(role = Masc_domain.Player) ?(sse_client_id = 1) room_scope =
  Events.disconnect ~base_path ~agent_name ~role ~scope:room_scope ~sse_client_id |> ok

let members base_path =
  (Room.read ~base_path ~now:(Time_compat.now ()) ~before:None |> ok).members

let names base_path = List.map (fun (member : Room.member) -> member.name) (members base_path)
let event_count heard = List.length !heard

let action ?(client = "tab1") ?(machine = "dos") ?text ?id name =
  `Assoc (["action", `String name; "client_id", `String client; "machine", `String machine]
    @ (match text with None -> [] | Some value -> ["text", `String value])
    @ (match id with None -> [] | Some value -> ["message_id", `String value]))

let perform_http base_path ?(agent_name = "player") ?(role = Masc_domain.Player) json =
  Events.perform_http ~base_path ~agent_name ~role (Room.parse_action json |> ok) |> ok

let test_connect_renew_disconnect () = workspace (fun base_path ->
  with_events base_path (fun heard ->
    let room_scope = scope () in
    connect base_path room_scope;
    check (list string) "connect joins the authenticated principal" ["player"] (names base_path);
    check int "connect announces once" 1 (event_count heard);
    let before = List.hd (members base_path) in
    Events.renew ~base_path ~agent_name:"player" ~role:Masc_domain.Player
      ~scope:room_scope ~sse_client_id:1 |> ok;
    let after = List.hd (members base_path) in
    check bool "renewal cannot move presence backwards" true (after.seen_at >= before.seen_at);
    check int "renewal is silent" 1 (event_count heard);
    disconnect base_path room_scope;
    check (list string) "disconnect removes membership" [] (names base_path);
    check int "the final disconnect announces" 2 (event_count heard)))

let test_replacement_and_http_lease () = workspace (fun base_path ->
  with_events base_path (fun heard ->
    let room_scope = scope () in
    connect base_path ~sse_client_id:10 room_scope;
    connect base_path ~sse_client_id:11 room_scope;
    check int "replacement does not duplicate the public member" 1 (event_count heard);
    let current = List.hd (members base_path) in
    Events.renew ~base_path ~agent_name:"player" ~role:Masc_domain.Player
      ~scope:room_scope ~sse_client_id:10 |> ok;
    check bool "a stale renewal is inert" true
      ((List.hd (members base_path)).seen_at = current.seen_at);
    disconnect base_path ~sse_client_id:10 room_scope;
    check (list string) "stale disconnect keeps the replacement" ["player"] (names base_path);
    let join = perform_http base_path (action ~machine:"msx" "join") in
    check (list string) "HTTP Join cannot move an active lease" ["dos"]
      (List.map (fun (member : Room.member) -> Masc.Machine_lane.to_wire member.machine) join.members);
    let left = perform_http base_path (action "leave") in
    check int "HTTP Leave cannot remove the replacement" 1 (List.length left.members);
    check int "stale and guarded effects stay silent" 1 (event_count heard);
    disconnect base_path ~sse_client_id:11 room_scope;
    check (list string) "the exact replacement disconnects" [] (names base_path);
    check int "only real public transitions announce" 2 (event_count heard)))

let test_stale_connect_is_explicit () = workspace (fun base_path ->
  with_events base_path (fun heard ->
    let room_scope = scope () in
    connect base_path ~sse_client_id:60 room_scope;
    connect base_path ~sse_client_id:61 room_scope;
    (match Events.connect ~base_path ~agent_name:"player" ~role:Masc_domain.Player
      ~scope:room_scope ~sse_client_id:60 with
     | Ok Events.Stale -> ()
     | Ok Events.Connected -> fail "the older connect replaced its successor"
     | Error error -> fail (Room.error_message error));
    check (list string) "stale connect keeps the successor" ["player"] (names base_path);
    check int "stale connect announces no public transition" 1 (event_count heard);
    disconnect base_path ~sse_client_id:61 room_scope))

let test_permission_denial_leaves_no_lease () = workspace (fun base_path ->
  with_events base_path (fun heard ->
    let room_scope = scope () in
    Events.For_testing.with_permission (fun _ _ -> false) (fun () ->
      match Events.connect ~base_path ~agent_name:"player" ~role:Masc_domain.Player
        ~scope:room_scope ~sse_client_id:20 with
      | Error _ -> ()
      | Ok () -> fail "permission denial admitted presence");
    check (list string) "denial creates no member" [] (names base_path);
    check int "denial announces nothing" 0 (event_count heard);
    connect base_path ~sse_client_id:20 room_scope;
    check (list string) "a later admitted connection is not blocked by a stale lease" ["player"] (names base_path);
    disconnect base_path ~sse_client_id:20 room_scope))

let test_renew_failure_keeps_lease_for_next_ping () = workspace (fun base_path ->
  with_events base_path (fun heard ->
    let room_scope = scope () in
    connect base_path ~sse_client_id:30 room_scope;
    let fail_next = ref true in
    Events.For_testing.with_perform
      (fun ~base_path ~who ~speaker ~now action ->
        if !fail_next then Error (Room.Unavailable "injected renewal failure")
        else Room.perform_with_change ~base_path ~who ~speaker ~now action)
      (fun () ->
        match Events.renew ~base_path ~agent_name:"player" ~role:Masc_domain.Player
          ~scope:room_scope ~sse_client_id:30 with
        | Error (Room.Unavailable _) -> ()
        | Error _ | Ok () -> fail "the injected renewal failure was lost");
    check (list string) "a failed renewal leaves presence for the next ping" ["player"] (names base_path);
    check int "a failed renewal announces nothing new" 1 (event_count heard);
    fail_next := false;
    Events.renew ~base_path ~agent_name:"player" ~role:Masc_domain.Player
      ~scope:room_scope ~sse_client_id:30 |> ok;
    disconnect base_path ~sse_client_id:30 room_scope))

let test_disconnect_finishes_before_cancellation () =
  let exception Disconnect_fixture in
  workspace (fun base_path ->
  with_events base_path (fun heard ->
    let room_scope = scope () in
    connect base_path ~sse_client_id:40 room_scope;
    let cancelled =
      try
        Eio.Cancel.sub (fun context ->
          Eio.Cancel.cancel context Disconnect_fixture;
          ignore (Events.disconnect ~base_path ~agent_name:"player" ~role:Masc_domain.Player
            ~scope:room_scope ~sse_client_id:40);
          false)
      with
      | Eio.Cancel.Cancelled Disconnect_fixture -> true
      | Eio.Cancel.Cancelled _ -> false
    in
    check bool "the original cancellation is preserved" true cancelled;
    check (list string) "protected cleanup still removes membership" [] (names base_path);
    check int "protected cleanup announces the actual Leave" 2 (event_count heard);
    connect base_path ~sse_client_id:40 room_scope;
    check (list string) "cleanup also releases the lease key" ["player"] (names base_path);
    disconnect base_path ~sse_client_id:40 room_scope))

let expect_no_scope target =
  match Events.room_scope_of_request_target target with
  | Ok None -> ()
  | Ok (Some _) | Error _ -> failf "unexpected Play scope in %s" target

let expect_scope target client machine =
  match Events.room_scope_of_request_target target with
  | Ok (Some room_scope) ->
    check string "Play client" client room_scope.play_client;
    check string "Play machine" machine (Masc.Machine_lane.to_wire room_scope.machine)
  | Ok None | Error _ -> failf "missing Play scope in %s" target

let expect_bad_scope target =
  match Events.room_scope_of_request_target target with
  | Error _ -> ()
  | Ok _ -> failf "invalid Play scope was accepted: %s" target

let test_room_scope_is_strict_and_separate () =
  expect_no_scope "/mcp";
  expect_no_scope "/mcp?machine=msx";
  expect_scope "/mcp?machine=msx&play_machine=dos&play_client_id=tab-1" "tab-1" "dos";
  List.iter expect_bad_scope
    [ "/mcp?play_client_id=tab-1"
    ; "/mcp?play_machine=dos"
    ; "/mcp?play_machine=dos&play_client_id=../elsewhere"
    ; "/mcp?play_machine=other&play_client_id=tab-1"
    ; "/mcp?play_machine=dos&play_machine=msx&play_client_id=tab-1"
    ; "/mcp?play_machine=dos&play_client_id=tab-1&play_client_id=tab-2" ]

let test_play_machine_does_not_step_control () = workspace (fun base_path ->
  let calls = ref 0 in
  Server_machine_spectator.For_testing.with_step
    (fun ~config:_ ~machine:_ -> incr calls; Ok ()) (fun () ->
      let room_scope = scope ~machine:Masc.Machine_lane.Msx () in
      connect base_path ~sse_client_id:50 room_scope;
      check int "room membership does not advance Control" 0 !calls;
      check (list string) "Play metadata still selects its own machine" ["msx"]
        (List.map (fun (member : Room.member) -> Masc.Machine_lane.to_wire member.machine) (members base_path));
      disconnect base_path ~sse_client_id:50 room_scope))

let test_http_read_say_and_idempotent_join () = workspace (fun base_path ->
  with_events base_path (fun heard ->
    let sent = perform_http base_path (action ~id:"one" ~text:"hello" "say") in
    check int "Say records a message without presence" 1 (List.length sent.messages);
    check (list string) "Say does not join" [] (names base_path);
    ignore (perform_http base_path (action ~id:"one" ~text:"hello" "say"));
    check int "an identical Say emits no second event" 1 (event_count heard);
    ignore (perform_http base_path (action "read"));
    check int "Read emits nothing" 1 (event_count heard);
    ignore (perform_http base_path (action "join"));
    ignore (perform_http base_path (action "join"));
    check int "only the first public Join announces" 2 (event_count heard);
    ignore (perform_http base_path (action "leave"));
    check int "the final HTTP Leave announces" 3 (event_count heard)))

let test_registration_cas_rejects_older_commit () = workspace (fun base_path ->
  let session_id = "play-room-cas-" ^ Random_id.hex ~bytes:4 in
  let auth = Masc_test_deps.make_sse_auth base_path "cas-observer" in
  ignore (Masc.Session.McpSessionStore.get_or_create ~id:session_id ());
  let previous_hook = Atomic.get Masc.Sse.register_commit_test_hook in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set Masc.Sse.register_commit_test_hook previous_hook;
      Masc.Sse.unregister session_id)
    (fun () ->
      Atomic.set Masc.Sse.register_commit_test_hook (Some (fun () ->
        Atomic.set Masc.Sse.register_commit_test_hook None;
        match Masc.Sse.register_with_client ~kind:Masc.Sse.Observer ~auth session_id ~last_event_id:0 with
        | Ok _ -> ()
        | Error error -> fail (Masc.Sse.registration_error_to_string error)));
      (match Masc.Sse.register_with_client ~kind:Masc.Sse.Observer ~auth session_id ~last_event_id:0 with
       | Error (Masc.Sse.Registration_stale _) -> ()
       | Error error -> fail (Masc.Sse.registration_error_to_string error)
       | Ok _ -> fail "the older registration commit replaced its successor");
      check bool "the newer registration remains committed" true (Masc.Sse.exists session_id)))

let test_register_returns_exact_client_identity () = workspace (fun base_path ->
  let session_id = "play-room-register-" ^ Random_id.hex ~bytes:4 in
  let auth = Masc_test_deps.make_sse_auth base_path "registered-keeper" in
  ignore (Masc.Session.McpSessionStore.get_or_create ~id:session_id ());
  match Masc.Sse.register_with_client ~kind:Masc.Sse.Observer ~auth session_id ~last_event_id:0 with
  | Error error -> fail (Masc.Sse.registration_error_to_string error)
  | Ok (client, _, _) ->
    Fun.protect ~finally:(fun () -> Masc.Sse.unregister_if_current session_id client.id) (fun () ->
      check string "principal comes from the registered credential" "registered-keeper" client.agent_name;
      check bool "role comes from the registered credential" true (client.role = Masc_domain.Worker);
      check bool "the client is an Observer" true (client.kind = Masc.Sse.Observer)))

let () = run "Play room Observer presence" ["presence", [
  test_case "connect, renew and disconnect carry real changes" `Quick test_connect_renew_disconnect;
  test_case "replacement and HTTP presence are lease guarded" `Quick test_replacement_and_http_lease;
  test_case "stale connect is explicit" `Quick test_stale_connect_is_explicit;
  test_case "permission denial leaves no lease" `Quick test_permission_denial_leaves_no_lease;
  test_case "renew failure keeps the next ping lease" `Quick test_renew_failure_keeps_lease_for_next_ping;
  test_case "disconnect completes before cancellation" `Quick test_disconnect_finishes_before_cancellation;
  test_case "query is strict and independent from Control" `Quick test_room_scope_is_strict_and_separate;
  test_case "Play machine never steps Control" `Quick test_play_machine_does_not_step_control;
  test_case "HTTP Read and Say do not own presence" `Quick test_http_read_say_and_idempotent_join;
  test_case "registration CAS rejects an older commit" `Quick test_registration_cas_rejects_older_commit;
  test_case "registration returns its exact client identity" `Quick test_register_returns_exact_client_identity;
]]
