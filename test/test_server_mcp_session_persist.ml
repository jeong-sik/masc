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

let save ~base_path () =
  match Session.save_sessions_to_file ~base_path () with
  | Session.Saved -> ()
  | Session.Skipped _ -> fail "expected actual persistence, observed a skipped save"
  | Session.Save_failed _ -> fail "expected actual persistence, observed a write failure"

let skipped ~base_path expected =
  match Session.save_sessions_to_file ~base_path () with
  | Session.Skipped reason -> check bool "original typed skip reason retained" true (expected reason)
  | Session.Saved -> fail "preserved original was reported as replaced"
  | Session.Save_failed _ -> fail "preservation attempted a failing write"

let test_roundtrip () = with_temp_base @@ fun base_path ->
  let sid = "persist-roundtrip-session" in
  with_sessions [sid] @@ fun () ->
  remember sid;
  save ~base_path ();
  let path = Session.sessions_file_path ~base_path () in
  check bool "actual owner persistence file written" true (Sys.file_exists path);
  check bool "no temporary residue after completed write" false (Sys.file_exists (path ^ ".tmp"));
  Session.forget_mcp_session sid;
  Session.load_sessions_from_file ~base_path ();
  check_original sid

let test_concurrent_writers_leave_existing_fifo () = with_temp_base @@ fun base_path ->
  let first = "persist-concurrent-original" and peer = "persist-concurrent-peer" in
  with_sessions [first;peer] @@ fun () ->
  let path = Session.sessions_file_path ~base_path () in
  Unix.mkdir (Filename.dirname path) 0o700;
  let unrelated = path ^ ".tmp" in
  Unix.mkfifo unrelated 0o600;
  remember first;
  remember peer;
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let original = Eio.Fiber.fork_promise ~sw (fun () -> save ~base_path ()) in
  let queued = Eio.Fiber.fork_promise ~sw (fun () -> save ~base_path ()) in
  Eio.Promise.await_exn original;
  Eio.Promise.await_exn queued;
  check bool "completed snapshot is a regular file" true ((Unix.lstat path).Unix.st_kind = Unix.S_REG);
  check bool "preexisting temporary FIFO remains in place" true ((Unix.lstat unrelated).Unix.st_kind = Unix.S_FIFO);
  let names = Sys.readdir (Filename.dirname path) in
  check bool "completed writers leave no private temporary residue" true
    (Array.for_all (fun name -> name = Filename.basename path || name = Filename.basename unrelated) names);
  List.iter Session.forget_mcp_session [first;peer];
  Session.load_sessions_from_file ~base_path ();
  check_original first;
  check_original peer

let session_bytes sid = Yojson.Basic.to_string (`Assoc ["sessions",`Assoc [sid,`Assoc
    ["protocol_version",`String Session.mcp_protocol_version_default;
     "profile",`String "operator_remote";"last_active_sse",`Float (Unix.gettimeofday ())]]])

let test_cancelled_restore_does_not_admit_or_apply () = with_temp_base @@ fun base_path ->
  let sid = "persist-cancelled-original" in
  with_sessions [sid] @@ fun () ->
  let path = Session.sessions_file_path ~base_path () in
  Unix.mkdir (Filename.dirname path) 0o700;
  let bytes = session_bytes sid in
  Out_channel.with_open_bin path (fun output -> output_string output bytes);
  Eio_main.run @@ fun _env ->
  let exception Stop_restore in
  let cancelled = try
    Eio.Switch.run (fun sw ->
      Eio.Switch.fail sw Stop_restore;
      Session.load_sessions_from_file ~base_path ());
    false
  with Stop_restore | Eio.Cancel.Cancelled _ -> true in
  check bool "cancelled caller cannot enter restoration" true cancelled;
  check bool "cancelled caller grants no initialize authority" false (Session.is_known_session sid);
  (match Session.validate_mcp_session_delete_profile
      ~profile:Server_mcp_transport_http_types.Operator_remote sid with
   | Error _ -> () | Ok () -> fail "cancelled caller applied profile authority");
  skipped ~base_path (function
    | Session.Restore_unobserved -> true
    | Session.Restore_unsettled | Session.Restore_failed _ -> false);
  check string "unadmitted original retains its actual bytes" bytes
    (In_channel.with_open_bin path In_channel.input_all);
  Session.load_sessions_from_file ~base_path ();
  check_original sid;
  save ~base_path ()

