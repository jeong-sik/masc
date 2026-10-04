open Alcotest
module Storage = Masc.Keeper_metrics_storage

let row i = `Assoc ["i", `Int i]
let row_bytes = String.length (Yojson.Safe.to_string (row 1)) + 1
let values storage =
  Dated_jsonl.read_recent (Storage.read_store storage) 100
  |> List.map (fun json -> Yojson.Safe.Util.(json |> member "i" |> to_int))

let with_dir f =
  let dir = Filename.temp_dir "keeper-metrics-storage-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree dir) (fun () -> f dir)

let test_disabled_keeps_all () = with_dir @@ fun dir ->
  let store = Storage.create ~base_dir:dir ~max_bytes:0 in
  for i = 1 to 20 do Storage.append store (row i) done;
  check (list int) "zero retains every row" (List.init 20 ((+) 1)) (values store)

let test_rotation_keeps_accepting_rows () = with_dir @@ fun dir ->
  let store = Storage.create ~base_dir:dir ~max_bytes:(2 * row_bytes) in
  List.iter (fun i -> Storage.append store (row i)) [1; 2; 3; 4];
  check (list int) "full completed file is pruned and new rows remain" [3; 4] (values store);
  Storage.append store (row 5);
  check (list int) "next rotation keeps a preceding row alongside the new one" [4; 5] (values store)

let test_prunes_old_days () = with_dir @@ fun dir ->
  let old_path = Filename.concat dir "2000-01/01.jsonl" in
  Fs_compat.mkdir_p (Filename.dirname old_path);
  Fs_compat.save_file old_path (Yojson.Safe.to_string (row 1) ^ "\n");
  let store = Storage.create ~base_dir:dir ~max_bytes:row_bytes in
  Storage.append store (row 2);
  check bool "older completed day is removed" false (Sys.file_exists old_path);
  check (list int) "current metric survives" [2] (values store)

let test_reopen_lower_target () = with_dir @@ fun dir ->
  let prior = Storage.create ~base_dir:dir ~max_bytes:0 in
  List.iter (fun i -> Storage.append prior (row i)) [1; 2; 3];
  let reopened = Storage.create ~base_dir:dir ~max_bytes:row_bytes in
  Storage.append reopened (row 4);
  check (list int) "new target takes effect when store reopens" [4] (values reopened)

