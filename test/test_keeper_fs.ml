open Alcotest

module KF = Masc.Keeper_fs
module KI = Masc.Keeper_identity

let read_file path =
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
    let len = in_channel_length ic in
    really_input_string ic len)

let temp_dir () =
  let dir = Filename.temp_file "test_keeper_fs_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else
        Unix.unlink path
  in
  try rm dir with _ -> ()

let has_tmp_files dir =
  Sys.readdir dir
  |> Array.exists (fun name -> Filename.check_suffix name ".tmp")

let require_ok label = function
  | Ok () -> ()
  | Error msg -> failf "%s: %s" label msg

(* ================================================================ *)
(* ensure_dir tests                                                 *)
(* ================================================================ *)

let test_ensure_dir_creates_and_caches () =
  let base = temp_dir () in
  let dir = Filename.concat base "sub/nested" in
  let result = KF.ensure_dir dir in
  check string "returns path" dir result;
  check bool "directory exists" true (Sys.file_exists dir);
  check bool "is directory" true (Sys.is_directory dir);
  (* Second call should hit cache and succeed *)
  let result2 = KF.ensure_dir dir in
  check string "cached return" dir result2;
  cleanup_dir base

let test_ensure_dir_invalidate () =
  let base = temp_dir () in
  let dir = Filename.concat base "volatile" in
  ignore (KF.ensure_dir dir);
  check bool "exists after ensure" true (Sys.file_exists dir);
  (* Remove directory externally *)
  Unix.rmdir dir;
  check bool "gone after rmdir" false (Sys.file_exists dir);
  (* Invalidate cache and re-ensure *)
  KF.invalidate_dir dir;
  ignore (KF.ensure_dir dir);
  check bool "recreated after invalidate" true (Sys.file_exists dir);
  cleanup_dir base

let test_clear_dir_cache () =
  let base = temp_dir () in
  let dir = Filename.concat base "cleartest" in
  ignore (KF.ensure_dir dir);
  KF.clear_dir_cache ();
  (* After clearing cache, ensure_dir should re-check filesystem *)
  Unix.rmdir dir;
  ignore (KF.ensure_dir dir);
  check bool "recreated after cache clear" true (Sys.file_exists dir);
  cleanup_dir base

let test_ensure_dir_failure_does_not_poison_mutex () =
  let base = temp_dir () in
  let blocker = Filename.concat base "blocker" in
  let oc = open_out blocker in
  close_out oc;
  let bad = Filename.concat blocker "child" in
  let good = Filename.concat base "good/nested" in
  let saw_failure =
    try
      ignore (KF.ensure_dir bad);
      false
    with _ -> true
  in
  check bool "bad path fails" true saw_failure;
  let result = KF.ensure_dir good in
  check string "good path returns" good result;
  check bool "good path exists after prior failure" true (Sys.file_exists good);
  check bool "good path is directory" true (Sys.is_directory good);
  cleanup_dir base

(* ================================================================ *)
(* save_atomic tests                                                *)
(* ================================================================ *)

let test_save_atomic_basic () =
  let base = temp_dir () in
  let path = Filename.concat base "data.json" in
  let content = {|{"key": "value"}|} in
  require_ok "save_atomic basic" (KF.save_atomic path content);
  let loaded = read_file path in
  check string "content matches" content loaded;
  check bool "no tmp file" false (has_tmp_files base);
  cleanup_dir base

let test_save_atomic_overwrites () =
  let base = temp_dir () in
  let path = Filename.concat base "overwrite.txt" in
  require_ok "save_atomic first write" (KF.save_atomic path "first");
  require_ok "save_atomic second write" (KF.save_atomic path "second");
  let loaded = read_file path in
  check string "second write wins" "second" loaded;
  cleanup_dir base

let test_save_atomic_creates_parent_dir () =
  let base = temp_dir () in
  let path = Filename.concat base "deep/nested/file.txt" in
  require_ok "save_atomic creates parent dir" (KF.save_atomic path "content");
  check bool "file exists" true (Sys.file_exists path);
  let loaded = read_file path in
  check string "content matches" "content" loaded;
  cleanup_dir base