let test_preexisting_temporary_symlink_is_untouched () = with_temp_base @@ fun base_path ->
  let sid = "persist-private-output" in
  with_sessions [sid] @@ fun () ->
  let path = Session.sessions_file_path ~base_path () in
  Unix.mkdir (Filename.dirname path) 0o700;
  let unrelated = path ^ ".tmp" and target = Filename.concat base_path "retained-target" in
  let bytes = "preexisting symlink target evidence" in
  Out_channel.with_open_bin target (fun output -> output_string output bytes);
  Unix.symlink target unrelated;
  remember sid;
  save ~base_path ();
  check string "save never truncates a preexisting symlink target" bytes
    (In_channel.with_open_bin target In_channel.input_all);
  check string "preexisting temporary symlink retains its target" target (Unix.readlink unrelated);
  check bool "published snapshot is regular" true ((Unix.lstat path).Unix.st_kind = Unix.S_REG);
  Session.forget_mcp_session sid;
  Session.load_sessions_from_file ~base_path ();
  check_original sid

let test_nonregular_snapshot expected_kind create () = with_temp_base @@ fun base_path ->
  let sid = "persist-nonregular-live" in
  with_sessions [sid;"persist-unread-symlink-target"] @@ fun () ->
  let path = Session.sessions_file_path ~base_path () in
  Unix.mkdir (Filename.dirname path) 0o700;
  let verify_resource = create path in
  Session.load_sessions_from_file ~base_path ();
  remember sid;
  check_original sid;
  skipped ~base_path (function
    | Session.Restore_failed (Session.Non_regular_file kind) -> kind = expected_kind
    | Session.Restore_failed (Session.Read_failed _ | Session.Json_failed _ | Session.Shape_rejected)
    | Session.Restore_unobserved | Session.Restore_unsettled -> false);
  ignore (Session.reap_stale_sessions ~base_path ~is_active_session:(fun _ -> true));
  check bool "nonregular original remains in place" true ((Unix.lstat path).Unix.st_kind = expected_kind);
  verify_resource ();
  check_original sid

let test_ready_destination_changed_to_fifo_is_preserved () = with_temp_base @@ fun base_path ->
  let sid = "persist-changed-destination-live" in
  with_sessions [sid] @@ fun () ->
  let path = Session.sessions_file_path ~base_path () in
  Unix.mkdir (Filename.dirname path) 0o700;
  Session.load_sessions_from_file ~base_path ();
  Unix.mkfifo path 0o600;
  remember sid;
  skipped ~base_path (function
    | Session.Restore_failed (Session.Non_regular_file Unix.S_FIFO) -> true
    | Session.Restore_failed (Session.Non_regular_file
        (Unix.S_REG | Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_SOCK)
      | Session.Read_failed _ | Session.Json_failed _ | Session.Shape_rejected)
    | Session.Restore_unobserved | Session.Restore_unsettled -> false);
  check bool "earlier readiness does not authorize replacing a new FIFO" true ((Unix.lstat path).Unix.st_kind = Unix.S_FIFO);
  check_original sid

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
    save ~base_path ();
    let json = Yojson.Basic.from_file path in
    Yojson.Basic.Util.(json |> member "sessions" |> member sid) in
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

