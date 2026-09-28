(** task-212: Backlog namespace distributed lock regression tests.

   Covers production paths around [tasks:.backlog]:
   - lock key naming contract
   - N-actor contention storm
   - stale lock takeover
   - invalid metadata recovery
   - lock_info JSON roundtrip contract *)

open Alcotest
module Backend = Backend

let rec rm_rf path =
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

(* [f backend clock rival]: [rival ()] builds another backend value on the
   same base path, as an independently initialised component of the same
   process would. *)
let with_eio_backends f =
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let clock = Eio.Stdenv.clock env in
  let tmp_dir = make_test_dir "masc_lock_backlog" in
  let config =
    { (Backend.default_config ()) with
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
          f backend clock (fun () -> Backend.FileSystem.create ~fs config)))

let with_eio_backend f = with_eio_backends (fun backend clock _rival -> f backend clock)

(* Mirrors the key construction in backend.ml ("locks:" ^ key), which is where
   acquire/release/read actually build it. The cases below hit the backend
   through this helper, so a drift here fails them rather than passing quietly. *)
let lock_key namespace = "locks:" ^ namespace

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

    Eio.Fiber.all (List.init contenders (fun i () -> attempt i));

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
    (match Backend.FileSystem.acquire_lock backend ~key:namespace ~owner:"keeper-recover" ~ttl_seconds:60 with
    | Ok true -> ()
    | Ok false -> fail "stale lock should be recoverable after expiry"
    | Error e -> fail (Printf.sprintf "stale lock recover attempt failed: %s" (Backend.show_error e)));

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
    (match Backend.FileSystem.acquire_lock backend ~key:namespace ~owner:"keeper-recover" ~ttl_seconds:60 with
    | Ok true -> ()
    | Ok false -> fail "invalid metadata lock should be overwritten"
    | Error e -> fail (Printf.sprintf "invalid metadata acquire failed: %s" (Backend.show_error e)));

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

(* {2 Lease fence}

   A lease record may change hands only through a fenced acquire, and a
   publication made under a lease runs inside the same fence as its owner
   check. The cases below stop a holder between that owner check and its
   renewal and let a rival try to take the lease over at exactly that point. *)

let lease_owner backend key =
  match Backend.FileSystem.get backend (lock_key key) with
  | Error _ -> None
  | Ok json ->
      Option.map
        (fun (info : Backend.FileSystem.lock_info) -> info.owner)
        (Backend.FileSystem.lock_info_of_json json)

let acquire_ok backend ~key ~owner ~ttl_seconds =
  match Backend.FileSystem.acquire_lock backend ~key ~owner ~ttl_seconds with
  | Ok true -> ()
  | Ok false -> failf "%s could not acquire %s" owner key
  | Error e -> fail (Backend.show_error e)

(* A lease taken with a zero TTL has expired once the clock moves on. *)
let acquire_expired backend clock ~key ~owner =
  acquire_ok backend ~key ~owner ~ttl_seconds:0;
  Eio.Time.sleep clock 0.02

let with_owner_read_hook hook f =
  let seam = Backend.FileSystem.after_lease_owner_read_hook in
  let previous = Atomic.get seam in
  Atomic.set seam hook;
  Fun.protect ~finally:(fun () -> Atomic.set seam previous) f

let fence_probe_env = "MASC_LEASE_FENCE_PROBE"

(* Runs in a separate process: this executable re-invoked with
   [fence_probe_env] naming the fence file. It tries the file's fcntl lock
   without waiting and exits 0 when the lock was free, 3 when another process
   holds it. fcntl locks belong to a process, so only another process can
   observe the one this process holds. *)
let run_fence_probe path =
  let fd = Unix.openfile path [ Unix.O_RDWR; Unix.O_CREAT ] 0o644 in
  let code =
    match Unix.lockf fd Unix.F_TLOCK 0 with
    | () -> 0
    | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EACCES), _, _) -> 3
  in
  Unix.close fd;
  exit code

let probe_fence_from_another_process fence_path =
  Eio_unix.run_in_systhread (fun () ->
    let env =
      Array.append
        [| fence_probe_env ^ "=" ^ fence_path |]
        (Unix.environment ())
    in
    let pid =
      Unix.create_process_env Sys.executable_name [| Sys.executable_name |] env
        Unix.stdin Unix.stdout Unix.stderr
    in
    match Unix.waitpid [] pid with
    | _, Unix.WEXITED code -> code
    | _, (Unix.WSIGNALED signal | Unix.WSTOPPED signal) -> 100 + signal)

let fence_path_of backend key =
  match Backend.FileSystem.lease_fence_path backend ~key with
  | Ok path -> path
  | Error e -> fail (Backend.show_error e)

(* A's lease expired and B took it over. A's publication must not run. *)
let test_commit_refused_after_takeover () =
  with_eio_backend (fun backend clock ->
    let key = make_unique_key "lease_stolen" in
    acquire_expired backend clock ~key ~owner:"holder-a";
    acquire_ok backend ~key ~owner:"holder-b" ~ttl_seconds:60;
    let published = ref 0 in
    (match
       Backend.FileSystem.commit_under_lease backend ~key ~owner:"holder-a"
         ~ttl_seconds:60 (fun () -> incr published)
     with
     | Ok (Error { Backend.FileSystem.holder }) ->
         check (option string) "the refusal names the new holder"
           (Some "holder-b") holder
     | Ok (Ok ()) -> fail "a lease that was taken over still published"
     | Error e -> fail (Backend.show_error e));
    check int "the publication never ran" 0 !published;
    check (option string) "the new holder keeps the lease" (Some "holder-b")
      (lease_owner backend key))

