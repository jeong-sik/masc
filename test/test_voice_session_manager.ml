open Alcotest

module Manager = Masc.Voice_session_manager

let temp_dir () =
  let path = Filename.temp_file "test_voice_session_manager_" "" in
  Unix.unlink path;
  Unix.mkdir path 0o755;
  path

let cleanup_dir root =
  let rec remove path =
    if Sys.file_exists path
    then
      if Sys.is_directory path
      then (
        Array.iter
          (fun name -> remove (Filename.concat path name))
          (Sys.readdir path);
        Unix.rmdir path)
      else Unix.unlink path
  in
  try remove root with _ -> ()

let with_manager f =
  let config_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir config_path)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      f config_path (Manager.create ~config_path))

let session_field_int session key =
  match Json_util.get_int (Manager.session_to_json session) key with
  | Some value -> value
  | None -> failf "session JSON is missing integer field %s" key

let require_session manager agent_id =
  match Manager.get_session manager ~agent_id with
  | Some session -> session
  | None -> failf "missing session for %s" agent_id

let test_returned_session_is_immutable_snapshot () =
  with_manager (fun _config_path manager ->
    let before =
      Manager.start_session manager ~agent_id:"snapshot" ~voice:"test" ()
    in
    Manager.increment_turn manager ~agent_id:"snapshot";
    let after = require_session manager "snapshot" in
    check int "prior snapshot stays unchanged" 0 (session_field_int before "turn_count");
    check int "published snapshot advances" 1 (session_field_int after "turn_count"))

let test_concurrent_updates_publish_without_loss () =
  with_manager (fun _config_path manager ->
    ignore
      (Manager.start_session manager ~agent_id:"concurrent" ~voice:"test" ());
    let fiber_count = 4 in
    let increments_per_fiber = 10 in
    Eio.Fiber.all
      (List.init fiber_count (fun _ () ->
         for _ = 1 to increments_per_fiber do
           Manager.increment_turn manager ~agent_id:"concurrent"
         done));
    let session = require_session manager "concurrent" in
    check
      int
      "every serialized transition is retained"
      (fiber_count * increments_per_fiber)
      (session_field_int session "turn_count");
    check int "one agent has one session" 1 (Manager.session_count manager))

let test_domain_updates_publish_without_loss () =
  with_manager (fun _config_path manager ->
    ignore (Manager.start_session manager ~agent_id:"domains" ~voice:"test" ());
    let domain_count = 4 in
    let increments_per_domain = 5 in
    let ready = Atomic.make 0 in
    let start = Atomic.make false in
    let workers =
      List.init domain_count (fun _ ->
        Domain.spawn (fun () ->
          Atomic.incr ready;
          while not (Atomic.get start) do
            Domain.cpu_relax ()
          done;
          for _ = 1 to increments_per_domain do
            Manager.increment_turn manager ~agent_id:"domains"
          done))
    in
    while Atomic.get ready < domain_count do
      Domain.cpu_relax ()
    done;
    Atomic.set start true;
    List.iter Domain.join workers;
    let session = require_session manager "domains" in
    check
      int
      "every cross-domain transition is retained"
      (domain_count * increments_per_domain)
      (session_field_int session "turn_count"))

let test_restore_publishes_one_complete_snapshot () =
  with_manager (fun config_path manager ->
    ignore
      (Manager.start_session manager ~agent_id:"restored" ~voice:"test" ());
    Manager.increment_turn manager ~agent_id:"restored";
    let restored = Manager.create ~config_path in
    Manager.restore restored;
    let session = require_session restored "restored" in
    check int "restored session count" 1 (Manager.session_count restored);
    check int "restored turn count" 1 (session_field_int session "turn_count"))

let write_session_file config_path agent_id body =
  let dir = Filename.concat config_path "voice_sessions" in
  if not (Sys.file_exists dir) then Unix.mkdir dir 0o755;
  let oc = open_out (Filename.concat dir (agent_id ^ ".json")) in
  output_string oc body;
  close_out oc

let session_status_string session =
  match Json_util.get_string (Manager.session_to_json session) "status" with
  | Some s -> s
  | None -> fail "session JSON is missing status"

