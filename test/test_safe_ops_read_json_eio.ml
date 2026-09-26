open Alcotest

let with_json_file body f =
  let path = Filename.temp_file "masc-json-reader" ".json" in
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () ->
    Out_channel.with_open_bin path (fun ch -> Out_channel.output_string ch body);
    f path)

let with_occupied_pool f =
  Eio_main.run @@ fun env ->
  Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 10.0 @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let pool = Domain_pool.create ~sw ~domain_count:1 env#domain_mgr in
  let previous_pool = Domain_pool_ref.get () in
  let previous_fs = Fs_compat.get_fs_opt () in
  Eio.Switch.on_release sw (fun () ->
    (match previous_pool with
     | None -> Domain_pool_ref.clear_for_tests ()
     | Some pool -> Domain_pool_ref.set pool);
    match previous_fs with
    | None -> Fs_compat.clear_fs ()
    | Some fs -> Fs_compat.set_fs fs);
  Domain_pool_ref.set pool;
  (* These local fixture reads cannot yield before the parse. That makes the
     occupied worker distinguish inline parsing from a real CPU submission;
     a pending disk read must not make an inline parser appear to yield. *)
  Fs_compat.clear_fs ();
  let occupied, occupy = Eio.Promise.create () in
  let released, release_worker = Eio.Promise.create () in
  let release () =
    if not (Eio.Promise.is_resolved released) then
      Eio.Promise.resolve release_worker ()
  in
  Fun.protect ~finally:release (fun () ->
    Eio.Fiber.fork ~sw (fun () ->
      Domain_pool.submit_cpu pool (fun () ->
        Eio.Promise.resolve occupy ();
        Eio.Promise.await released));
    Eio.Promise.await occupied;
    f ~sw ~release)

let exercise_large_read ~body ~expected =
  with_json_file body @@ fun large_path ->
  with_json_file {|{"small":"한글🙂"}|} @@ fun small_path ->
  with_occupied_pool @@ fun ~sw ~release ->
  let entered, enter = Eio.Promise.create () in
  let parsed = Eio.Fiber.fork_promise ~sw (fun () ->
    Eio.Promise.resolve enter ();
    Safe_ops.read_json_eio large_path)
  in
  Eio.Promise.await entered;
  check bool "large read waits for the occupied CPU worker" false
    (Eio.Promise.is_resolved parsed);
  let small = Safe_ops.read_json_eio small_path in
  check bool "small sibling read completes with exact Unicode" true
    (small = `Assoc ["small", `String "한글🙂"]);
  let sibling = Eio.Fiber.fork_promise ~sw (fun () -> "progress") in
  check string "another request fiber runs while parsing waits" "progress"
    (Eio.Promise.await_exn sibling);
  check bool "large parse is still waiting" false
    (Eio.Promise.is_resolved parsed);
  release ();
  check bool "large read retains its exact result" true
    (Yojson.Safe.equal expected (Eio.Promise.await_exn parsed))

let large_text () = String.make Safe_ops.json_parse_offload_min_bytes 'x'

let test_large_valid () =
  let value = large_text () ^ "한글🙂" in
  let expected = `Assoc ["text", `String value] in
  exercise_large_read ~body:(Yojson.Safe.to_string expected) ~expected

let test_large_repaired () =
  let prefix = large_text () in
  let before = Safe_ops.persistence_utf8_repair_stats () in
  exercise_large_read
    ~body:("{\"text\":\"" ^ prefix ^ "\xff한글🙂\"}")
    ~expected:(`Assoc ["text", `String (prefix ^ "\xef\xbf\xbd한글🙂")]);
  let after = Safe_ops.persistence_utf8_repair_stats () in
  check int "repair counts exactly one read" (before.repaired_reads + 1)
    after.repaired_reads;
  check int "repair counts exactly one invalid byte" (before.repaired_bytes + 1)
    after.repaired_bytes

let test_large_malformed () =
  exercise_large_read ~body:("{\"text\":\"" ^ large_text ())
    ~expected:(`Assoc [])

let () =
  run "safe_ops_read_json_eio"
    [ "large file reads",
      [ test_case "valid Unicode leaves sibling fibers available" `Quick test_large_valid
      ; test_case "invalid UTF-8 repair survives offload" `Quick test_large_repaired
      ; test_case "malformed JSON retains its empty-object result" `Quick test_large_malformed
      ] ]