(* A's lease has expired, so a rival may take it over, and A is stopped
   inside its commit after reading itself as owner and before renewing.
   The rival, built as a separate backend value on the same base path, tries
   the takeover right then. It must wait until A has renewed and published,
   and then find the lease renewed and refuse. Without the fence the rival
   would take over between A's read and A's renewal, and A would publish
   under a lease it no longer held. *)
let test_takeover_waits_between_owner_read_and_renewal () =
  with_eio_backends (fun backend clock rival ->
    let key = make_unique_key "lease_race" in
    let rival = rival () in
    acquire_expired backend clock ~key ~owner:"holder-a";
    let owner_read, owner_read_r = Eio.Promise.create () in
    let resume, resume_r = Eio.Promise.create () in
    let events = ref [] in
    let note event = events := event :: !events in
    let hook ~key:hook_key =
      if String.equal hook_key key then begin
        Eio.Promise.resolve owner_read_r ();
        Eio.Promise.await resume
      end
    in
    with_owner_read_hook hook (fun () ->
      Eio.Switch.run (fun sw ->
        let commit =
          Eio.Fiber.fork_promise ~sw (fun () ->
            Backend.FileSystem.commit_under_lease backend ~key ~owner:"holder-a"
              ~ttl_seconds:60 (fun () -> note "holder-a published"))
        in
        Eio.Promise.await owner_read;
        let takeover =
          Eio.Fiber.fork_promise ~sw (fun () ->
            let result =
              Backend.FileSystem.acquire_lock rival ~key ~owner:"holder-b"
                ~ttl_seconds:60
            in
            note "holder-b acquire returned";
            result)
        in
        for _ = 1 to 20 do Eio.Fiber.yield () done;
        Eio.Time.sleep clock 0.1;
        check bool
          "the takeover waits while the holder is between its owner read and \
           its renewal"
          false (Eio.Promise.is_resolved takeover);
        Eio.Promise.resolve resume_r ();
        (match Eio.Promise.await_exn commit with
         | Ok (Ok ()) -> ()
         | Ok (Error _) -> fail "the holder's own lease was refused"
         | Error e -> fail (Backend.show_error e));
        match Eio.Promise.await_exn takeover with
        | Ok false -> ()
        | Ok true -> fail "the rival took over a lease its holder had just renewed"
        | Error e -> fail (Backend.show_error e)));
    check (list string) "the publication came before the rival's decision"
      [ "holder-a published"; "holder-b acquire returned" ]
      (List.rev !events);
    check (option string) "the holder keeps the renewed lease" (Some "holder-a")
      (lease_owner backend key))

(* The same point seen from a real second process: while the holder is
   between its owner read and its renewal, another process cannot take the
   fence's fcntl lock; once the commit is done it can. *)
let test_fence_excludes_another_process () =
  with_eio_backend (fun backend _clock ->
    let key = make_unique_key "lease_process" in
    acquire_ok backend ~key ~owner:"holder-a" ~ttl_seconds:60;
    let fence_path = fence_path_of backend key in
    let probe_inside = ref (-1) in
    with_owner_read_hook
      (fun ~key:hook_key ->
        if String.equal hook_key key then
          probe_inside := probe_fence_from_another_process fence_path)
      (fun () ->
        match
          Backend.FileSystem.commit_under_lease backend ~key ~owner:"holder-a"
            ~ttl_seconds:60 (fun () -> ())
        with
        | Ok (Ok ()) -> ()
        | Ok (Error _) -> fail "the holder's own lease was refused"
        | Error e -> fail (Backend.show_error e));
    check int
      "another process finds the fence held between owner read and renewal" 3
      !probe_inside;
    check int "another process takes the fence once the commit is done" 0
      (probe_fence_from_another_process fence_path))

(* After B took A's expired lease over, A's late renewal and release must
   leave B's lease in place. *)
let test_release_and_extend_after_takeover_keep_new_holder () =
  with_eio_backend (fun backend clock ->
    let key = make_unique_key "lease_late" in
    acquire_expired backend clock ~key ~owner:"holder-a";
    acquire_ok backend ~key ~owner:"holder-b" ~ttl_seconds:60;
    (match
       Backend.FileSystem.extend_lock backend ~key ~owner:"holder-a"
         ~ttl_seconds:60
     with
     | Ok false -> ()
     | Ok true -> fail "a lease that was taken over was renewed"
     | Error e -> fail (Backend.show_error e));
    (match Backend.FileSystem.release_lock backend ~key ~owner:"holder-a" with
     | Ok false -> ()
     | Ok true -> fail "a lease that was taken over was released"
     | Error e -> fail (Backend.show_error e));
    check (option string) "the new holder keeps the lease" (Some "holder-b")
      (lease_owner backend key))

let () =
  match Sys.getenv_opt fence_probe_env with
  | Some fence_path -> run_fence_probe fence_path
  | None ->
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
      "lease fence", [
        test_case "commit refused after takeover" `Quick
          test_commit_refused_after_takeover;
        test_case "takeover waits between owner read and renewal" `Quick
          test_takeover_waits_between_owner_read_and_renewal;
        test_case "fence excludes another process" `Quick
          test_fence_excludes_another_process;
        test_case "late release and extend keep the new holder" `Quick
          test_release_and_extend_after_takeover_keep_new_holder;
      ];
    ]