let test_failed_restore_preserves_original () =
  List.iter (fun (original,expected_failure) -> with_temp_base @@ fun base_path ->
    let sid = "persist-live-after-bad-snapshot" in
    with_sessions [sid] @@ fun () ->
    let path = Session.sessions_file_path ~base_path () in
    Unix.mkdir (Filename.dirname path) 0o700;
    Out_channel.with_open_bin path (fun output -> output_string output original);
    Session.load_sessions_from_file ~base_path ();
    remember sid;
    check_original sid;
    ignore (Session.reap_stale_sessions ~base_path ~is_active_session:(fun _ -> true));
    skipped ~base_path (function
      | Session.Restore_failed failure -> expected_failure failure
      | Session.Restore_unobserved | Session.Restore_unsettled -> false);
    check string "failed restore survives actual maintenance and direct save" original
      (In_channel.with_open_bin path In_channel.input_all);
    check bool "refused save never opens a temporary output" false
      (Sys.file_exists (path ^ ".tmp"));
    check_original sid)
    ["{unclosed",(function Session.Json_failed _ -> true | Session.Read_failed _ | Session.Shape_rejected | Session.Non_regular_file _ -> false);
     "{\"not_sessions\":{}}",(function Session.Shape_rejected -> true | Session.Read_failed _ | Session.Json_failed _ | Session.Non_regular_file _ -> false)]

let test_read_failure_is_path_local_and_latched () = with_temp_base @@ fun damaged ->
  with_temp_base @@ fun independent ->
  let path = Session.sessions_file_path ~base_path:damaged () in
  let directory = Filename.dirname path in
  (* A parent symlink loop is a real lookup failure, without using a
     nonregular snapshot as if it were supported input. *)
  Unix.symlink (Filename.basename directory) directory;
  Session.load_sessions_from_file ~base_path:damaged ();
  Unix.unlink directory;
  Unix.mkdir directory 0o700;
  let original = "{\"sessions\":{}}\n" in
  Out_channel.with_open_bin path (fun output -> output_string output original);
  let sid = "persist-independent-after-refusal" in
  with_sessions [sid] @@ fun () ->
  remember sid;
  Session.load_sessions_from_file ~base_path:independent ();
  save ~base_path:independent ();
  let peer_path = Session.sessions_file_path ~base_path:independent () in
  check bool "independent missing path persists the live session" true
    Yojson.Basic.Util.(Yojson.Basic.from_file peer_path |> member "sessions" |> member sid <> `Null);
  Session.load_sessions_from_file ~base_path:damaged ();
  let original_refusal = function
    | Session.Restore_failed (Session.Read_failed _) -> true
    | Session.Restore_failed (Session.Json_failed _ | Session.Shape_rejected | Session.Non_regular_file _)
    | Session.Restore_unobserved | Session.Restore_unsettled -> false in
  skipped ~base_path:damaged original_refusal;
  check string "later readable replacement cannot clear this process refusal" original
    (In_channel.with_open_bin path In_channel.input_all);
  (* A later failed read must not replace the first refusal's cause. *)
  let later = "{later-invalid-json" in
  Out_channel.with_open_bin path (fun output -> output_string output later);
  Session.load_sessions_from_file ~base_path:damaged ();
  skipped ~base_path:damaged original_refusal;
  check string "later failure retains its original bytes and original refusal" later
    (In_channel.with_open_bin path In_channel.input_all);
  check_original sid

let test_save_before_restore_preserves_existing () = with_temp_base @@ fun base_path ->
  let path = Session.sessions_file_path ~base_path () in
  Unix.mkdir (Filename.dirname path) 0o700;
  let sid = "persist-unrestored-original" in
  with_sessions [sid] @@ fun () ->
  let original = session_bytes sid in
  Out_channel.with_open_bin path (fun output -> output_string output original);
  skipped ~base_path (function
    | Session.Restore_unobserved -> true
    | Session.Restore_unsettled | Session.Restore_failed _ -> false);
  check string "save-first preserves an existing original" original
    (In_channel.with_open_bin path In_channel.input_all);
  Session.load_sessions_from_file ~base_path ();
  check_original sid;
  Session.forget_mcp_session sid;
  save ~base_path ();
  let json = Yojson.Basic.from_file path in
  check bool "successful restore permits later session removal to persist" true
    Yojson.Basic.Util.(json |> member "sessions" |> member sid = `Null)