let with_bridge_env value f =
  let original = Sys.getenv_opt Manager.realtime_bridge_env in
  Unix.putenv Manager.realtime_bridge_env value;
  Fun.protect
    ~finally:(fun () ->
      match original with
      | Some v -> Unix.putenv Manager.realtime_bridge_env v
      | None -> Unix.unsetenv Manager.realtime_bridge_env)
    f

let session_string session key =
  match Json_util.get_string (Manager.session_to_json session) key with
  | Some s -> s
  | None -> fail ("session JSON is missing " ^ key)

let session_float session key =
  match Json_util.get_float (Manager.session_to_json session) key with
  | Some value -> value
  | None -> fail ("session JSON is missing float " ^ key)

let check_session_identity expected actual =
  List.iter (fun key ->
    check string (key ^ " preserved")
      (session_string expected key) (session_string actual key))
    ["session_id"; "agent_id"; "voice"];
  check (float 0.) "start time preserved"
    (session_float expected "started_at") (session_float actual "started_at")

let check_endpoint_redacted json =
  check bool "top-level endpoint is null" true
    (Json_util.assoc_member_opt "realtime_bridge_endpoint" json = Some `Null);
  let check_bridge container =
    match Json_util.get_object container "realtime_bridge" with
    | None -> fail "missing bridge metadata"
    | Some bridge ->
      check bool "nested endpoint is null" true
        (Json_util.assoc_member_opt "endpoint" bridge = Some `Null) in
  check_bridge json;
  match Json_util.get_object json "voice_loop" with
  | None -> fail "missing voice loop"
  | Some loop -> check_bridge loop

let test_realtime_intent_survives_lost_bridge () =
  with_manager (fun config_path _manager ->
    write_session_file
      config_path
      "rt"
      {|{"session_id":" vs-1 ","agent_id":"rt","voice":"v","started_at":1.0,"last_activity":2.0,"turn_count":3,"status":"active","conversation_mode":"realtime_bridge"}|};
    with_bridge_env "" (fun () ->
      let restored = Manager.create ~config_path in
      Manager.restore restored;
      let session = require_session restored "rt" in
      check string "lost bridge is not a live session" "suspended"
        (session_status_string session);
      check string "desired mode kept" "realtime_bridge"
        (session_string session "conversation_mode");
      check bool "realtime not supported while unavailable" false
        (Manager.realtime_supported (Manager.session_conversation_mode session));
      check int "turn history kept" 3 (session_field_int session "turn_count");
      check string "valid ID bytes kept" " vs-1 " (session_string session "session_id");
      check string "voice kept" "v" (session_string session "voice");
      check string "agent kept" "rt" (session_string session "agent_id");
      (* persist again while the bridge is still missing *)
      Manager.increment_turn restored ~agent_id:"rt";
      let again = Manager.create ~config_path in
      Manager.restore again;
      let persisted = require_session again "rt" in
      check_session_identity session persisted;
      check string "still suspended after persist" "suspended"
        (session_status_string persisted);
      check string "mode survives persist" "realtime_bridge"
        (session_string persisted "conversation_mode"));
    with_bridge_env "ws://127.0.0.1:9/bridge" (fun () ->
      let recovered = Manager.create ~config_path in
      Manager.restore recovered;
      let session = require_session recovered "rt" in
      check string "id bytes kept after endpoint configuration" " vs-1 "
        (session_string session "session_id");
      check string "voice kept after endpoint configuration" "v" (session_string session "voice");
      check string "agent kept after endpoint configuration" "rt" (session_string session "agent_id");
      check string "configuration alone does not reactivate session" "suspended"
        (session_status_string session);
      check bool "configured transport supported, not connection health" true
        (Manager.realtime_supported (Manager.session_conversation_mode session));
      check int "turn count kept" 4 (session_field_int session "turn_count");
      let endpoint = "ws://127.0.0.1:9/bridge" in
      let activated = Manager.start_session recovered ~agent_id:"rt"
        ~conversation_mode:(Manager.Realtime_bridge {endpoint}) () in
      check_session_identity session activated;
      check string "explicit start activates local session" "active"
        (session_status_string activated);
      check_endpoint_redacted (Manager.session_to_json activated);
      let persisted = Fs_compat.load_file
        (Filename.concat (Filename.concat config_path "voice_sessions") "rt.json")
        |> Yojson.Safe.from_string in
      check_endpoint_redacted persisted))

