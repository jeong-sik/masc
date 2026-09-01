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
        ] );
    ]