let test_failed_write_can_retry_after_resource_release () = with_temp_base @@ fun base_path ->
  let sid = "persist-write-error-live" in
  with_sessions [sid] @@ fun () ->
  let path = Session.sessions_file_path ~base_path () in
  Session.load_sessions_from_file ~base_path ();
  let directory = Filename.dirname path in
  Unix.symlink (Filename.concat base_path "absent-session-directory") directory;
  remember sid;
  (match Session.save_sessions_to_file ~base_path () with
   | Session.Save_failed _ -> ()
   | Session.Saved -> fail "blocked actual output was reported as replaced"
   | Session.Skipped _ -> fail "write error was confused with a restore refusal");
  check bool "failed write did not create a completed snapshot" false (Sys.file_exists path);
  check_original sid;
  Unix.unlink directory;
  Unix.mkdir directory 0o700;
  save ~base_path ();
  Session.forget_mcp_session sid;
  Session.load_sessions_from_file ~base_path ();
  check_original sid

let initialize_body version =
  Yojson.Basic.to_string (`Assoc
    ["jsonrpc",`String "2.0";"id",`Int 1;"method",`String "initialize";
     "params",`Assoc ["protocolVersion",`String version]])

let initialize_response =
  `Assoc ["jsonrpc",`String "2.0";"id",`Int 1;"result",`Assoc []]

let saved_session ~base_path sid =
  save ~base_path ();
  let path = Session.sessions_file_path ~base_path () in
  let json = Yojson.Basic.from_file path in
  Yojson.Basic.Util.(json |> member "sessions" |> member sid)

let test_initialize_profile_lifecycle () = with_temp_base @@ fun base_path ->
  let sid = "persist-initialize-lifecycle" in
  with_sessions [sid] @@ fun () ->
  let profile = Server_mcp_transport_http_types.Seat in
  let version = Session.mcp_protocol_version_default in
  let first = Otel_dispatch_hook.http_transport_context ~protocol_version:"1.1" in
  let second = Otel_dispatch_hook.http_transport_context ~protocol_version:"2" in
  Session.remember_mcp_profile ~otel_transport_context:first sid profile;
  check bool "profile alone grants no initialize authority" false (Session.is_known_session sid);
  (match Session.validate_mcp_session_profile ~profile sid with
   | Ok () -> () | Error detail -> fail detail);
  (match Session.validate_mcp_session_delete_profile ~profile sid with
   | Ok () -> () | Error detail -> fail detail);
  (match Session.validate_mcp_session_delete_profile
      ~profile:Server_mcp_transport_http_types.Operator_remote sid with
   | Error _ -> () | Ok () -> fail "profile-only seat crossed its narrow door");
  check bool "profile-only session is absent from actual snapshot" true
    (saved_session ~base_path sid = `Null);
  Session.remember_protocol_version_if_initialize_succeeded ~otel_transport_context:first sid
    ~request_body:(initialize_body version)
    ~response_json:(`Assoc ["jsonrpc",`String "2.0";"id",`Int 1;
      "error",`Assoc ["code",`Int (-32602);"message",`String "Rejected initialize"]]);
  check bool "rejected initialize remains unknown" false (Session.is_known_session sid);
  check bool "rejected initialize remains absent from actual snapshot" true
    (saved_session ~base_path sid = `Null);
  Session.remember_protocol_version_if_initialize_succeeded ~otel_transport_context:first sid
    ~request_body:(initialize_body version) ~response_json:initialize_response;
  check bool "accepted initialize grants known-session authority" true (Session.is_known_session sid);
  let row = saved_session ~base_path sid in
  let open Yojson.Basic.Util in
  check string "accepted wire version persisted" version (row |> member "protocol_version" |> to_string);
  check string "pre-initialize seat profile retained" "seat" (row |> member "profile" |> to_string);
  let started = row |> member "started_at" |> to_float in
  check bool "initialized session has a real start time, not missing-field zero" true (started > 0.0);
  check bool "initialized session has real activity" true (row |> member "last_active_sse" |> to_float > 0.0);
  check string "initialize transport accompanies the accepted version" "1.1"
    (row |> member "network_protocol_version" |> to_string);
  Session.remember_mcp_profile ~otel_transport_context:second sid profile;
  let refreshed = saved_session ~base_path sid in
  check (float 0.0) "profile refresh retains the first start time" started
    (refreshed |> member "started_at" |> to_float);
  check string "known profile refresh publishes its current transport" "2"
    (refreshed |> member "network_protocol_version" |> to_string);
  Session.forget_mcp_session sid;
  check bool "forgotten session leaves the actual snapshot" true (saved_session ~base_path sid = `Null);
  Session.remember_protocol_version sid version;
  (match Session.validate_mcp_session_profile ~profile sid with
   | Ok () -> () | Error detail -> fail detail);
  (match Session.validate_mcp_session_delete_profile ~profile sid with
   | Error _ -> () | Ok () -> fail "re-registration inherited the deleted seat profile");
  let recreated = saved_session ~base_path sid in
  List.iter (fun key -> check bool "re-registration inherits no old transport labels" true
      (recreated |> member key = `Null))
    ["network_protocol_name";"network_protocol_version";"network_transport"];
  Session.remember_mcp_profile sid Server_mcp_transport_http_types.Operator_remote;
  save ~base_path ();
  Session.forget_mcp_session sid;
  Session.load_sessions_from_file ~base_path ();
  check_original sid

