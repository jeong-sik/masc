(** End-to-end round-trip test for Masc_runtime_events.

    Emits a Begin/End span via [emit_turn_start]/[emit_turn_end] into
    the current-process ring buffer and reads it back through an
    in-process cursor with [Runtime_events.Callbacks.add_user_event].

    This validates:
    - the listener is actually started by [start_listener]
    - the span-typed write carries [Begin]/[End] bounds through the
      buffer intact
    - consumers using [Runtime_events.Type.span] receive both bounds
      keyed to the same registered event handle ("masc.turn"). *)

let test_turn_span_roundtrip () =
  Masc_runtime_events.start_listener ();
  let cursor = Runtime_events.create_cursor None in

  Masc_runtime_events.emit_turn_start ();
  Masc_runtime_events.emit_turn_end ();

  let bounds_seen = ref [] in
  let span_cb _ring_idx _ts ev (bound : Runtime_events.Type.span) =
    if Runtime_events.User.name ev = "masc.turn" then
      bounds_seen := bound :: !bounds_seen
  in
  let callbacks =
    Runtime_events.Callbacks.create ()
    |> Runtime_events.Callbacks.add_user_event
         Runtime_events.Type.span span_cb
  in
  let _n = Runtime_events.read_poll cursor callbacks None in
  Runtime_events.free_cursor cursor;

  let observed = List.rev !bounds_seen in
  match observed with
  | [ Runtime_events.Type.Begin; Runtime_events.Type.End ] -> ()
  | _ ->
    Alcotest.failf
      "expected [Begin; End], got %d event(s)"
      (List.length observed)

(* with_turn_span composes emit_turn_start/emit_turn_end (covered by the
   round-trip above), so these cases pin only the bracket contract that is
   new: the body result flows through, and the body exception is re-raised
   (after the [finally] emits End). They deliberately do not read the
   process-global ring so they cannot interfere with the round-trip cursor. *)

let test_with_turn_span_returns_body () =
  let result = Masc_runtime_events.with_turn_span (fun () -> 7) in
  Alcotest.(check int) "with_turn_span returns the body's result" 7 result

let test_with_turn_span_propagates_exn () =
  Alcotest.check_raises
    "with_turn_span re-raises the body exception"
    (Failure "boom")
    (fun () ->
      ignore (Masc_runtime_events.with_turn_span (fun () -> failwith "boom")))

(* One past the largest pid any supported platform allocates (Linux caps
   pid_max at 4194304; macOS at 99999), so no process can hold it and
   [Unix.kill] answers ESRCH.  Picking a real reaped pid would need a fork,
   which this module's own docs warn against. *)
let dead_pid () = 4194305

let with_temp_dir f =
  let dir = Filename.temp_file "masc_events_prune" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () ->
      Array.iter (fun n -> try Sys.remove (Filename.concat dir n) with _ -> ())
        (try Sys.readdir dir with _ -> [||]);
      try Unix.rmdir dir with _ -> ())
    (fun () -> f dir)

let touch path = close_out (open_out path)

let test_prune_removes_dump_of_dead_pid () =
  with_temp_dir (fun dir ->
    let dead = Filename.concat dir (string_of_int (dead_pid ()) ^ ".events") in
    touch dead;
    Masc_runtime_events.prune_stale_dumps ~dir;
    Alcotest.(check bool) "dead pid dump removed" false (Sys.file_exists dead))

let test_prune_keeps_dump_of_live_pid () =
  with_temp_dir (fun dir ->
    let live =
      Filename.concat dir (string_of_int (Unix.getpid ()) ^ ".events")
    in
    touch live;
    Masc_runtime_events.prune_stale_dumps ~dir;
    Alcotest.(check bool) "live pid dump kept" true (Sys.file_exists live))

let test_prune_ignores_non_dump_files () =
  with_temp_dir (fun dir ->
    let keep = Filename.concat dir "notes.txt" in
    let keep_named = Filename.concat dir "olly.events" in
    touch keep;
    touch keep_named;
    Masc_runtime_events.prune_stale_dumps ~dir;
    Alcotest.(check bool) "unrelated file kept" true (Sys.file_exists keep);
    Alcotest.(check bool)
      "non-numeric .events kept" true (Sys.file_exists keep_named))

