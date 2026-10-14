(** Persistence for tool-approval-mode overrides.

    The stance used to be deliberately in-memory; that reversal is the point
    of this test file. A yolo override must survive a restart (an operator's
    other authorization choices already do), setting [Auto] must remove the
    row rather than store a synonym for the default, and a store that cannot
    be read must surface an error — resolving to [Auto] is the looser answer,
    so it must never be the quiet fallback for a broken file.
*)

open Alcotest
open Masc

module Mode = Keeper_tool_approval_mode

let temp_dir_counter = ref 0

let with_temp_dir f =
  incr temp_dir_counter;
  let base =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "tool-approval-persist-%d-%06d"
         (Unix.getpid ())
         !temp_dir_counter)
  in
  Unix.mkdir base 0o755;
  Fun.protect
    ~finally:(fun () ->
      let rec rm_rf path =
        if Sys.file_exists path
        then
          if Sys.is_directory path
          then (
            Sys.readdir path
            |> Array.iter (fun name -> rm_rf (Filename.concat path name));
            Unix.rmdir path)
          else Sys.remove path
      in
      rm_rf base)
    (fun () -> f base)
;;

let set_exn store ~base_path ~keeper_name mode =
  match Mode.set store ~base_path ~actor:"test-operator" ~keeper_name mode with
  | Ok () -> ()
  | Error detail -> fail ("set failed: " ^ detail)
;;

let write_corrupt_store ~base_path =
  let file = Keeper_gate_path.tool_approval_modes ~base_path in
  Fs_compat.mkdir_p (Keeper_gate_path.dir ~base_path);
  match Fs_compat.save_file_atomic file "{ not a store" with
  | Ok () -> file
  | Error detail -> fail ("could not write the corrupt fixture: " ^ detail)
;;

let test_yolo_survives_a_restart () =
  with_temp_dir @@ fun base_path ->
  let keeper_name = "persist-yolo" in
  let before = Mode.create () in
  set_exn before ~base_path ~keeper_name Mode.Yolo;
  (* Simulate the restart: a fresh registry, replayed from disk. *)
  let after = Mode.create () in
  (match Mode.bind ~base_path after with
   | Ok () -> ()
   | Error detail -> fail ("bind failed: " ^ detail));
  check bool "the override survived the restart" true
    (Mode.resolve after ~keeper_name = Mode.Yolo);
  check (list (pair string string)) "overrides list the keeper" [ keeper_name, "yolo" ]
    (List.map
       (fun (name, mode) -> name, Mode.mode_to_string mode)
       (Mode.overrides after));
  (match Mode.keeper_overrides ~base_path with
   | Ok [ row ] ->
     check string "the row names the keeper" keeper_name row.keeper_name;
     check string "the row records the actor" "test-operator" row.actor
   | Ok rows -> failf "expected one persisted row, got %d" (List.length rows)
   | Error detail -> fail ("could not read the persisted rows: " ^ detail))
;;

let test_auto_removes_the_row () =
  with_temp_dir @@ fun base_path ->
  let keeper_name = "persist-auto" in
  let store = Mode.create () in
  set_exn store ~base_path ~keeper_name Mode.Yolo;
  set_exn store ~base_path ~keeper_name Mode.Auto;
  check (list string) "memory holds no override" []
    (List.map fst (Mode.overrides store));
  (match Mode.keeper_overrides ~base_path with
   | Ok [] -> ()
   | Ok rows ->
     failf "clearing left %d persisted row(s) behind" (List.length rows)
   | Error detail -> fail ("could not read the persisted rows: " ^ detail))
;;

let test_a_corrupt_store_is_an_error_not_a_quiet_auto () =
  with_temp_dir @@ fun base_path ->
  let keeper_name = "persist-corrupt" in
  ignore (write_corrupt_store ~base_path);
  let store = Mode.create () in
  (match Mode.bind ~base_path store with
   | Ok () -> fail "bind succeeded on a corrupt store"
   | Error _ -> ());
  check bool "resolve falls back to Auto" true
    (Mode.resolve store ~keeper_name = Mode.Auto);
  check bool "the error is recorded, not silent" true
    (match Mode.last_restore_error store with
     | Some _ -> true
     | None -> false)
;;

let test_set_on_a_corrupt_store_holds_and_recovers () =
  with_temp_dir @@ fun base_path ->
  let keeper_name = "persist-corrupt-set" in
  let file = write_corrupt_store ~base_path in
  let store = Mode.create () in
  (match
     Mode.set store ~base_path ~actor:"test-operator" ~keeper_name Mode.Yolo
   with
   | Ok () -> fail "set succeeded on a corrupt store"
   | Error _ -> ());
  check (list string) "a failed set holds the registry" []
    (List.map fst (Mode.overrides store));
  (* Once the store reads again, a set both lands and clears the recorded
     error — the operator can repair forward without a restart. *)
  (match
     Fs_compat.save_file_atomic file
       {|{"schema":"masc.tool_approval_modes.v1","overrides":[]}|}
   with
   | Ok () -> ()
   | Error detail -> fail ("could not repair the store: " ^ detail));
  set_exn store ~base_path ~keeper_name Mode.Yolo;
  check bool "the repaired set landed" true
    (Mode.resolve store ~keeper_name = Mode.Yolo);
  check bool "the recorded error is cleared" true
    (Option.is_none (Mode.last_restore_error store))
;;

let () =
  run
    "keeper_tool_approval_mode_persist"
    [ ( "persist"
      , [ test_case "yolo survives a restart" `Quick test_yolo_survives_a_restart
        ; test_case "auto removes the row" `Quick test_auto_removes_the_row
        ; test_case "a corrupt store is an error, not a quiet auto" `Quick
            test_a_corrupt_store_is_an_error_not_a_quiet_auto
        ; test_case "set on a corrupt store holds and recovers" `Quick
            test_set_on_a_corrupt_store_holds_and_recovers
        ] )
    ]
;;
