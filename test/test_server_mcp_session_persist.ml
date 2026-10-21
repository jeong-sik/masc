(** Actual session persistence/protocol and host-resource scenarios. No server
    controller, model, UI or installed runtime is launched by these cases. *)
open Alcotest
module Session = Server_mcp_transport_http_session

let with_temp_base f =
  let path = Filename.temp_file "masc-session-persist-" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  let base_path = Unix.realpath path in
  let rec remove path =
    match Unix.lstat path with
    | {Unix.st_kind=Unix.S_DIR;_} ->
        Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path
    | {Unix.st_kind=(Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK);_} ->
        Unix.unlink path
    | exception Unix.Unix_error (Unix.ENOENT,_,_) -> () in
  Fun.protect ~finally:(fun () -> remove base_path) (fun () -> f base_path)

let with_sessions ids f =
  Fun.protect ~finally:(fun () -> List.iter Session.forget_mcp_session ids) f

let remember sid =
  Session.remember_protocol_version sid Session.mcp_protocol_version_default;
  Session.remember_mcp_profile sid Server_mcp_transport_http_types.Operator_remote

let check_original sid =
  check bool "restored session retains its initialize authority" true (Session.is_known_session sid);
  (match Session.validate_mcp_session_delete_profile
      ~profile:Server_mcp_transport_http_types.Operator_remote sid with
   | Ok () -> () | Error detail -> fail detail);
  (match Session.validate_mcp_session_delete_profile ~profile:Server_mcp_transport_http_types.Seat sid with
   | Error _ -> () | Ok () -> fail "restored session changed its original transport profile")

let test_roundtrip () = with_temp_base @@ fun base_path ->
  let sid = "persist-roundtrip-session" in
  with_sessions [sid] @@ fun () ->
  remember sid;
  Session.save_sessions_to_file ~base_path ();
  let path = Session.sessions_file_path ~base_path () in
  check bool "actual owner persistence file written" true (Sys.file_exists path);
  check bool "no temporary residue after completed write" false (Sys.file_exists (path ^ ".tmp"));
  Session.forget_mcp_session sid;
  Session.load_sessions_from_file ~base_path ();
  check_original sid

let test_blocked_writers_preserve_live_sessions () = with_temp_base @@ fun base_path ->
  let first = "persist-blocked-original" and peer = "persist-independent-peer" in
  with_sessions [first;peer] @@ fun () ->
  let path = Session.sessions_file_path ~base_path () in
  Unix.mkdir (Filename.dirname path) 0o700;
  let temporary = path ^ ".tmp" in
  Unix.mkfifo temporary 0o600;
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  remember first;
  let write () = Session.save_sessions_to_file ~base_path () in
  let original = Eio.Fiber.fork_promise ~sw write in
  let queued = Eio.Fiber.fork_promise ~sw write in
  (* Both real writes need the actual FIFO's reader. The live session registry
     must remain usable before releasing that host resource. No I/O callback
     or session store is substituted. *)
  remember peer;
  check_original peer;
  ignore (Eio_guard.run_in_systhread ~label:"session-fixture-release-writer" (fun () ->
    In_channel.with_open_bin temporary In_channel.input_all));
  Eio.Promise.await_exn original;
  Eio.Promise.await_exn queued;
  (match (Unix.lstat path).Unix.st_kind with
   | Unix.S_REG -> ()
   | Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK ->
       fail "serialized final writer did not replace the temporary FIFO");
  check bool "both actual writers released their temporary namespace" false (Sys.file_exists temporary);
  List.iter Session.forget_mcp_session [first;peer];
  Session.load_sessions_from_file ~base_path ();
  check_original first;
  check_original peer

