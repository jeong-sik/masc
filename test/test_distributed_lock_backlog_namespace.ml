(** task-212: Backlog namespace distributed lock regression tests.

   Covers production paths around [tasks:.backlog]:
   - lock key naming contract
   - N-actor contention storm
   - stale lock takeover
   - invalid metadata recovery
   - lock_info JSON roundtrip contract *)

open Alcotest
module Backend = Backend

let rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Array.iter (fun name -> rm_rf (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
    )
    else
      Unix.unlink path

let make_unique_key prefix =
  Printf.sprintf "%s_%d_%d" prefix (Unix.getpid ())
    (int_of_float (Unix.gettimeofday () *. 1_000_000.))

let make_test_dir base =
  let tmp_dir = Filename.concat (Filename.get_temp_dir_name ()) (make_unique_key base) in
  (try Unix.mkdir tmp_dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  tmp_dir

let with_eio_backend f =
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let clock = Eio.Stdenv.clock env in
  let tmp_dir = make_test_dir "masc_lock_backlog" in
  let config =
    { Backend.default_config with
      base_path = tmp_dir
    ; node_id = "test-node"
    ; cluster_name = "test-cluster"
    }
  in
  Fun.protect
    ~finally:(fun () -> try rm_rf tmp_dir with _ -> ())
    (fun () ->
      Eio.Switch.run @@ fun sw ->
      Eio_context.with_test_env
        ~net:(Eio.Stdenv.net env)
        ~clock
        ~mono_clock:(Eio.Stdenv.mono_clock env)
        ~sw
        (fun () ->
          let backend = Backend.FileSystem.create ~fs config in
          f backend clock))

let lock_key namespace = Coord_eio.lock_key namespace

let test_backlog_lock_key () =
  check string "backlog key uses lock namespace"
    "locks:tasks:.backlog" (lock_key "tasks:.backlog")

let test_backlog_lock_storm () =
  with_eio_backend (fun backend _clock ->
    let namespace = "tasks:.backlog" in
    let contenders = 17 in
    let winners : string list ref = ref [] in
    let winners_mu = Eio.Mutex.create () in

    let attempt idx =
      let owner = Printf.sprintf "keeper-%02d" idx in
      Eio.Fiber.yield ();
      match Backend.FileSystem.acquire_lock backend ~key:namespace ~owner ~ttl_seconds:60 with
      | Ok true ->
          Eio.Mutex.use_rw ~protect:true winners_mu (fun () -> winners := owner :: !winners)
      | Ok false -> ()
      | Error e -> fail (Printf.sprintf "acquire failed: %s" (Backend.show_error e))
    in

    Eio.Fiber.all (List.init contenders attempt);

    match !winners with
    | [winner] ->
        (match Backend.FileSystem.get backend (lock_key namespace) with
         | Ok json ->
            (match Backend.FileSystem.lock_info_of_json json with
             | Some info -> check string "single winner owns lock" winner info.owner
             | None -> fail "lock_info_of_json should parse winner metadata")
         | Error e ->
            fail (Printf.sprintf "lock metadata should be readable: %s" (Backend.show_error e)))
    | [] -> fail "no winner under contention"
    | _ -> fail "more than one winner under contention")

let test_stale_lock_recovery () =
  with_eio_backend (fun backend clock ->
    let namespace = "tasks:.backlog" in
    (match Backend.FileSystem.acquire_lock backend ~key:namespace ~owner:"keeper-old" ~ttl_seconds:1 with
     | Ok true -> ()
     | Ok false -> fail "initial acquire should succeed"
     | Error e -> fail (Printf.sprintf "initial acquire should succeed: %s" (Backend.show_error e)));
    Eio.Time.sleep clock 1.5;
    match Backend.FileSystem.acquire_lock backend ~key:namespace ~owner:"keeper-recover" ~ttl_seconds:60 with
    | Ok true -> ()
    | Ok false -> fail "stale lock should be recoverable after expiry"
    | Error e -> fail (Printf.sprintf "stale lock recover attempt failed: %s" (Backend.show_error e));

    match Backend.FileSystem.get backend (lock_key namespace) with
    | Ok json ->
        (match Backend.FileSystem.lock_info_of_json json with
         | Some info -> check string "recovered owner" "keeper-recover" info.owner
         | None -> fail "lock_info_of_json should parse recovered metadata")
    | Error e ->
        fail (Printf.sprintf "lock metadata should be readable after recovery: %s" (Backend.show_error e)))

let test_invalid_metadata_recovery () =
  with_eio_backend (fun backend _clock ->
    let namespace = "tasks:.backlog" in
    let lkey = lock_key namespace in
    (match Backend.FileSystem.set backend lkey "not valid json" with
     | Ok () -> ()
     | Error e -> fail (Printf.sprintf "manual invalid metadata injection should work: %s" (Backend.show_error e)));
    match Backend.FileSystem.acquire_lock backend ~key:namespace ~owner:"keeper-recover" ~ttl_seconds:60 with
    | Ok true -> ()
    | Ok false -> fail "invalid metadata lock should be overwritten"
    | Error e -> fail (Printf.sprintf "invalid metadata acquire failed: %s" (Backend.show_error e));

    match Backend.FileSystem.get backend lkey with
    | Ok json ->
        (match Backend.FileSystem.lock_info_of_json json with
         | Some info -> check string "recovered owner from invalid metadata" "keeper-recover" info.owner
         | None -> fail "invalid metadata recovery should produce valid lock_info")
    | Error e ->
        fail (Printf.sprintf "lock metadata should be readable after invalid recovery: %s" (Backend.show_error e)))

let test_lock_info_roundtrip () =
  let expected : Backend.FileSystem.lock_info =
    { owner = "keeper-qa"; acquired_at = 1700000000.0; expires_at = 1700000060.0 }
  in
  let json = Backend.FileSystem.lock_info_to_json expected in
  match Backend.FileSystem.lock_info_of_json json with
  | Some parsed ->
      check string "owner roundtrip" expected.owner parsed.owner;
      check (float 0.001) "acquired_at roundtrip" expected.acquired_at parsed.acquired_at;
      check (float 0.001) "expires_at roundtrip" expected.expires_at parsed.expires_at
  | None -> fail "lock_info roundtrip should succeed"

let () =
  run "distributed_lock_backlog_namespace"
    [ "lock_key", [
        test_case "backlog namespace uses lock key" `Quick test_backlog_lock_key;
      ];
      "storm", [
        test_case "17 contenders => one winner" `Quick test_backlog_lock_storm;
      ];
      "recovery", [
        test_case "stale lock becomes reclaimable" `Quick test_stale_lock_recovery;
        test_case "invalid metadata is overwritten" `Quick test_invalid_metadata_recovery;
      ];
      "metadata", [
        test_case "lock_info json roundtrip" `Quick test_lock_info_roundtrip;
      ];
    ]
