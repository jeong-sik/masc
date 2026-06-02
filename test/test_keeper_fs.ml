open Alcotest

module KF = Masc_mcp.Keeper_fs
module KI = Masc_mcp.Keeper_identity

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
