open Alcotest
open Masc

let temp_dir () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "test_board_inference_%d" (Random.int 1_000_000))
  in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path |> Array.iter (fun name -> rm (Filename.concat path name));
        Unix.rmdir path
      end
      else Sys.remove path
  in
  rm dir

let with_workspace f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let config = Workspace.default_config dir in
      ignore (Workspace.init config ~agent_name:(Some "keeper-alpha-agent"));
      f config)

let make_meta name : Keeper_meta_contract.keeper_meta =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [
          ("name", `String name);
          ("trace_id", `String ("trace-" ^ name));
          ("autoboot_enabled", `Bool false);
        ])
  with
  | Ok meta -> meta
  | Error err -> fail ("meta_of_json failed: " ^ err)

let post_id_of_string s =
  match Board.Post_id.of_string s with
  | Ok id -> id
  | Error _ -> Alcotest.failf "failed to parse post_id %S" s

let agent_id_of_string s =
  match Board.Agent_id.of_string s with
  | Ok id -> id
  | Error _ -> Alcotest.failf "failed to parse agent_id %S" s

let make_post ~id ~author =
  { Board.id = post_id_of_string id;
    author = agent_id_of_string author;
    title = "Test post";
    body = "Test body";
    content = "Test content";
    post_kind = Board.Human_post;
    meta_json = None;
    visibility = Board.Internal;
    created_at = Unix.gettimeofday ();
    updated_at = Unix.gettimeofday ();
    expires_at = Unix.gettimeofday () +. 3600.0;
    votes_up = 0;
    votes_down = 0;
    reply_count = 0;
    pinned = false;
    hearth = None;
    thread_id = None;
    origin = None;
  }

let check_bad_request label expected = function
  | Error (`Bad_request msg) -> check string label expected msg
  | Error (`Internal_server_error msg) ->
    fail (Printf.sprintf "expected Bad_request, got Internal_server_error: %s" msg)
  | Ok _ -> fail "expected Bad_request error"

let test_parse_request () =
  (* 1. Valid payload *)
  let json = `Assoc [("post_id", `String "post-123"); ("target_keeper", `String "alpha")] in
  (match Server_routes_http_routes_activity.parse_board_context_inference_request json with
   | Ok req ->
     check string "post_id parsed" "post-123" req.post_id;
     check (option string) "target_keeper parsed" (Some "alpha") req.target_keeper
   | Error err -> fail ("parse failed: " ^ err));

  (* 2. Missing post_id *)
  let json = `Assoc [("target_keeper", `String "alpha")] in
  (match Server_routes_http_routes_activity.parse_board_context_inference_request json with
   | Error err -> check string "error on missing post_id" "post_id is required" err
   | Ok _ -> fail "expected parsing error");

  (* 3. Whitespace target_keeper *)
  let json = `Assoc [("post_id", `String "post-123"); ("target_keeper", `String "  ")] in
  (match Server_routes_http_routes_activity.parse_board_context_inference_request json with
   | Ok req ->
     check string "post_id parsed" "post-123" req.post_id;
     check (option string) "target_keeper parsed as None" None req.target_keeper
   | Error err -> fail ("parse failed: " ^ err))

let test_target_resolution_explicit_registered () =
  with_workspace (fun config ->
    (* Register keeper "alpha" *)
    (match Keeper_meta_store.replace_snapshot config (make_meta "alpha") with
     | Ok _ -> ()
     | Error msg -> fail ("write_meta failed: " ^ msg));

    let post = make_post ~id:"post-1" ~author:"operator" in
    match Server_routes_http_routes_activity.resolve_board_context_inference_target ~config post (Some "alpha") with
    | Ok (resolved_name, source) ->
      check string "resolved name" "alpha" resolved_name;
      check bool "source is Explicit_target" true (source = Server_routes_http_routes_activity.Explicit_target)
    | Error _ -> fail "expected resolution to succeed")

let test_target_resolution_explicit_unregistered () =
  with_workspace (fun config ->
    let post = make_post ~id:"post-1" ~author:"operator" in
    Server_routes_http_routes_activity.resolve_board_context_inference_target
      ~config post (Some "chulsoo")
    |> check_bad_request
         "error message"
         "target_keeper \"chulsoo\" is not a registered keeper")

let test_target_resolution_implicit_registered_author () =
  with_workspace (fun config ->
    (* Register keeper "alpha" *)
    (match Keeper_meta_store.replace_snapshot config (make_meta "alpha") with
     | Ok _ -> ()
     | Error msg -> fail ("write_meta failed: " ^ msg));

    (* Post author matches a registered keeper (either by short name or full agent name) *)
    let post = make_post ~id:"post-1" ~author:"alpha" in
    match Server_routes_http_routes_activity.resolve_board_context_inference_target ~config post None with
    | Ok (resolved_name, source) ->
      check string "resolved name" "alpha" resolved_name;
      check bool "source is Post_author" true (source = Server_routes_http_routes_activity.Post_author)
    | Error _ -> fail "expected resolution to succeed")

let test_target_resolution_implicit_unregistered_author () =
  with_workspace (fun config ->
    (* Post author is "operator", which is not a registered keeper *)
    let post = make_post ~id:"post-1" ~author:"operator" in
    Server_routes_http_routes_activity.resolve_board_context_inference_target
      ~config post None
    |> check_bad_request
         "error message"
         "target_keeper is required because board post author \"operator\" is not a registered keeper")

let expect_runtime_param_request_error ~label decode body expected =
  match decode body with
  | Error error ->
    check string label expected
      (Server_runtime_param_request.error_message error)
  | Ok _ -> fail (Printf.sprintf "accepted invalid runtime-param request: %s" body)

let test_runtime_param_request_admission () =
  (match
     Server_runtime_param_request.decode_set
       {|{"param_key":"keeper.max_turns","value":12}|}
   with
   | Ok request ->
     check string "set key" "keeper.max_turns"
       (Server_runtime_param_request.set_param_key request);
     check bool "set value" true
       (Yojson.Safe.equal (`Int 12)
          (Server_runtime_param_request.set_value request))
   | Error error -> fail (Server_runtime_param_request.error_message error));
  (match
     Server_runtime_param_request.decode_clear
       {|{"param_key":"keeper.max_turns"}|}
   with
   | Ok request ->
     check string "clear key" "keeper.max_turns"
       (Server_runtime_param_request.clear_param_key request)
   | Error error -> fail (Server_runtime_param_request.error_message error));
  (match
     Server_runtime_param_request.decode_set
       {|{"param_key":"feature.flag","value":null}|}
   with
   | Ok request ->
     check bool "explicit null remains a present value" true
       (Yojson.Safe.equal `Null
          (Server_runtime_param_request.set_value request))
   | Error error -> fail (Server_runtime_param_request.error_message error));
  List.iter
    (fun (label, decode, body, expected) ->
       expect_runtime_param_request_error ~label decode body expected)
    [ ( "object required"
      , Server_runtime_param_request.decode_set
      , "[]"
      , "request body must be an object" )
    ; ( "key required"
      , Server_runtime_param_request.decode_set
      , {|{"value":1}|}
      , "param_key is required" )
    ; ( "key type"
      , Server_runtime_param_request.decode_set
      , {|{"param_key":1,"value":1}|}
      , "param_key must be a string" )
    ; ( "blank key"
      , Server_runtime_param_request.decode_set
      , {|{"param_key":"  ","value":1}|}
      , "param_key is required" )
    ; ( "duplicate key"
      , Server_runtime_param_request.decode_set
      , {|{"param_key":"a","param_key":"b","value":1}|}
      , "duplicate param_key field" )
    ; ( "value required"
      , Server_runtime_param_request.decode_set
      , {|{"param_key":"keeper.max_turns"}|}
      , "value is required" )
    ; ( "duplicate value"
      , Server_runtime_param_request.decode_set
      , {|{"param_key":"keeper.max_turns","value":1,"value":2}|}
      , "duplicate value field" )
    ];
  expect_runtime_param_request_error
    ~label:"canonical clear key"
    Server_runtime_param_request.decode_clear
    {|{"param_key":" keeper.max_turns "}|}
    "param_key must not contain surrounding whitespace";
  match Server_runtime_param_request.decode_clear "{" with
  | Error error ->
    let message = Server_runtime_param_request.error_message error in
    check bool "malformed JSON is classified" true
      (String.starts_with ~prefix:"Invalid JSON:" message)
  | Ok _ -> fail "accepted malformed runtime-param request"

let test_cadence_change_wakes_only_live_sleepers_when_shortened () =
  let base_path = "/tmp/test_runtime_param_keeper_wakeup" in
  Keeper_registry.For_testing.clear ();
  Fun.protect
    ~finally:(fun () -> Keeper_registry.For_testing.clear ())
    (fun () ->
      let first =
        Keeper_registry.For_testing.register ~base_path "first" (make_meta "first")
      in
      let second =
        Keeper_registry.For_testing.register ~base_path "second" (make_meta "second")
      in
      let second = { second with phase = Keeper_state_machine.Failing } in
      Keeper_registry.For_testing.unsafe_put_entry ~base_path "second" second;
      let in_flight =
        Keeper_registry.For_testing.register
          ~base_path
          "in-flight"
          (make_meta "in-flight")
      in
      let awake =
        Keeper_registry.For_testing.register
          ~base_path
          "awake-pre-turn"
          (make_meta "awake-pre-turn")
      in
      Keeper_registry.mark_turn_started
        ~base_path
        ~wake:Keeper_registry.Proactive_tick
        "in-flight";
      Atomic.set first.cadence_sleeping true;
      Atomic.set second.cadence_sleeping true;
      let unrelated =
        Server_routes_http_routes_activity.wake_keepers_after_runtime_param_change
          ~base_path
          ~param_key:"keeper.max_turns"
          ~previous_interval_s:300
          ~new_interval_s:30
      in
      check bool "unrelated param has no wake effect" true
        (Option.is_none unrelated);
      check bool "unrelated param keeps first asleep" true
        (Atomic.get first.cadence_sleeping);
      check bool "unrelated param keeps second asleep" true
        (Atomic.get second.cadence_sleeping);
      let summary =
        Server_routes_http_routes_activity.wake_keepers_after_runtime_param_change
          ~base_path
          ~param_key:
            (Runtime_params.key Runtime_settings.keeper_keepalive_interval_sec)
          ~previous_interval_s:300
          ~new_interval_s:30
        |> Option.value ~default:`Null
      in
      let open Yojson.Safe.Util in
      check bool "cadence change consumes first sleeper" false
        (Atomic.get first.cadence_sleeping);
      check bool "cadence decrease consumes failing sleeper" false
        (Atomic.get second.cadence_sleeping);
      check bool "cadence decrease does not mark an active turn sleeping" false
        (Atomic.get in_flight.cadence_sleeping);
      check bool "cadence decrease does not queue during pre-turn work" false
        (Atomic.get awake.cadence_sleeping);
      check int "summary requested all live lanes" 4
        (summary |> member "requested" |> to_int);
      check int "summary signaled both sleepers" 2
        (summary |> member "signaled" |> to_int);
      check int "summary exposes in-flight deferral" 1
        (summary |> member "deferred_in_flight" |> to_int);
      check int "summary exposes awake pre-turn deferral" 1
        (summary |> member "deferred_awake" |> to_int);
      check bool "summary does not claim full delivery" false
        (summary |> member "fully_signaled" |> to_bool);
      Atomic.set first.cadence_sleeping true;
      Atomic.set second.cadence_sleeping true;
      let lengthened =
        Server_routes_http_routes_activity.wake_keepers_after_runtime_param_change
          ~base_path
          ~param_key:
            (Runtime_params.key Runtime_settings.keeper_keepalive_interval_sec)
          ~previous_interval_s:30
          ~new_interval_s:300
        |> Option.value ~default:`Null
      in
      check bool "cadence increase keeps running sleeper asleep" true
        (Atomic.get first.cadence_sleeping);
      check bool "cadence increase keeps failing sleeper asleep" true
        (Atomic.get second.cadence_sleeping);
      check int "lengthening requests no wakes" 0
        (lengthened |> member "requested" |> to_int);
      check string "lengthening is explicit" "lengthened"
        (lengthened |> member "change" |> to_string);
      let unchanged =
        Server_routes_http_routes_activity.wake_keepers_after_runtime_param_change
          ~base_path
          ~param_key:
            (Runtime_params.key Runtime_settings.keeper_keepalive_interval_sec)
          ~previous_interval_s:300
          ~new_interval_s:300
        |> Option.value ~default:`Null
      in
      check int "unchanged cadence requests no wakes" 0
        (unchanged |> member "requested" |> to_int);
      check string "unchanged cadence is explicit" "unchanged"
        (unchanged |> member "change" |> to_string))

let test_keeper_metric_producer_tracks_turn_and_failed_sleep () =
  let base_path = "/tmp/test_keeper_metric_producer_active" in
  Keeper_registry.For_testing.clear ();
  Fun.protect
    ~finally:(fun () -> Keeper_registry.For_testing.clear ())
    (fun () ->
      let entry =
        Keeper_registry.For_testing.register
          ~base_path
          "producer"
          (make_meta "producer")
      in
      check bool "idle running lane is not an active producer" false
        (Keeper_status_runtime.keeper_metric_producer_active ~base_path);
      Keeper_registry.mark_turn_started
        ~base_path
        ~wake:Keeper_registry.Proactive_tick
        entry.name;
      check bool "live turn is an active producer" true
        (Keeper_status_runtime.keeper_metric_producer_active ~base_path);
      Keeper_registry.mark_turn_finished ~base_path entry.name;
      let failed =
        Keeper_registry.get ~base_path entry.name
        |> Option.value ~default:entry
      in
      let failed = { failed with phase = Keeper_state_machine.Failing } in
      Keeper_registry.For_testing.unsafe_put_entry ~base_path entry.name failed;
      Atomic.set failed.cadence_sleeping true;
      check bool "failed inter-cycle sleep is still producing" true
        (Keeper_status_runtime.keeper_metric_producer_active ~base_path);
      Atomic.set failed.cadence_sleeping false;
      check bool "failed awake lane does not mask stale telemetry" false
        (Keeper_status_runtime.keeper_metric_producer_active ~base_path))

let test_cadence_mutation_and_wake_are_serialized () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let param_key =
    Runtime_params.key Runtime_settings.keeper_keepalive_interval_sec
  in
  let first_entered, resolve_first_entered = Eio.Promise.create () in
  let release_first, resolve_release_first = Eio.Promise.create () in
  let second_attempting, resolve_second_attempting = Eio.Promise.create () in
  let second_entered = Atomic.make false in
  let first_done, resolve_first_done = Eio.Promise.create () in
  let second_done, resolve_second_done = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    let result =
      Server_routes_http_routes_activity.mutate_runtime_param_with_effects
        ~base_path:"/tmp/test_cadence_effect_serialization"
        ~param_key
        (fun () ->
          Eio.Promise.resolve resolve_first_entered ();
          Eio.Promise.await release_first;
          Ok
            { Runtime_params.old_value = `Int 300
            ; new_value = `Int 30
            })
    in
    Eio.Promise.resolve resolve_first_done result);
  Eio.Promise.await first_entered;
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Promise.resolve resolve_second_attempting ();
    let result =
      Server_routes_http_routes_activity.mutate_runtime_param_with_effects
        ~base_path:"/tmp/test_cadence_effect_serialization"
        ~param_key
        (fun () ->
          Atomic.set second_entered true;
          Ok
            { Runtime_params.old_value = `Int 30
            ; new_value = `Int 600
            })
    in
    Eio.Promise.resolve resolve_second_done result);
  Eio.Promise.await second_attempting;
  Eio.Fiber.yield ();
  check bool "later cadence mutation waits through the earlier wake" false
    (Atomic.get second_entered);
  Eio.Promise.resolve resolve_release_first ();
  ignore (Eio.Promise.await first_done);
  ignore (Eio.Promise.await second_done);
  check bool "later cadence mutation enters after wake completion" true
    (Atomic.get second_entered)

let () =
  run "Server board context inference resolution"
    [ ( "parse_request",
        [ test_case "parse request payloads" `Quick test_parse_request ] )
    ; ( "target_resolution",
        [ test_case "explicit registered target" `Quick test_target_resolution_explicit_registered
        ; test_case "explicit unregistered target" `Quick test_target_resolution_explicit_unregistered
        ; test_case "implicit registered author" `Quick test_target_resolution_implicit_registered_author
        ; test_case "implicit unregistered author" `Quick test_target_resolution_implicit_unregistered_author
        ] )
    ; ( "runtime_params",
        [ test_case "request admission is typed and strict" `Quick
            test_runtime_param_request_admission
        ; test_case "cadence decrease wakes only live sleepers" `Quick
            test_cadence_change_wakes_only_live_sleepers_when_shortened
        ; test_case "cadence mutation and wake are serialized" `Quick
            test_cadence_mutation_and_wake_are_serialized
        ; test_case "Keeper metric producer tracks live work" `Quick
            test_keeper_metric_producer_tracks_turn_and_failed_sleep
        ] )
    ]