let test_oversized_row_is_preserved () = with_dir @@ fun dir ->
  let store = Storage.create ~base_dir:dir ~max_bytes:row_bytes in
  let large = `Assoc ["i", `Int 1; "detail", `String (String.make 100 'x')] in
  Storage.append store large;
  check string "one oversized metric is preserved whole"
    (Yojson.Safe.to_string large)
    (Yojson.Safe.to_string (List.hd (Dated_jsonl.read_recent (Storage.read_store store) 1)));
  Storage.append store (row 2);
  check (list int) "next row rotates the oversized file" [2] (values store)

let test_stores_and_auxiliary_logs_are_independent () = with_dir @@ fun dir ->
  let a = Storage.create ~base_dir:(Filename.concat dir "a/metrics") ~max_bytes:row_bytes in
  let b = Storage.create ~base_dir:(Filename.concat dir "b/metrics") ~max_bytes:0 in
  let auxiliary = Filename.concat dir "a/decisions.jsonl" in
  Fs_compat.mkdir_p (Filename.dirname auxiliary);
  Fs_compat.save_file auxiliary "keep auxiliary log";
  List.iter (fun i -> Storage.append a (row i); Storage.append b (row i)) [1; 2; 3];
  check (list int) "bounded Keeper has newest row" [3] (values a);
  check (list int) "other Keeper retains its own history" [1; 2; 3] (values b);
  check string "auxiliary log is outside this policy" "keep auxiliary log"
    (Fs_compat.load_file auxiliary)

let test_guard_refusal_is_observable () = with_dir @@ fun dir ->
  let store = Storage.create ~base_dir:dir ~max_bytes:row_bytes in
  Dated_jsonl.set_append_guard (fun _ -> ());
  Fun.protect ~finally:(fun () -> Dated_jsonl.set_append_guard (fun f -> f ())) (fun () ->
    match Storage.append store (row 1) with
    | () -> fail "refused write was reported as successful"
    | exception Sys_error _ -> ());
  Storage.append store (row 2);
  check (list int) "refusal does not poison subsequent writes" [2] (values store)

let test_io_failure_can_recover () = with_dir @@ fun dir ->
  let base_dir = Filename.concat dir "collision" in
  Fs_compat.save_file base_dir "not a directory";
  let store = Storage.create ~base_dir ~max_bytes:row_bytes in
  (match Storage.append store (row 1) with
   | () -> fail "invalid store path was reported as successful"
   | exception (Sys_error _ | Unix.Unix_error _ | Eio.Io _) -> ());
  Sys.remove base_dir;
  Storage.append store (row 2);
  check (list int) "I/O refusal leaves store reusable" [2] (values store)

let test_continues_across_sequence_width_and_reopen () = with_dir @@ fun dir ->
  (* Fixed-width values keep exactly two rows in the configured byte target. *)
  let row i = `Assoc ["i", `String (Printf.sprintf "%04d" i)] in
  let bytes = String.length (Yojson.Safe.to_string (row 1)) + 1 in
  let write storage first last =
    for i = first to last do Storage.append storage (row i) done in
  let storage = Storage.create ~base_dir:dir ~max_bytes:(bytes * 2) in
  write storage 1 1002;
  let reopened = Storage.create ~base_dir:dir ~max_bytes:(bytes * 2) in
  write reopened 1003 1010;
  let store = Storage.read_store reopened in
  let values rows = List.map (fun json -> Yojson.Safe.Util.(json |> member "i" |> to_string)) rows in
  let expected = ["1009"; "1010"] in
  check (list string) "retention still accepts the newest rows after reopening" expected
    (values (Dated_jsonl.read_recent store 100));
  let strict = match Dated_jsonl.read_recent_result store 100 with
    | Ok rows -> List.map (function Dated_jsonl.Parsed json -> json
        | Malformed_json _ -> fail "writer produced malformed JSON") rows
    | Error err -> fail (Dated_jsonl.read_error_to_string err) in
  check (list string) "strict recent reader sees the same newest values" expected (values strict)

let test_segment_order_across_digit_boundary () = with_dir @@ fun dir ->
  let tm = Unix.gmtime (Unix.gettimeofday ()) in
  let month = Printf.sprintf "%04d-%02d" (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) in
  let day = Printf.sprintf "%02d" tm.Unix.tm_mday in
  let month_dir = Filename.concat dir month in
  Fs_compat.mkdir_p month_dir;
  List.iter (fun sequence ->
    Fs_compat.save_file (Filename.concat month_dir (Printf.sprintf "%s.%03d.jsonl" day sequence))
      (Yojson.Safe.to_string (row sequence) ^ "\n")) [998; 999; 1000];
  Fs_compat.save_file (Filename.concat month_dir (day ^ ".jsonl"))
    (Yojson.Safe.to_string (row 1001) ^ "\n");
  let store = Storage.create ~base_dir:dir ~max_bytes:0 |> Storage.read_store in
  let expected = [998; 999; 1000; 1001] in
  let values rows = List.map (fun json -> Yojson.Safe.Util.(json |> member "i" |> to_int)) rows in
  let date = month ^ "-" ^ day in
  check (list int) "recent reader sorts numeric sequences" expected
    (values (Dated_jsonl.read_recent store 10));
  check (list int) "range reader sorts numeric sequences" expected
    (values (Dated_jsonl.read_range store ~since:date ~until:date));
  let paths = match Dated_jsonl.range_day_file_paths_result store ~since:date ~until:date with
    | Ok paths -> paths | Error err -> fail (Dated_jsonl.read_error_to_string err) in
  check (list string) "strict range paths agree with row ordering"
    (List.map (fun seq -> Printf.sprintf "%s.%03d.jsonl" day seq) [998;999;1000] @ [day ^ ".jsonl"])
    (List.map Filename.basename paths);
  let row_bytes = String.length (Yojson.Safe.to_string (row 1001)) + 1 in
  let bounded = Storage.create ~base_dir:dir ~max_bytes:(row_bytes * 2) in
  Storage.append bounded (row 1002);
  check (list int) "prune removes 998/999/1000 before 1001" [1001;1002]
    (values (Dated_jsonl.read_recent (Storage.read_store bounded) 10))

let with_fs use_eio test () =
  let previous = Fs_compat.get_fs_opt () in
  Fun.protect ~finally:(fun () ->
    match previous with Some fs -> Fs_compat.set_fs fs | None -> Fs_compat.clear_fs ())
    (fun () -> Eio_main.run (fun env ->
      if use_eio then Fs_compat.set_fs (Eio.Stdenv.fs env) else Fs_compat.clear_fs ();
      test ()))

let () =
  let cases =
    [ "sequence width and reopen", test_continues_across_sequence_width_and_reopen
    ; "numeric reader and prune order", test_segment_order_across_digit_boundary
    ; "zero retains all", test_disabled_keeps_all
    ; "rotation keeps accepting", test_rotation_keeps_accepting_rows
    ; "old days are pruned", test_prunes_old_days
    ; "reopen applies smaller target", test_reopen_lower_target
    ; "oversized row is preserved", test_oversized_row_is_preserved
    ; "Keeper and auxiliary isolation", test_stores_and_auxiliary_logs_are_independent
    ; "append refusal is observable", test_guard_refusal_is_observable
    ; "I/O failure can recover", test_io_failure_can_recover ] in
  run "Keeper dated metrics"
    (List.map (fun (label, use_eio) ->
      label, List.map (fun (name, test) -> test_case name `Quick (with_fs use_eio test)) cases)
      ["Stdlib filesystem", false; "Eio filesystem", true])