(* int_of_string accepts these as integers; the runtime never emits them as
   buffer names, so treating them as pids would unlink unrelated files. *)
let test_prune_rejects_non_decimal_pid_stems () =
  with_temp_dir (fun dir ->
    let names = [ "0x10.events"; "+123.events"; "1_000.events"; "-5.events" ] in
    List.iter (fun n -> touch (Filename.concat dir n)) names;
    Masc_runtime_events.prune_stale_dumps ~dir;
    List.iter
      (fun n ->
        Alcotest.(check bool)
          (Printf.sprintf "%s kept (not a decimal pid)" n)
          true
          (Sys.file_exists (Filename.concat dir n)))
      names)

(* Must run last in this file.  The guard keys on the variable's presence, the
   same way the OCaml runtime does, and the stdlib has no unsetenv — putenv ""
   still reads as present.  So this test permanently enables preserve mode for
   the remainder of the process and no later case may depend on pruning. *)
let test_prune_honors_preserve_env_runs_last () =
  with_temp_dir (fun dir ->
    let dead = Filename.concat dir (string_of_int (dead_pid ()) ^ ".events") in
    touch dead;
    Unix.putenv "OCAML_RUNTIME_EVENTS_PRESERVE" "1";
    Masc_runtime_events.prune_stale_dumps ~dir;
    Alcotest.(check bool)
      "dead dump kept when PRESERVE is set" true (Sys.file_exists dead))

let test_prune_survives_missing_dir () =
  let dir = Filename.concat (Filename.get_temp_dir_name ()) "masc_no_such_dir" in
  (* Must log and return, not raise: pruning cannot block the listener. *)
  Masc_runtime_events.prune_stale_dumps ~dir

(* A fresh process is necessary: OCaml snapshots the event directory before
   ML starts. These probes exercise the real exec and lease handoff rather
   than replacing either effect with a successful callback. *)