let test_save_json_atomic () =
  let base = temp_dir () in
  let path = Filename.concat base "test.json" in
  let json = `Assoc [("name", `String "keeper"); ("gen", `Int 1)] in
  require_ok "save_json_atomic" (KF.save_json_atomic path json);
  let loaded = Yojson.Safe.from_file path in
  let open Yojson.Safe.Util in
  check string "name field" "keeper" (loaded |> member "name" |> to_string);
  check int "gen field" 1 (loaded |> member "gen" |> to_int);
  cleanup_dir base

let test_durable_write_pre_publish_failure_preserves_target () =
  Eio_main.run
  @@ fun _env ->
  let base = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base)
    (fun () ->
       let path = Filename.concat base "durable.json" in
       let old_content = {|{"version":"old"}|} in
       require_ok "seed durable target" (KF.save_atomic path old_content);
       let result =
         KF.For_testing.save_json_durable_atomic
           ~before_stage:(function
             | KF.Payload_fsync -> failwith "injected payload fsync failure"
             | _ -> ())
           path
           (`Assoc [ "version", `String "new" ])
       in
       (match result with
        | Error { renamed = false; stage = KF.Payload_fsync; _ } -> ()
        | Error error ->
          failf
            "unexpected durable write error: %s"
            (KF.durable_write_error_to_string error)
        | Ok () -> fail "pre-publish failure unexpectedly succeeded");
       check string "old target remains authoritative" old_content (read_file path);
       check bool "failed temp is removed" false (has_tmp_files base))

let test_durable_write_commits_new_directory_chain () =
  Eio_main.run
  @@ fun _env ->
  let base = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base)
    (fun () ->
       let directory = Filename.concat base "new/active" in
       let path = Filename.concat directory "request.json" in
       let json = `Assoc [ "status", `String "queued" ] in
       (match KF.save_json_durable_atomic path json with
        | Ok () -> ()
        | Error error ->
          failf
            "first durable partition write failed: %s"
            (KF.durable_write_error_to_string error));
       check bool "nested partition exists" true (Sys.is_directory directory);
       check
         string
         "first record is visible"
         (Yojson.Safe.pretty_to_string json)
         (read_file path))

let test_durable_sibling_preparation_is_serialized () =
  Eio_main.run
  @@ fun _env ->
  let base = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base)
    (fun () ->
       KF.clear_dir_cache ();
       let request_root = Filename.concat base "keeper_msg_requests" in
       let active_path = Filename.concat request_root "active/request.json" in
       let terminal_path = Filename.concat request_root "terminal/request.json" in
       let first_entered, resolve_first_entered = Eio.Promise.create () in
       let second_started, resolve_second_started = Eio.Promise.create () in
       let release_first, resolve_release_first = Eio.Promise.create () in
       let second_prepare_entered = Atomic.make false in
       let second_entered_before_release = Atomic.make false in
       let first_result = ref None in
       let second_result = ref None in
       let first () =
         first_result :=
           Some
             (KF.For_testing.save_json_durable_atomic
                ~before_stage:(function
                  | KF.Directory_prepare ->
                    Eio.Promise.resolve resolve_first_entered ();
                    Eio.Promise.await release_first
                  | _ -> ())
                active_path
                (`Assoc [ "partition", `String "active" ]))
       in
       let second () =
         Eio.Promise.await first_entered;
         Eio.Promise.resolve resolve_second_started ();
         second_result :=
           Some
             (KF.For_testing.save_json_durable_atomic
                ~before_stage:(function
                  | KF.Directory_prepare -> Atomic.set second_prepare_entered true
                  | _ -> ())
                terminal_path
                (`Assoc [ "partition", `String "terminal" ]))
       in
       let observe_ordering () =
         Eio.Promise.await second_started;
         Eio.Fiber.yield ();
         Atomic.set
           second_entered_before_release
           (Atomic.get second_prepare_entered);
         Eio.Promise.resolve resolve_release_first ()
       in
       Eio.Fiber.all [ first; second; observe_ordering ];
       check
         bool
         "sibling preparation waits for ancestor durability"
         false
         (Atomic.get second_entered_before_release);
       check bool "second sibling eventually prepares" true (Atomic.get second_prepare_entered);
       let require_durable label = function
         | Some (Ok ()) -> ()
         | Some (Error error) ->
           failf "%s failed: %s" label (KF.durable_write_error_to_string error)
         | None -> failf "%s did not return" label
       in
       require_durable "active sibling" !first_result;
       require_durable "terminal sibling" !second_result)

let test_durable_write_post_publish_failure_reports_visible_target () =
  Eio_main.run
  @@ fun _env ->
  let base = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base)
    (fun () ->
       let path = Filename.concat base "durable.json" in
       require_ok
         "seed durable target"
         (KF.save_atomic path {|{"version":"old"}|});
       let json = `Assoc [ "version", `String "new" ] in
       let result =
         KF.For_testing.save_json_durable_atomic
           ~before_stage:(function
             | KF.Parent_directory_fsync_after_rename ->
               failwith "injected parent fsync failure"
             | _ -> ())
           path
           json
       in
       (match result with
        | Error
            { renamed = true
            ; stage = KF.Parent_directory_fsync_after_rename
            ; _
            } -> ()
        | Error error ->
          failf
            "unexpected durable write error: %s"
            (KF.durable_write_error_to_string error)
        | Ok () -> fail "post-publish failure unexpectedly succeeded");
       check
         string
         "published bytes remain visible"
         (Yojson.Safe.pretty_to_string json)
         (read_file path);
       check bool "renamed temp is absent" false (has_tmp_files base))

let test_durable_remove_absent_path_still_fsyncs_parent () =
  Eio_main.run
  @@ fun _env ->
  let base = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base)
    (fun () ->
       let parent_fsync_observed = ref false in
       let path = Filename.concat base "absent.json" in
       let result =
         KF.For_testing.remove_file_durable
           ~before_stage:(function
             | KF.Parent_directory_fsync -> parent_fsync_observed := true
             | KF.Unlink -> ())
           path
       in
       (match result with
        | Ok () -> ()
        | Error error ->
          failf
            "absent durable remove failed: %s"
            (KF.durable_remove_error_to_string error));
       check bool "ENOENT still verifies parent durability" true !parent_fsync_observed)

let test_durable_remove_reports_absent_parent_fsync_failure () =
  Eio_main.run
  @@ fun _env ->
  let base = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base)
    (fun () ->
       let path = Filename.concat base "absent.json" in
       match
         KF.For_testing.remove_file_durable
           ~before_stage:(function
             | KF.Parent_directory_fsync ->
               failwith "injected parent fsync failure"
             | KF.Unlink -> ())
           path
       with
       | Error { removed = false; failure = KF.Parent_directory_fsync, _ } -> ()
       | Error error ->
         failf
           "unexpected durable remove error: %s"
           (KF.durable_remove_error_to_string error)
       | Ok () -> fail "absent remove hid the parent fsync failure")

(* ================================================================ *)
(* Keeper_identity tests                                            *)
(* ================================================================ *)

let test_generate_trace_id_format () =
  let id = KI.generate_trace_id () in
  check bool "starts with trace-" true (String.length id > 6 && String.sub id 0 6 = "trace-");
  (* Two calls should produce different IDs *)
  let id2 = KI.generate_trace_id () in
  check bool "unique IDs" true (id <> id2)

(* ================================================================ *)
(* Concurrent ensure_dir (Eio-based)                                *)
(* ================================================================ *)

let test_concurrent_ensure_dir () =
  Eio_main.run @@ fun _env ->
  let base = temp_dir () in
  KF.clear_dir_cache ();
  let dir = Filename.concat base "concurrent" in
  (* Spawn multiple fibers all calling ensure_dir on the same path *)
  let errors = Atomic.make 0 in
  Eio.Fiber.all
    (List.init 10 (fun _i () ->
       try ignore (KF.ensure_dir dir)
       with _ -> Atomic.incr errors));
  check int "no errors" 0 (Atomic.get errors);
  check bool "directory exists" true (Sys.file_exists dir);
  cleanup_dir base

let test_concurrent_save_atomic () =
  Eio_main.run @@ fun _env ->
  let base = temp_dir () in
  let path = Filename.concat base "concurrent.txt" in
  let errors = Atomic.make 0 in
  Eio.Fiber.all
    (List.init 10 (fun i () ->
       try
         match KF.save_atomic path (Printf.sprintf "fiber-%d" i) with
         | Ok () -> ()
         | Error _ -> Atomic.incr errors
       with _ -> Atomic.incr errors));
  check int "no errors" 0 (Atomic.get errors);
  check bool "file exists" true (Sys.file_exists path);
  (* File should contain exactly one of the fiber writes *)
  let content = read_file path in
  check bool "contains fiber-" true (String.length content > 0
    && String.sub content 0 6 = "fiber-");
  check bool "no tmp file left behind" false (has_tmp_files base);
  cleanup_dir base

(* ================================================================ *)
(* Test runner                                                      *)
(* ================================================================ *)

let () =
  KF.clear_dir_cache ();
  run "Keeper_fs"
    [
      ( "ensure_dir",
        [
          test_case "creates and caches" `Quick test_ensure_dir_creates_and_caches;
          test_case "invalidate" `Quick test_ensure_dir_invalidate;
          test_case "clear cache" `Quick test_clear_dir_cache;
          test_case "failure does not poison mutex" `Quick
            test_ensure_dir_failure_does_not_poison_mutex;
        ] );
      ( "save_atomic",
        [
          test_case "basic write" `Quick test_save_atomic_basic;
          test_case "overwrites" `Quick test_save_atomic_overwrites;
          test_case "creates parent dir" `Quick test_save_atomic_creates_parent_dir;
          test_case "json atomic" `Quick test_save_json_atomic;
        ] );
      ( "durability",
        [ test_case
            "first write commits directory chain"
            `Quick
            test_durable_write_commits_new_directory_chain
        ; test_case
            "sibling preparation serializes ancestor durability"
            `Quick
            test_durable_sibling_preparation_is_serialized
        ; test_case
            "pre-publish failure preserves target"
            `Quick
            test_durable_write_pre_publish_failure_preserves_target;
          test_case
            "post-publish failure reports visible target"
            `Quick
            test_durable_write_post_publish_failure_reports_visible_target;
          test_case
            "absent remove still fsyncs parent"
            `Quick
            test_durable_remove_absent_path_still_fsyncs_parent;
          test_case
            "absent remove reports parent fsync failure"
            `Quick
            test_durable_remove_reports_absent_parent_fsync_failure;
        ] );
      ( "identity",
        [
          test_case "trace_id format" `Quick test_generate_trace_id_format;
        ] );
      ( "concurrent",
        [
          test_case "ensure_dir 10 fibers" `Quick test_concurrent_ensure_dir;
          test_case "save_atomic 10 fibers" `Quick test_concurrent_save_atomic;
        ] );
    ]
