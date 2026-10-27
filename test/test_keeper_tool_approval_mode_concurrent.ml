(* [Keeper_tool_approval_mode.set] writes the override store while it holds the
   registry lock, and that write suspends the calling fiber: [Fs_compat] runs
   the read, the mkdir and the atomic replacement of the store file on a worker
   thread. The fibers of a domain share one thread, so a lock that raises when
   the thread that holds it locks it again fails the next caller instead of
   making it wait. [resolve] runs on every keeper turn, so one operator POST
   that is still writing the file would fail the approval decision of a turn
   with Sys_error "Mutex.lock: Resource deadlock avoided". A second writer and
   [bind] hit the same error. *)
open Alcotest
open Masc

module Mode = Keeper_tool_approval_mode

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let with_store_dir f =
  let base_path = Filename.temp_dir "tool-approval-concurrent-" "" in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
      Eio_main.run (fun env ->
        Fs_compat.set_fs (Eio.Stdenv.fs env);
        Fun.protect ~finally:Fs_compat.clear_fs (fun () -> f ~base_path)))

let set_exn store ~base_path ~keeper_name mode =
  match Mode.set store ~base_path ~actor:"test-operator" ~keeper_name mode with
  | Ok Mode.Applied -> ()
  | Ok (Mode.Applied_audit_failed detail) ->
    failf "set applied with unexpected audit failure: %s" detail
  | Error detail -> failf "set failed: %s" detail

let persisted_names ~base_path =
  match Mode.keeper_overrides ~base_path with
  | Ok rows -> List.map (fun row -> row.Mode.keeper_name) rows
  | Error detail -> failf "could not read the store back: %s" detail

let named_modes overrides =
  List.map (fun (name, mode) -> name, Mode.mode_to_string mode) overrides

let test_readers_do_not_wait_for_a_writers_disk_io () =
  with_store_dir (fun ~base_path ->
    let store = Mode.create () in
    let keeper_name = "reader-keeper" in
    let writer_started = ref false in
    let writer_finished = ref false in
    let reader_saw = ref None in
    Eio.Fiber.both
      (fun () ->
        writer_started := true;
        set_exn store ~base_path ~keeper_name Mode.Yolo;
        writer_finished := true)
      (fun () ->
        (* The second fiber only runs once the first one suspends. If [set]
           never suspended it would already be finished here, and the reads
           below would prove nothing. *)
        let writer_was_suspended = !writer_started && not !writer_finished in
        let resolved = Mode.resolve store ~keeper_name in
        let listed = Mode.overrides store in
        let restore_error = Mode.last_restore_error store in
        reader_saw :=
          Some
            ( writer_was_suspended
            , resolved
            , listed
            , restore_error
            , !writer_finished ));
    match !reader_saw with
    | None -> fail "the reader did not run"
    | Some (writer_was_suspended, resolved, listed, restore_error, finished) ->
      check bool "the writer was suspended inside set when the reader ran" true
        writer_was_suspended;
      check string "resolve answers from the state before the write" "auto"
        (Mode.mode_to_string resolved);
      check (list (pair string string)) "overrides answers from the state before the write"
        [] (named_modes listed);
      check (option string) "no restore error before the write" None restore_error;
      check bool "the reads returned before the write finished" false finished;
      check string "resolve returns the new mode once the write is done" "yolo"
        (Mode.mode_to_string (Mode.resolve store ~keeper_name));
      check (list (pair string string)) "overrides lists the new mode once the write is done"
        [ keeper_name, "yolo" ]
        (named_modes (Mode.overrides store)))

let test_concurrent_sets_for_different_keepers_both_apply () =
  with_store_dir (fun ~base_path ->
    let store = Mode.create () in
    let keepers = [ "writer-a"; "writer-b" ] in
    let callers = List.length keepers in
    let asked = ref 0 in
    let asked_when_served = ref [] in
    let write keeper_name =
      incr asked;
      set_exn store ~base_path ~keeper_name Mode.Yolo;
      asked_when_served := !asked :: !asked_when_served
    in
    Eio.Fiber.List.iter write keepers;
    (* The first write suspends inside the lock, so the second caller has
       asked before the first is served. A write that never suspended would
       serve the first caller after one ask and the test would prove nothing. *)
    check (list int) "every caller asked before any was served"
      (List.init callers (fun _ -> callers)) !asked_when_served;
    let sorted = List.sort String.compare in
    let in_memory = List.map fst (Mode.overrides store) in
    let on_disk = persisted_names ~base_path in
    check (list string) "memory holds both keepers" (sorted keepers) (sorted in_memory);
    check (list string) "the file holds both keepers" (sorted keepers) (sorted on_disk);
    check (list string) "memory and file list the keepers in the same order" on_disk
      in_memory;
    List.iter
      (fun keeper_name ->
        check string ("resolve " ^ keeper_name) "yolo"
          (Mode.mode_to_string (Mode.resolve store ~keeper_name)))
      keepers)

let test_bind_waits_for_a_set_in_flight () =
  with_store_dir (fun ~base_path ->
    let store = Mode.create () in
    let keeper_name = "bind-keeper" in
    let writer_started = ref false in
    let writer_finished = ref false in
    let bind_ran_while_writer_was_suspended = ref false in
    let bound = ref None in
    Eio.Fiber.both
      (fun () ->
        writer_started := true;
        set_exn store ~base_path ~keeper_name Mode.Yolo;
        writer_finished := true)
      (fun () ->
        bind_ran_while_writer_was_suspended :=
          !writer_started && not !writer_finished;
        bound := Some (Mode.bind ~base_path store));
    check bool "bind was called while the writer was suspended inside set" true
      !bind_ran_while_writer_was_suspended;
    (match !bound with
     | Some (Ok ()) -> ()
     | Some (Error detail) -> failf "bind failed: %s" detail
     | None -> fail "bind did not return");
    (* A replay that read the store before the writer's rename and published
       after the writer's update would put the empty pre-image back. *)
    check string "the replay kept the row the writer stored" "yolo"
      (Mode.mode_to_string (Mode.resolve store ~keeper_name));
    check (list string) "the file still holds the row" [ keeper_name ]
      (persisted_names ~base_path))

let () =
  run "keeper tool approval mode concurrent"
    [ ( "registry lock"
      , [ test_case "readers do not wait for a writer's disk I/O" `Quick
            test_readers_do_not_wait_for_a_writers_disk_io
        ; test_case "concurrent sets for different keepers both apply" `Quick
            test_concurrent_sets_for_different_keepers_both_apply
        ; test_case "bind waits for a set in flight" `Quick
            test_bind_waits_for_a_set_in_flight
        ] )
    ]