let test_registration_and_actual_snapshot_coherence () = with_temp_base @@ fun base_path ->
  let sid = "persist-domain-initialize" and peer = "persist-domain-peer" in
  with_sessions [sid;peer] @@ fun () ->
  remember peer;
  let first_version = Session.mcp_protocol_version_default in
  let second_version = match List.find_opt ((<>) first_version) Session.mcp_protocol_versions with
    | Some version -> version
    | None -> fail "session transition scenario requires two supported versions" in
  let finished = Atomic.make false in
  let writer = Domain.spawn (fun () ->
    Fun.protect ~finally:(fun () -> Atomic.set finished true) (fun () ->
      Session.remember_mcp_profile sid Server_mcp_transport_http_types.Operator_remote;
      let first = Otel_dispatch_hook.http_transport_context ~protocol_version:"1.1" in
      Session.remember_protocol_version_if_initialize_succeeded ~otel_transport_context:first sid
        ~request_body:(initialize_body first_version) ~response_json:initialize_response;
      let second = Otel_dispatch_hook.http_transport_context ~protocol_version:"2" in
      Session.remember_protocol_version ~otel_transport_context:second sid second_version)) in
  let inspect () =
    let row = saved_session ~base_path sid in
    match row with
    | `Null -> () (* A save may capture the valid pre-initialize state. *)
    | row ->
        let open Yojson.Basic.Util in
        let version = row |> member "protocol_version" |> to_string in
        let network = row |> member "network_protocol_version" |> to_string in
        check bool "saved protocol and transport belong to one registration"
          true ((version = first_version && network = "1.1")
            || (version = second_version && network = "2"));
        check string "profile prepared before initialize is retained" "operator_remote"
          (row |> member "profile" |> to_string);
        check bool "published known session has its activity" true
          (row |> member "last_active_sse" |> to_float > 0.0);
        check bool "published known session has its start time" true
          (row |> member "started_at" |> to_float > 0.0) in
  (* The producer owns no Eio/native resource. Join exactly once even if an
     actual save/inspection fails. No stress count, timer or overlap assertion. *)
  Fun.protect ~finally:(fun () -> Domain.join writer) (fun () ->
    while not (Atomic.get finished) do inspect () done);
  inspect ();
  let final = saved_session ~base_path sid in
  check string "completed registration persists its final version" second_version
    Yojson.Basic.Util.(final |> member "protocol_version" |> to_string);
  List.iter Session.forget_mcp_session [sid;peer];
  Session.load_sessions_from_file ~base_path ();
  check_original sid;
  check_original peer

let test_shared_writer_failure_preserves_resources_and_recovers () = with_temp_base @@ fun base_path ->
  let target = Filename.concat base_path "occupied-publication" in
  Unix.mkdir target 0o700;
  let marker = Filename.concat target "retained-evidence" in
  let bytes = "original directory contents" and payload = "snapshot\000bytes\n한글\n" in
  Out_channel.with_open_bin marker (fun output -> output_string output bytes);
  let unrelated = Filename.concat base_path ".atomic_unrelated.tmp" in
  Unix.mkfifo unrelated 0o600;
  (match Fs_compat.save_file_atomic_rename_only_staged target payload with
   | Ok () -> fail "actual directory collision was reported as publication"
   | Error failure ->
       (match failure.stage with
        | Fs_compat.Before_rename -> ()
        | Fs_compat.After_rename -> fail "directory collision was reported after publication");
       (match failure.exception_ with
        | Sys_error _ | Unix.Unix_error _ -> ()
        | exn -> raise exn));
  check string "failed publication retains actual destination contents" bytes
    (In_channel.with_open_bin marker In_channel.input_all);
  check bool "unowned canonical FIFO is never opened or removed" true
    ((Unix.lstat unrelated).Unix.st_kind = Unix.S_FIFO);
  check bool "failed real write leaves no owned temporary output" true
    (Array.for_all (fun name -> name = Filename.basename target || name = Filename.basename unrelated)
      (Sys.readdir base_path));
  Unix.unlink marker;
  Unix.rmdir target;
  (match Fs_compat.save_file_atomic_rename_only_staged target payload with
   | Ok () -> ()
   | Error failure -> Printexc.raise_with_backtrace failure.exception_ failure.backtrace);
  check string "released destination receives exact binary payload" payload
    (In_channel.with_open_bin target In_channel.input_all);
  check bool "successful retry leaves no owned temporary output" true
    (Array.for_all (fun name -> name = Filename.basename target || name = Filename.basename unrelated)
      (Sys.readdir base_path))

let () =
  run "server_mcp_session_persist"
    ["persistence",
      [test_case "shared writer preserves occupied destination and retries after release" `Quick
         test_shared_writer_failure_preserves_resources_and_recovers;
       test_case "initialize, profile, persistence and re-registration retain authority" `Quick
         test_initialize_profile_lifecycle;
       test_case "native registration and real snapshots retain coherent session fields" `Quick
         test_registration_and_actual_snapshot_coherence;
       test_case "save/forget/load retains original session and profile" `Quick test_roundtrip;
       test_case "concurrent regular outputs leave a preexisting FIFO untouched" `Quick
         test_concurrent_writers_leave_existing_fifo;
       test_case "cancelled caller cannot admit or apply a regular snapshot" `Quick
         test_cancelled_restore_does_not_admit_or_apply;
       test_case "private output never follows a preexisting temporary symlink" `Quick
         test_preexisting_temporary_symlink_is_untouched;
       test_case "FIFO snapshot is refused without a writer" `Quick
         (test_nonregular_snapshot Unix.S_FIFO (fun path -> Unix.mkfifo path 0o600; fun () -> ()));
       test_case "directory snapshot preserves child evidence" `Quick
         (test_nonregular_snapshot Unix.S_DIR (fun path ->
           Unix.mkdir path 0o700;
           let child = Filename.concat path "retained-evidence" in
           let bytes = "original directory evidence" in
           Out_channel.with_open_bin child (fun output -> output_string output bytes);
           fun () -> check string "original directory child survives" bytes (In_channel.with_open_bin child In_channel.input_all)));
       test_case "snapshot symlink is refused without changing its target" `Quick
         (test_nonregular_snapshot Unix.S_LNK (fun path ->
           let target = path ^ ".target" in
           let bytes = session_bytes "persist-unread-symlink-target" in
           Out_channel.with_open_bin target (fun output -> output_string output bytes);
           Unix.symlink target path;
           fun () ->
             check string "original symlink target survives" bytes (In_channel.with_open_bin target In_channel.input_all);
             check bool "symlink target grants no initialize authority" false (Session.is_known_session "persist-unread-symlink-target")));
       test_case "ready path changed to FIFO is preserved" `Quick
         test_ready_destination_changed_to_fifo_is_preserved;
       test_case "actual overlays retain duplicate and optional-field authority" `Quick
         test_overlay_preserves_original_field_policies;
       test_case "failed JSON and root restore preserve actual snapshots" `Quick
         test_failed_restore_preserves_original;
       test_case "read refusal stays with its path and process" `Quick
         test_read_failure_is_path_local_and_latched;
       test_case "save-first preserves an existing unrestored file" `Quick
         test_save_before_restore_preserves_existing;
       test_case "actual write failure remains distinct and retries after resource release" `Quick
         test_failed_write_can_retry_after_resource_release]]
