(** The newest row of a Keeper's decision record is kept in memory, and the
    record's writer moves it ([Keeper_row_facts]).

    This executable stands for the server: it says it holds the workspace's
    writer lease before any test runs.

    The reader is [Keeper_runtime_trust_snapshot.latest_decision_json], the
    writer is [Keeper_types_support.append_decision_record], and what the
    file says is [Keeper_runtime_trust_snapshot.latest_decision_result], the
    read the kept row is filled with.

    What is pinned:

    1. Once read, the row comes from memory: the reader answers with the
       file gone, until the removal is told.
    2. An appended row replaces the kept one, also across a rotation.
    3. A row a read is not sure to answer with (not an object, or as long as
       the reader's window) is not kept: the next reader reads the file.
    4. An append that fails, and a file that cannot be read, keep nothing.
    5. Two spellings of one record reach one kept row. A record that comes
       to exist under another name than the one its cell was chosen by, and
       a name remembered across a rotation or a failed write, are not held
       against the file.
    6. A writer that another writer overtook leaves nothing kept.
    7. Over 300 random steps the kept row is the row the file gives.
    8. A kept row is answered without the fiber giving up its turn: asking
       for the record's path looks at no file. *)

open Alcotest
open Masc
module Trust = Keeper_runtime_trust_snapshot

let keeper_name = "decision-kept"

let with_workspace f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Filename.temp_dir "keeper_decision_kept_" "" in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree base_path)
    (fun () -> f (Workspace.default_config base_path))
;;

let with_max_bytes value f =
  let name = "MASC_KEEPER_METRICS_MAX_BYTES" in
  let before = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () -> Unix.putenv name (Option.value before ~default:"10485760"))
    f
;;

let path config = Keeper_types_support.keeper_decision_log_path config keeper_name
let row turn = `Assoc [ "turn_id", `Int turn ]
let append config json = Keeper_types_support.append_decision_record config keeper_name json