let startup_probe ~base_path ~run_dir ~token ~missing_executable =
  let lease = match Server_startup_takeover.acquire_base_path_lock ~run_dir base_path with
    | Server_startup_takeover.Base_path_acquired lease -> lease
    | Server_startup_takeover.Base_path_already_owned _ -> failwith "probe lease contended"
    | Server_startup_takeover.Base_path_rejected error ->
      failwith (Server_startup_takeover.base_path_lock_rejection_to_string error) in
  let executable_path = if missing_executable then Filename.concat base_path "missing-executable"
    else Unix.realpath Sys.executable_name in
  let emit stage fields =
    print_endline (Yojson.Safe.to_string
      (`Assoc (("stage", `String stage) :: ("pid", `Int (Unix.getpid ())) :: fields)));
    flush stdout in
  let result = Masc_runtime_events.prepare_process ~base_path ~executable_path ~argv:Sys.argv
      ~before_exec:(fun () ->
        emit "handoff" [];
        Server_startup_takeover.prepare_base_path_lease_exec_handoff lease) in
  let outcome = match result with
    | Error (Masc_runtime_events.Handoff_failed _) -> "handoff_failed"
    | Error (Masc_runtime_events.Directory_unavailable _) -> "directory_unavailable"
    | Error (Masc_runtime_events.Exec_failed _) -> "exec_failed"
    | Ok () ->
      (* Empty is an explicit runtime override whose opening semantics belong
         to OCaml. This probe observes preparation without opening /<pid>.events. *)
      if Sys.getenv_opt "OCAML_RUNTIME_EVENTS_DIR" <> Some "" then
        Masc_runtime_events.start_listener ();
      "ready" in
  emit "result"
    [ "outcome", `String outcome; "token", `String token
    ; "directory", (match Sys.getenv_opt "OCAML_RUNTIME_EVENTS_DIR" with
        | None -> `Null | Some directory -> `String directory)
    ; "ring", (match Runtime_events.path () with None -> `Null | Some path -> `String path) ];
  Server_startup_takeover.release_base_path_lease lease

let rec remove_startup_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Array.iter (fun name -> remove_startup_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> Unix.unlink path

let with_startup_workspace f =
  let root = Unix.realpath (Filename.temp_dir "masc-event-startup-" "") in
  let base_path = Filename.concat root "workspace" in
  let run_dir = Filename.concat root "host-run" in
  Unix.mkdir base_path 0o700;
  Unix.mkdir run_dir 0o700;
  Fun.protect ~finally:(fun () -> remove_startup_tree root) (fun () -> f root base_path run_dir)

let run_startup_probe ~root ~base_path ~run_dir ?(enabled="1") ?directory ?(missing_executable=false) () =
  let excluded =
    [ "MASC_RUNTIME_EVENTS"; "OCAML_RUNTIME_EVENTS_DIR"; "OCAML_RUNTIME_EVENTS_START"
    ; "OCAML_RUNTIME_EVENTS_PRESERVE" ] in
  let inherited = Unix.environment () |> Array.to_list |> List.filter (fun binding ->
    let name = match String.index_opt binding '=' with
      | Some separator -> String.sub binding 0 separator
      | None -> binding in
    not (List.mem name excluded)) in
  let environment = Array.of_list
      (inherited @ [ "MASC_RUNTIME_EVENTS=" ^ enabled ]
       @ (match directory with None -> [] | Some path -> [ "OCAML_RUNTIME_EVENTS_DIR=" ^ path ])) in
  let token = "argv survives exec with spaces" in
  let executable = Unix.realpath Sys.executable_name in
  let args = [| executable; "--startup-probe"; base_path; run_dir; token
              ; string_of_bool missing_executable |] in
  let output = Filename.concat root "probe-output" in
  let descriptor = Unix.openfile output [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o600 in
  let pid = Fun.protect ~finally:(fun () -> Unix.close descriptor) (fun () ->
    Unix.create_process_env executable args environment Unix.stdin descriptor Unix.stderr) in
  let _, status = Unix.waitpid [] pid in
  Alcotest.(check bool) "probe exits successfully" true (status = Unix.WEXITED 0);
  let input = open_in output in
  let lines = Fun.protect ~finally:(fun () -> close_in input) (fun () ->
    let rec read acc = match input_line input with
      | line -> read (Yojson.Safe.from_string line :: acc)
      | exception End_of_file -> List.rev acc in
    read []) in
  let result = List.hd (List.rev lines) in
  let open Yojson.Safe.Util in
  Alcotest.(check int) "exec preserves process identity" pid (result |> member "pid" |> to_int);
  Alcotest.(check string) "exec preserves argv" token (result |> member "token" |> to_string);
  let handoffs = List.filter (fun row -> (row |> member "stage" |> to_string) = "handoff") lines in
  List.iter (fun row -> Alcotest.(check int) "handoff has the original PID" pid
    (row |> member "pid" |> to_int)) handoffs;
  List.length handoffs, result

let test_default_directory_survives_real_exec () =
  with_startup_workspace (fun root base_path run_dir ->
    let handoffs, result = run_startup_probe ~root ~base_path ~run_dir () in
    let directory = Filename.concat (Common.masc_dir_from_base_path ~base_path) "runtime/events" in
    let open Yojson.Safe.Util in
    Alcotest.(check int) "one lease-preserving exec" 1 handoffs;
    Alcotest.(check string) "ready after exec" "ready" (result |> member "outcome" |> to_string);
    Alcotest.(check string) "runtime received the workspace directory" directory
      (result |> member "directory" |> to_string);
    Alcotest.(check string) "ring uses the workspace directory" directory
      (result |> member "ring" |> to_string |> Filename.dirname))

let test_explicit_and_disabled_directory_authority () =
  with_startup_workspace (fun root base_path run_dir ->
    let explicit = Filename.concat root "operator-events" in
    Unix.mkdir explicit 0o700;
    let open Yojson.Safe.Util in
    List.iter (fun (enabled, directory) ->
      let handoffs, result = run_startup_probe ~root ~base_path ~run_dir ~enabled ?directory () in
      Alcotest.(check int) "no default exec" 0 handoffs;
      Alcotest.(check string) "preparation succeeded" "ready" (result |> member "outcome" |> to_string);
      Alcotest.(check bool) "no default directory was created" false
        (Sys.file_exists (Filename.concat (Common.masc_dir_from_base_path ~base_path) "runtime"));
      match directory with
      | None -> Alcotest.(check bool) "disabled events have no ring" true ((result |> member "ring") = `Null)
      | Some expected -> Alcotest.(check string) "override retained exactly" expected
          (result |> member "directory" |> to_string))
      ["1", Some explicit; "1", Some ""; "0", None])