let with_held_read ~base_path bytes f =
  let path = Session.sessions_file_path ~base_path () in
  Unix.mkdir (Filename.dirname path) 0o700;
  Unix.mkfifo path 0o600;
  let mutex = Stdlib.Mutex.create () and condition = Condition.create () in
  let opened = ref false and released = ref false in
  let release () = Stdlib.Mutex.protect mutex (fun () ->
    released := true; Condition.broadcast condition) in
  let await_open () = Stdlib.Mutex.protect mutex (fun () ->
    while not !opened do Condition.wait condition mutex done) in
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun outer ->
  Fun.protect ~finally:release @@ fun () ->
  let writer = Eio.Fiber.fork_promise ~sw:outer (fun () ->
    Eio_guard.run_in_systhread ~label:"session-fixture-held-read" (fun () ->
      Out_channel.with_open_bin path (fun output ->
        (* Opening the FIFO proves that the production reader has connected.
           Keep actual JSON bytes withheld until the scenario releases them. *)
        Stdlib.Mutex.protect mutex (fun () ->
          opened := true; Condition.broadcast condition;
          while not !released do Condition.wait condition mutex done);
        output_string output bytes;
        flush output))) in
  f ~await_open:(fun () ->
    Eio_guard.run_in_systhread ~label:"session-fixture-reader-connected" await_open) ~release;
  Eio.Promise.await_exn writer

let session_bytes sid = Yojson.Basic.to_string (`Assoc ["sessions",`Assoc [sid,`Assoc
    ["protocol_version",`String Session.mcp_protocol_version_default;
     "profile",`String "operator_remote";"last_active_sse",`Float (Unix.gettimeofday ())]]])

let test_cancelled_read_does_not_apply_decoded_sessions () = with_temp_base @@ fun base_path ->
  let sid = "persist-cancelled-original" in
  with_sessions [sid] @@ fun () ->
  let bytes = session_bytes sid in
  with_held_read ~base_path bytes @@ fun ~await_open ~release ->
  let exception Stop_restore in
  let cancelled =
    try
      Eio.Switch.run (fun sw ->
        Eio.Fiber.fork ~sw (fun () -> Session.load_sessions_from_file ~base_path ());
        await_open ();
        Eio.Switch.fail sw Stop_restore;
        release ());
      false
    with Stop_restore -> true in
  check bool "selected restore scope joins structural cancellation" true cancelled;
  check bool "cancelled decode never publishes initialize authority" false (Session.is_known_session sid);
  (match Session.validate_mcp_session_delete_profile
      ~profile:Server_mcp_transport_http_types.Operator_remote sid with
   | Error _ -> () | Ok () -> fail "cancelled restore applied a transport profile");
  (* A fresh, joined restore can consume the same original snapshot. *)
  let path = Session.sessions_file_path ~base_path () in
  Sys.remove path;
  Out_channel.with_open_bin path (fun output -> output_string output bytes);
  Session.load_sessions_from_file ~base_path ();
  check_original sid

let test_connected_read_preserves_later_live_session () = with_temp_base @@ fun base_path ->
  let original = "persist-read-original" and peer = "persist-during-read-peer" in
  with_sessions [original;peer] @@ fun () ->
  with_held_read ~base_path (session_bytes original) @@ fun ~await_open ~release ->
  Eio.Switch.run @@ fun sw ->
  let loading = Eio.Fiber.fork_promise ~sw (fun () -> Session.load_sessions_from_file ~base_path ()) in
  await_open ();
  (* The production read is connected but has not received any JSON. Changes
     now must survive application; restoring a pre-read registry would lose them. *)
  remember peer;
  check_original peer;
  release ();
  Eio.Promise.await_exn loading;
  check_original original;
  check_original peer