(* A row whose line on disk, newline counted, is [bytes] long. *)
let row_of_bytes turn bytes =
  let padded pad = `Assoc [ "turn_id", `Int turn; "pad", `String pad ] in
  let bare = String.length (Yojson.Safe.to_string (padded "")) + 1 in
  padded (String.make (bytes - bare) 'p')
;;

let by_hand config text =
  Fs_compat.mkdir_p (Filename.dirname (path config));
  Out_channel.with_open_gen
    [ Open_wronly; Open_append; Open_creat; Open_binary ]
    0o644
    (path config)
    (fun channel -> output_string channel text)
;;

let remove_by_hand config = if Sys.file_exists (path config) then Sys.remove (path config)

let turn_of = function
  | None -> "no row"
  | Some json ->
    (match Yojson.Safe.Util.member "turn_id" json with
     | `Int turn -> Printf.sprintf "turn %d" turn
     | `Null | `Bool _ | `Intlit _ | `Float _ | `String _ | `Assoc _ | `List _ ->
       "a row without a turn")
;;

(* What the reader shows. *)
let shown config = turn_of (Trust.latest_decision_json ~config ~keeper_name)

(* What the file says. *)
let in_the_file config =
  match Trust.latest_decision_result ~config ~keeper_name with
  | Ok row -> turn_of row
  | Error _ -> "the file could not be read"
;;

(* What is kept, asked without a read of the file: the read given here fails,
   and it runs only when nothing is kept. *)
let kept_at path =
  match Keeper_row_facts.newest_decision ~path ~read:(fun () -> Error ()) with
  | Fact_cell.Held row -> "kept: " ^ turn_of row
  | Fact_cell.Read_failed () -> "nothing kept"
  | Fact_cell.Read_and_kept _ | Fact_cell.Read_not_kept _ ->
    fail "a read that fails gave a value"
;;

let kept config = kept_at (path config)

(* The second answer has to come from memory: the file it would read is
   gone. Once the removal is told the reader reads again and finds no file. *)
let test_a_kept_row_is_read_without_the_file () =
  with_workspace (fun config ->
    check string "no record yet" "no row" (shown config);
    check string "and that is kept" "kept: no row" (kept config);
    append config (row 1);
    check string "the writer moves a kept answer of no row" "kept: turn 1" (kept config);
    remove_by_hand config;
    check string "the row, with the file gone" "turn 1" (shown config);
    Keeper_row_facts.decision_records_removed ();
    check string "nothing is kept once the removal is told" "nothing kept" (kept config);
    check string "and the reader finds no file" "no row" (shown config))
;;

let test_an_appended_row_replaces_the_kept_one () =
  with_workspace (fun config ->
    append config (row 1);
    check string "the first row" "turn 1" (shown config);
    append config (row 2);
    remove_by_hand config;
    check string "the appended row, with the file gone" "turn 2" (shown config))
;;

(* The threshold makes every append rotate a file that has a row. The row
   written after the rotation is the only row of the new file. *)
let test_a_row_appended_after_a_rotation () =
  with_workspace (fun config ->
    append config (row 1);
    check string "the first row" "turn 1" (shown config);
    with_max_bytes "1" (fun () -> append config (row 2));
    check bool "the file was rotated" true (Sys.file_exists (path config ^ ".1"));
    check string "the row is kept" "kept: turn 2" (kept config);
    check string "and it is what the file says" "turn 2" (in_the_file config))
;;

(* The reader passes over a row that is not an object and answers with the
   object before it. The writer does not work that out: it forgets, and the
   next reader reads the file. *)
let test_a_row_that_is_not_an_object_is_not_kept () =
  with_workspace (fun config ->
    append config (row 1);
    check string "the first row" "turn 1" (shown config);
    append config (`List [ `Int 2 ]);
    check string "nothing is kept after it" "nothing kept" (kept config);
    check string "the reader reads the object before it" "turn 1" (shown config);
    check string "and keeps that" "kept: turn 1" (kept config))
;;

(* The longest row that is kept is one byte shorter than the reader's
   window: the newline before it is then the window's first byte, and the
   file read finds the row. One byte more and the window starts at the row's
   first byte. The file read drops the row as the piece its window may have
   cut, so the writer keeps nothing. A row longer than the window is not a
   row the reader finds either. *)
let test_how_long_a_kept_row_can_be () =
  with_workspace (fun config ->
    let longest = Keeper_row_facts.decision_window_bytes - 1 in
    append config (row 1);
    check string "the first row" "turn 1" (shown config);
    append config (row_of_bytes 2 longest);
    check string "a row one byte shorter than the window is kept" "kept: turn 2" (kept config);
    check string "and is what the file says" "turn 2" (in_the_file config);
    append config (row_of_bytes 3 (longest + 1));
    check string "a row as long as the window is not" "nothing kept" (kept config);
    check
      bool
      "the file read does not find that row"
      false
      (String.equal (in_the_file config) "turn 3");
    check string "the reader answers as the file" (in_the_file config) (shown config);
    append config (row_of_bytes 4 (Keeper_row_facts.decision_window_bytes + 5_000));
    check string "nothing is kept after a row longer than the window" "nothing kept" (kept config);
    check string "the reader answers as the file" (in_the_file config) (shown config))
;;

(* Everything the reader's window holds before the row is blank. The piece
   the reader drops is the one its window cut, which is blank here, and the
   row is the file's last line: what is kept is what the file says. The
   writer moves a kept row and leaves a cell no read has filled as it is, so
   the record is read once before the row is appended. *)
let test_a_row_behind_a_blank_run_is_what_the_file_says () =
  with_workspace (fun config ->
    by_hand config (String.make Keeper_row_facts.decision_window_bytes ' ' ^ "\n");
    check string "a record of blanks holds no row" "no row" (shown config);
    check string "and that is kept" "kept: no row" (kept config);
    append config (row 1);
    check string "the row is kept" "kept: turn 1" (kept config);
    check string "and is what the file says" "turn 1" (in_the_file config))
;;

(* The rotation refuses a backup that is a directory and raises before the
   row is written. *)
let test_an_append_that_fails_keeps_nothing () =
  with_workspace (fun config ->
    append config (row 1);
    check string "the first row" "turn 1" (shown config);
    Unix.mkdir (path config ^ ".1") 0o755;
    (match with_max_bytes "1" (fun () -> append config (row 2)) with
     | () -> fail "the append went through a backup that is a directory"
     | exception Sys_error _ -> ());
    check string "nothing is kept" "nothing kept" (kept config);
    check string "the reader answers as the file" (in_the_file config) (shown config))
;;

(* The record's path is a directory. The read fails, the reader answers with
   no row as it did, and that answer is not kept. *)
let test_a_record_that_cannot_be_read_keeps_nothing () =
  with_workspace (fun config ->
    Fs_compat.mkdir_p (Filename.dirname (path config));
    Unix.mkdir (path config) 0o755;
    Out_channel.with_open_text (Filename.concat (path config) "child") (fun channel ->
      output_string channel "x");
    check string "the file" "the file could not be read" (in_the_file config);
    check string "the reader" "no row" (shown config);
    check string "nothing is kept" "nothing kept" (kept config))
;;

(* How many turns a fiber that is ready to run gets while [read] is called
   fifty times. Fibers of one domain take turns only where one of them
   waits, so a read that never waits gives the fiber beside it none. A read
   that asks the file system through Eio waits for a worker thread, and the
   fiber beside it runs. *)
let turns_of_a_fiber_beside read =
  Eio.Switch.run
  @@ fun sw ->
  let turns = ref 0 in
  let stop = ref false in
  Eio.Fiber.fork ~sw (fun () ->
    while not !stop do
      incr turns;
      Eio.Fiber.yield ()
    done);
  Eio.Fiber.yield ();
  let before = !turns in
  for _ = 1 to 50 do
    read ()
  done;
  let during = !turns - before in
  stop := true;
  during
;;

(* The record's path used to look whether the keepers directory was there,
   through Eio, each time a reader asked for it. *)
let test_a_kept_row_is_answered_without_waiting () =
  with_workspace (fun config ->
    append config (row 1);
    check string "read and kept" "turn 1" (shown config);
    check string "kept" "kept: turn 1" (kept config);
    check
      int
      "the fiber beside got no turn"
      0
      (turns_of_a_fiber_beside (fun () -> check string "held" "turn 1" (shown config))))
;;

(* --- a record written and read by hand ----------------------------------
   [Keeper_row_facts] around plain file calls, on paths of the test's own. *)

let with_directory f =
  let directory = Filename.temp_dir "keeper_decision_paths_" "" in
  let rec remove path =
    match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR ->
      Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
    | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK ->
      Unix.unlink path
  in
  Fun.protect ~finally:(fun () -> remove directory) (fun () -> f directory)
;;

let write_line path text =
  Out_channel.with_open_gen
    [ Open_wronly; Open_append; Open_creat; Open_binary ]
    0o644
    path
    (fun channel -> output_string channel text)
;;

(* The writer of [turn]'s row. [write] is given the call that puts the row in
   the file and says what the append was. *)
let appending path turn write =
  let row = Yojson.Safe.to_string (row turn) in
  Keeper_row_facts.appending_decision ~path ~row (fun () ->
    write (fun () -> write_line path (row ^ "\n")))
;;

let append_at path turn =
  appending path turn (fun write_the_row ->
    write_the_row ();
    Keeper_row_facts.To_the_file_there)
;;

(* A reader that found [found] in the file. *)
let fill_at path found =
  match Keeper_row_facts.newest_decision ~path ~read:(fun () -> Ok found) with
  | Fact_cell.Held _ | Fact_cell.Read_and_kept _ -> ()
  | Fact_cell.Read_not_kept _ -> fail "the cell changed during a read with no writer"
  | Fact_cell.Read_failed (_ : unit) -> fail "the read failed"
;;

let record_in directory = Filename.concat directory "alpha.decisions.jsonl"

(* The record's path with a piece that is ".": another spelling of it. *)
let through_a_dot path =
  Filename.concat (Filename.concat (Filename.dirname path) ".") (Filename.basename path)
;;

(* [link] is a symbolic link to the directory that holds the record. A row
   appended through one spelling moves the row kept through the other. *)
let test_two_spellings_of_a_record_are_one_kept_row () =
  with_directory (fun directory ->
    let real = Filename.concat directory "real" in
    let link = Filename.concat directory "link" in
    Unix.mkdir real 0o755;
    Unix.symlink real link;
    let spelled = record_in real in
    let through_link = record_in link in
    append_at spelled 1;
    fill_at through_link (Some (row 1));
    check string "kept through the link" "kept: turn 1" (kept_at through_link);
    check string "and through the other spelling" "kept: turn 1" (kept_at spelled);
    append_at spelled 2;
    check string "a row through one spelling" "kept: turn 2" (kept_at spelled);
    check string "moves the row of the other" "kept: turn 2" (kept_at through_link))
;;

(* The spellings a record can be reached by, each asked after a row went in
   through the plain one: a piece that is ".", a doubled "/", a path relative
   to the working directory, a link to the directory, and another letter
   case. A spelling that is the record (the same device and inode) reaches
   its kept row, and no other spelling does. The letter case follows the file
   system. Then a row written through one spelling is read through another. *)
let test_every_spelling_of_a_record_reaches_its_kept_row () =
  with_directory (fun directory ->
    let real = Filename.concat directory "real" in
    let link = Filename.concat directory "link" in
    Unix.mkdir real 0o755;
    Unix.symlink real link;
    let record = record_in real in
    let relative =
      let pieces =
        String.split_on_char '/' (Sys.getcwd ()) |> List.filter (fun piece -> piece <> "")
      in
      String.concat "/" (List.map (fun _ -> "..") pieces) ^ record
    in
    let spellings =
      [ "a piece that is \".\"", through_a_dot record
      ; "a doubled \"/\"", real ^ "//" ^ Filename.basename record
      ; "relative to the working directory", relative
      ; "a link to the directory", record_in link
      ; "another letter case", Filename.concat real "ALPHA.decisions.jsonl"
      ]
    in
    append_at record 1;
    fill_at record (Some (row 1));
    let identity path =
      match Unix.stat path with
      | stats -> Some (stats.Unix.st_dev, stats.Unix.st_ino)
      | exception Unix.Unix_error (_, _, _) -> None
    in
    let is_the_record path = Option.is_some (identity path) && identity path = identity record in
    List.iter
      (fun (label, spelling) ->
         check
           string
           label
           (if is_the_record spelling then "kept: turn 1" else "nothing kept")
           (kept_at spelling))
      spellings;
    check bool "the relative spelling is relative" true (Filename.is_relative relative);
    check bool "and it is the record" true (is_the_record relative);
    append_at (through_a_dot record) 2;
    check string "a row through another spelling" "kept: turn 2" (kept_at record))
;;

(* The record's path is a link to a file that is not there yet. A reader
   that spells the link's target keeps "no row" in the cell of that name. The
   writer spells the record's path, which the file system names by the link
   itself while the target is missing: another cell. The write makes the
   target, so the row went by the reader's cell unseen, and what both cells
   keep is forgotten. *)
let test_a_record_made_through_a_link_to_a_missing_file () =
  with_directory (fun directory ->
    let record = record_in directory in
    let target = Filename.concat directory "target.jsonl" in
    Unix.symlink target record;
    fill_at target None;
    check string "no row is kept under the target's name" "kept: no row" (kept_at target);
    append_at record 1;
    check bool "the write made the target" true (Sys.file_exists target);
    check string "the target's kept answer is forgotten" "nothing kept" (kept_at target);
    check string "and nothing is kept by the record's spelling" "nothing kept" (kept_at record))
;;

(* The record's path is a link to a file. The rotation renames the link away
   and the row after it makes a regular file at the record's path: the path
   is another file now, under another name. The names remembered go with the
   rotation, so the writer's spelling is asked about again and its next row
   moves the row kept by a spelling first asked after the rotation.

   The writer is the real one, which says whether it rotated. *)
let test_a_rotation_forgets_the_names_remembered () =
  with_workspace (fun config ->
    let record = path config in
    let target = Filename.concat (Filename.dirname record) "target.jsonl" in
    Fs_compat.mkdir_p (Filename.dirname record);
    write_line target (Yojson.Safe.to_string (row 0) ^ "\n");
    Unix.symlink target record;
    check string "the row of the link's target" "turn 0" (shown config);
    with_max_bytes "1" (fun () -> append config (row 1));
    check
      bool
      "the rotation moved the link away"
      true
      (match (Unix.lstat (record ^ ".1")).Unix.st_kind with
       | Unix.S_LNK -> true
       | Unix.S_REG | Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK ->
         false);
    let asked_after = through_a_dot record in
    (match
       Keeper_row_facts.newest_decision ~path:asked_after ~read:(fun () ->
         Trust.latest_decision_result ~config ~keeper_name)
     with
     | Fact_cell.Read_and_kept found ->
       check string "a spelling first asked after the rotation" "turn 1" (turn_of found)
     | Fact_cell.Held _ | Fact_cell.Read_not_kept _ | Fact_cell.Read_failed _ ->
       fail "the spelling asked after the rotation did not read the file");
    append config (row 2);
    check string "the next row moves that spelling's kept row" "kept: turn 2" (kept_at asked_after);
    check string "and it is what the file says" "turn 2" (in_the_file config))
;;

(* The writer renames the record's link away and then fails. Whether a failed
   append rotated is not known, so the names remembered go as they do after
   a rotation. The record is then made again as a regular file, and a row
   written through the writer's spelling moves the row kept by another
   spelling of it. *)
let test_a_write_that_fails_after_its_rotation () =
  with_directory (fun directory ->
    let record = record_in directory in
    let target = Filename.concat directory "target.jsonl" in
    let asked_after = through_a_dot record in
    write_line target (Yojson.Safe.to_string (row 0) ^ "\n");
    Unix.symlink target record;
    fill_at record (Some (row 0));
    (match
       appending record 1 (fun (_ : unit -> unit) ->
         Unix.rename record (record ^ ".1");
         raise (Sys_error "the write failed"))
     with
     | () -> fail "the append did not fail"
     | exception Sys_error _ -> ());
    check string "nothing is kept after the failure" "nothing kept" (kept_at record);
    append_at record 1;
    fill_at asked_after (Some (row 1));
    append_at record 2;
    check string "the next row moves the other spelling's kept row" "kept: turn 2" (kept_at asked_after))
;;

(* Two writers of one record. The first has looked at the kept row and put
   its row in the file when the second writes a row after it and moves the
   kept row. The first then finds the kept row is no longer the one it
   looked at, and what is kept is forgotten: its own row is not the file's
   last. *)
let test_a_writer_that_another_writer_overtook () =
  with_directory (fun directory ->
    let record = record_in directory in
    append_at record 1;
    fill_at record (Some (row 1));
    appending record 2 (fun write_the_row ->
      write_the_row ();
      append_at record 3;
      check string "the second writer's row is kept" "kept: turn 3" (kept_at record);
      Keeper_row_facts.To_the_file_there);
    check string "the first writer leaves nothing kept" "nothing kept" (kept_at record))
;;

let steps = 300

(* Rows of every kind, rotations, and changes made by hand and told, in a
   random order. After each step: a kept row is the row the file gives, and
   the reader answers as the file. *)
let test_the_kept_row_is_the_files_over_random_steps () =
  with_workspace (fun config ->
    let random = Random.State.make [| 53_232 |] in
    let longest = Keeper_row_facts.decision_window_bytes - 1 in
    let turn = ref 0 in
    let next () =
      incr turn;
      !turn
    in
    for step = 1 to steps do
      let label = Printf.sprintf "step %d" step in
      (match Random.State.int random 13 with
       | 0 | 1 | 2 | 3 -> append config (row (next ()))
       | 4 -> append config (`List [ `Int (next ()) ])
       | 5 -> append config (row_of_bytes (next ()) longest)
       | 6 -> append config (row_of_bytes (next ()) (longest + 1))
       | 7 ->
         append
           config
           (row_of_bytes (next ()) (Keeper_row_facts.decision_window_bytes + 5_000))
       | 8 -> with_max_bytes "1" (fun () -> append config (row (next ())))
       | 9 ->
         by_hand config "{\"turn_id\": \n";
         Keeper_row_facts.decision_records_removed ()
       | 10 ->
         remove_by_hand config;
         Keeper_row_facts.decision_records_removed ()
       | 11 ->
         (* A row cut short, with no newline: what a write that stopped part
            way and was not taken back leaves. *)
         by_hand config "{\"turn_id\":";
         Keeper_row_facts.decision_records_removed ()
       | _ -> ignore (shown config));
      let file = in_the_file config in
      (match kept config with
       | "nothing kept" -> ()
       | kept -> check string (label ^ ": the kept row is the file's") ("kept: " ^ file) kept);
      check string (label ^ ": the reader answers as the file") file (shown config)
    done)
;;

let () =
  Fact_cell.keep_in_this_process ();
  run
    "keeper_decision_row_kept"
    [ ( "the newest decision row is kept by its writer"
      , [ test_case
            "a kept row is read without the file"
            `Quick
            test_a_kept_row_is_read_without_the_file
        ; test_case
            "an appended row replaces the kept one"
            `Quick
            test_an_appended_row_replaces_the_kept_one
        ; test_case
            "a row appended after a rotation"
            `Quick
            test_a_row_appended_after_a_rotation
        ; test_case
            "a row that is not an object is not kept"
            `Quick
            test_a_row_that_is_not_an_object_is_not_kept
        ; test_case "how long a kept row can be" `Quick test_how_long_a_kept_row_can_be
        ; test_case
            "a row behind a blank run is what the file says"
            `Quick
            test_a_row_behind_a_blank_run_is_what_the_file_says
        ; test_case
            "an append that fails keeps nothing"
            `Quick
            test_an_append_that_fails_keeps_nothing
        ; test_case
            "a record that cannot be read keeps nothing"
            `Quick
            test_a_record_that_cannot_be_read_keeps_nothing
        ; test_case
            "a kept row is answered without waiting"
            `Quick
            test_a_kept_row_is_answered_without_waiting
        ; test_case
            "two spellings of a record are one kept row"
            `Quick
            test_two_spellings_of_a_record_are_one_kept_row
        ; test_case
            "every spelling of a record reaches its kept row"
            `Quick
            test_every_spelling_of_a_record_reaches_its_kept_row
        ; test_case
            "a record made through a link to a missing file"
            `Quick
            test_a_record_made_through_a_link_to_a_missing_file
        ; test_case
            "a rotation forgets the names remembered"
            `Quick
            test_a_rotation_forgets_the_names_remembered
        ; test_case
            "a write that fails after its rotation"
            `Quick
            test_a_write_that_fails_after_its_rotation
        ; test_case
            "a writer that another writer overtook"
            `Quick
            test_a_writer_that_another_writer_overtook
        ; test_case
            "the kept row is the file's over random steps"
            `Quick
            test_the_kept_row_is_the_files_over_random_steps
        ] )
    ]
;;