let test_startup_refuses_unusable_directory_and_exec () =
  with_startup_workspace (fun root base_path run_dir ->
    let runtime = Filename.concat (Common.masc_dir_from_base_path ~base_path) "runtime" in
    Fs_compat.mkdir_p (Filename.dirname runtime);
    let retained = Filename.concat root "outside" in
    Unix.mkdir retained 0o700;
    Unix.symlink retained runtime;
    let handoffs, result = run_startup_probe ~root ~base_path ~run_dir () in
    let open Yojson.Safe.Util in
    Alcotest.(check int) "handoff is prepared before directory effects" 1 handoffs;
    Alcotest.(check string) "symlink refuses startup" "directory_unavailable"
      (result |> member "outcome" |> to_string);
    Alcotest.(check int) "outside directory stayed empty" 0 (Array.length (Sys.readdir retained));
    Unix.unlink runtime;
    let _, result = run_startup_probe ~root ~base_path ~run_dir ~missing_executable:true () in
    Alcotest.(check string) "exec failure refuses startup" "exec_failed"
      (result |> member "outcome" |> to_string);
    Alcotest.(check bool) "failed exec leaves environment unchanged" true
      ((result |> member "directory") = `Null))

let () =
  match Sys.argv with
  | [| _; "--startup-probe"; base_path; run_dir; token; missing_executable |] ->
    startup_probe ~base_path ~run_dir ~token ~missing_executable:(bool_of_string missing_executable)
  | _ ->
  Alcotest.run "masc_runtime_events"
    [ ( "span-roundtrip"
      , [ Alcotest.test_case
            "emit_turn_start/emit_turn_end visible to in-process cursor"
            `Quick test_turn_span_roundtrip
        ] )
    ; ( "prune-stale-dumps"
      , [ Alcotest.test_case "removes dump of dead pid" `Quick
            test_prune_removes_dump_of_dead_pid
        ; Alcotest.test_case "keeps dump of live pid" `Quick
            test_prune_keeps_dump_of_live_pid
        ; Alcotest.test_case "ignores non-dump files" `Quick
            test_prune_ignores_non_dump_files
        ; Alcotest.test_case "rejects non-decimal pid stems" `Quick
            test_prune_rejects_non_decimal_pid_stems
        ; Alcotest.test_case "survives missing directory" `Quick
            test_prune_survives_missing_dir
        ] )
    ; ( "with_turn_span"
      , [ Alcotest.test_case "returns body result" `Quick
            test_with_turn_span_returns_body
        ; Alcotest.test_case "propagates body exception" `Quick
            test_with_turn_span_propagates_exn
        ] )
    ; ( "startup-directory"
      , [ Alcotest.test_case "workspace default reaches OCaml through exec" `Quick
            test_default_directory_survives_real_exec
        ; Alcotest.test_case "operator directory and disabled events retain authority" `Quick
            test_explicit_and_disabled_directory_authority
        ; Alcotest.test_case "unsafe directory and failed exec refuse startup" `Quick
            test_startup_refuses_unusable_directory_and_exec
        ] )
      (* Last group on purpose: it sets OCAML_RUNTIME_EVENTS_PRESERVE and the
         stdlib cannot unset it, so any prune case after this would be skipped
         by the guard and pass vacuously. *)
    ; ( "prune-preserve-env"
      , [ Alcotest.test_case "honors OCAML_RUNTIME_EVENTS_PRESERVE" `Quick
            test_prune_honors_preserve_env_runs_last
        ] )
    ]