let test_restore_rejects_blank_or_foreign_identity () =
  with_manager (fun config_path _manager ->
    write_session_file config_path "blank"
      {|{"session_id":"","agent_id":"blank","status":"active","conversation_mode":"turn_based"}|};
    write_session_file config_path "whitespace"
      {|{"session_id":" \t\r\n ","agent_id":"whitespace","status":"active","conversation_mode":"turn_based"}|};
    write_session_file config_path "alice"
      {|{"session_id":"vs-2","agent_id":"bob","status":"active","conversation_mode":"turn_based"}|};
    let restored = Manager.create ~config_path in
    Manager.restore restored;
    check int "no session accepted" 0 (Manager.session_count restored))

let test_unavailable_start_suspends_new_and_existing_sessions () =
  with_manager (fun config_path manager ->
    with_bridge_env "" (fun () ->
      let fresh = Manager.start_session manager ~agent_id:"new" ~voice:"new-voice"
        ~conversation_mode:Manager.Realtime_unavailable () in
      check string "fresh unavailable session suspended" "suspended"
        (session_status_string fresh);
      let existing = Manager.start_session manager ~agent_id:"existing" ~voice:"original" () in
      Manager.increment_turn manager ~agent_id:"existing";
      let suspended = Manager.start_session manager ~agent_id:"existing" ~voice:"replacement"
        ~conversation_mode:Manager.Realtime_unavailable () in
      check_session_identity existing suspended;
      check string "existing unavailable session suspended" "suspended"
        (session_status_string suspended);
      check int "existing turn count kept" 1 (session_field_int suspended "turn_count");
      let restored = Manager.create ~config_path in
      Manager.restore restored;
      List.iter (fun (agent_id, before) ->
        let after = require_session restored agent_id in
        check_session_identity before after;
        check int "persisted turn count" (session_field_int before "turn_count")
          (session_field_int after "turn_count");
        check string "persisted suspended status" "suspended" (session_status_string after);
        check string "persisted realtime intent" "realtime_bridge"
          (session_string after "conversation_mode")) ["new", fresh; "existing", suspended];
      let loop = Manager.voice_loop_json ~session_active:true Manager.Realtime_unavailable in
      check (option bool) "unavailable loop cannot advertise activity" (Some false)
        (Json_util.get_bool loop "session_active")))

let test_restore_rejects_unknown_conversation_mode () =
  with_manager (fun config_path _manager ->
    let modes = [None; Some (`String "unknown"); Some (`String "");
      Some (`String " turn_based "); Some `Null; Some (`Int 1)] in
    List.iteri (fun index mode ->
      let agent_id = "invalid-" ^ string_of_int index in
      let fields = ["session_id", `String "vs-invalid"; "agent_id", `String agent_id;
        "status", `String "active"] in
      let fields = match mode with None -> fields | Some mode -> ("conversation_mode", mode)::fields in
      write_session_file config_path agent_id (Yojson.Safe.to_string (`Assoc fields))) modes;
    write_session_file config_path "valid"
      {|{"session_id":"vs-valid","agent_id":"valid","status":"active","conversation_mode":"turn_based"}|};
    let restored = Manager.create ~config_path in
    Manager.restore restored;
    check int "only known mode accepted" 1 (Manager.session_count restored);
    check string "valid control stays turn-based" "turn_based"
      (session_string (require_session restored "valid") "conversation_mode"))

let () =
  run
    "Voice_session_manager"
    [
      ( "immutable state",
        [
          test_case
            "returned session is a snapshot"
            `Quick
            test_returned_session_is_immutable_snapshot;
          test_case
            "concurrent increments are retained"
            `Quick
            test_concurrent_updates_publish_without_loss;
          test_case
            "cross-domain increments are retained"
            `Quick
            test_domain_updates_publish_without_loss;
          test_case
            "restore publishes complete snapshot"
            `Quick
            test_restore_publishes_one_complete_snapshot;
          test_case
            "realtime intent survives lost bridge"
            `Quick
            test_realtime_intent_survives_lost_bridge;
          test_case
            "restore rejects blank or foreign identity"
            `Quick
            test_restore_rejects_blank_or_foreign_identity;
          test_case
            "unavailable start suspends new and existing sessions"
            `Quick
            test_unavailable_start_suspends_new_and_existing_sessions;
          test_case
            "restore rejects unknown conversation mode"
            `Quick
            test_restore_rejects_unknown_conversation_mode;
        ] );
    ]