let test_overlay_preserves_original_field_policies () = with_temp_base @@ fun base_path ->
  let duplicate = "persist-duplicate" and existing = "persist-existing-optionals"
  and peer = "persist-overlay-peer" and invalid = "persist-invalid-only"
  and malformed = "persist-malformed-entry" in
  with_sessions [duplicate;existing;peer;invalid;malformed] @@ fun () ->
  let original_version = Session.mcp_protocol_version_default in
  let next_version = match List.find_opt ((<>) original_version) Session.mcp_protocol_versions with
    | Some version -> version
    | None -> fail "protocol overlay scenario requires two supported protocol versions" in
  let invalid_version = "unsupported-session-fixture-version" in
  let path = Session.sessions_file_path ~base_path () in
  Unix.mkdir (Filename.dirname path) 0o700;
  let load rows =
    Yojson.Basic.to_file path (`Assoc ["sessions",`Assoc rows]);
    Session.load_sessions_from_file ~base_path () in
  let persisted sid =
    Session.save_sessions_to_file ~base_path ();
    Yojson.Basic.Util.(Yojson.Basic.from_file path |> member "sessions" |> member sid) in
  let string_field fields key expected =
    check string key expected Yojson.Basic.Util.(fields |> member key |> to_string) in
  load [existing,`Assoc ["protocol_version",`String original_version;
    "profile",`String "seat";"network_protocol_name",`String "http";
    "network_protocol_version",`String "2";"network_transport",`String "tcp"]];
  remember peer;
  load [duplicate,`Assoc ["protocol_version",`String original_version;
      "profile",`String "operator_remote";"last_active_sse",`Float 12.;"started_at",`Float 8.;
      "network_protocol_name",`String "http";"network_protocol_version",`String "1.1";
      "network_transport",`String "tcp"];
    duplicate,`Assoc ["protocol_version",`String next_version;"profile",`String "unknown-profile"];
    duplicate,`Assoc ["protocol_version",`String invalid_version;
      "profile",`String "seat";"network_transport",`String "discarded"];
    existing,`Assoc ["protocol_version",`String next_version];
    invalid,`Assoc ["protocol_version",`String invalid_version;"profile",`String "operator_remote"];
    malformed,`Null];
  check_original duplicate;
  check_original peer;
  (match Session.validate_mcp_session_delete_profile ~profile:Server_mcp_transport_http_types.Seat existing with
   | Ok () -> () | Error detail -> fail detail);
  (match Session.validate_mcp_session_delete_profile
      ~profile:Server_mcp_transport_http_types.Operator_remote existing with
   | Error _ -> () | Ok () -> fail "absent profile replaced existing session authority");
  List.iter (fun sid ->
    check bool "invalid row grants no initialize authority" false (Session.is_known_session sid);
    match Session.validate_mcp_session_delete_profile
        ~profile:Server_mcp_transport_http_types.Operator_remote sid with
    | Error _ -> () | Ok () -> fail "invalid row granted transport profile authority") [invalid;malformed];
  let fields = persisted duplicate in
  string_field fields "protocol_version" next_version;
  string_field fields "network_protocol_name" "http";
  string_field fields "network_protocol_version" "1.1";
  string_field fields "network_transport" "tcp";
  List.iter (fun key ->
    check (float 0.) key 0. Yojson.Basic.Util.(fields |> member key |> to_float))
    ["last_active_sse";"started_at"];
  let existing_fields = persisted existing in
  string_field existing_fields "protocol_version" next_version;
  string_field existing_fields "network_protocol_name" "http";
  string_field existing_fields "network_protocol_version" "2";
  string_field existing_fields "network_transport" "tcp";
  (* A present partial transport replaces the whole old transport record. *)
  load [duplicate,`Assoc ["protocol_version",`String next_version;"network_transport",`String "unix"]];
  let replaced = persisted duplicate in
  string_field replaced "network_transport" "unix";
  List.iter (fun key ->
    check bool "replacement does not retain absent transport labels" true
      Yojson.Basic.Util.(replaced |> member key = `Null)) ["network_protocol_name";"network_protocol_version"];
  check_original duplicate;
  check_original peer

let () =
  run "server_mcp_session_persist"
    ["persistence",
      [test_case "save/forget/load retains original session and profile" `Quick test_roundtrip;
       test_case "blocked serialized writers preserve independent live session work" `Quick
         test_blocked_writers_preserve_live_sessions;
       test_case "cancelled physical read does not apply decoded sessions" `Quick
         test_cancelled_read_does_not_apply_decoded_sessions;
       test_case "connected restore preserves independent session created during physical read" `Quick
         test_connected_read_preserves_later_live_session;
       test_case "actual overlays retain duplicate and optional-field authority" `Quick
         test_overlay_preserves_original_field_policies]]
