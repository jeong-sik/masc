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
    3. A row a read is not sure to answer with (not an object, or longer than
       half the reader's window) is not kept: the next reader reads the file.
    4. An append that fails, and a file that cannot be read, keep nothing.
    5. Two spellings of one record reach one kept row.
    6. Over 300 random steps the kept row is the row the file gives. *)

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

(* A row of half the reader's window is kept. One byte more and the writer
   forgets. A row longer than the window is not a row the reader finds at
   all. *)
let test_how_long_a_kept_row_can_be () =
  with_workspace (fun config ->
    let half = Keeper_row_facts.decision_window_bytes / 2 in
    append config (row 1);
    check string "the first row" "turn 1" (shown config);
    append config (row_of_bytes 2 half);
    check string "half the window is kept" "kept: turn 2" (kept config);
    check string "and is what the file says" "turn 2" (in_the_file config);
    append config (row_of_bytes 3 (half + 1));
    check string "one byte more is not" "nothing kept" (kept config);
    check string "the reader reads it from the file" "turn 3" (shown config);
    append config (row_of_bytes 4 (Keeper_row_facts.decision_window_bytes + 5_000));
    check string "nothing is kept after a row longer than the window" "nothing kept" (kept config);
    check string "the reader answers as the file" (in_the_file config) (shown config))
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
    Unix.mkdir (path config) 0o755;
    Out_channel.with_open_text (Filename.concat (path config) "child") (fun channel ->
      output_string channel "x");
    check string "the file" "the file could not be read" (in_the_file config);
    check string "the reader" "no row" (shown config);
    check string "nothing is kept" "nothing kept" (kept config))
;;

(* [link] is a symbolic link to the directory that holds the record. A row
   appended through one spelling moves the row kept through the other. *)
let test_two_spellings_of_a_record_are_one_kept_row () =
  let directory = Filename.temp_dir "keeper_decision_spellings_" "" in
  let real = Filename.concat directory "real" in
  let link = Filename.concat directory "link" in
  Unix.mkdir real 0o755;
  Unix.symlink real link;
  let spelled = Filename.concat real "alpha.decisions.jsonl" in
  let through_link = Filename.concat link "alpha.decisions.jsonl" in
  let append path turn =
    let row = Yojson.Safe.to_string (row turn) in
    Keeper_row_facts.appending_decision ~path ~row (fun () ->
      Out_channel.with_open_gen
        [ Open_wronly; Open_append; Open_creat; Open_binary ]
        0o644
        path
        (fun channel -> output_string channel (row ^ "\n"));
      Keeper_row_facts.To_the_file_there)
  in
  let fill path turn =
    match Keeper_row_facts.newest_decision ~path ~read:(fun () -> Ok (Some (row turn))) with
    | Fact_cell.Held _ | Fact_cell.Read_and_kept _ -> ()
    | Fact_cell.Read_not_kept _ -> fail "the cell changed during a read with no writer"
    | Fact_cell.Read_failed (_ : unit) -> fail "the read failed"
  in
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun path -> if Sys.file_exists path then Sys.remove path) [ spelled ];
      Unix.unlink link;
      Unix.rmdir real;
      Unix.rmdir directory)
    (fun () ->
      append spelled 1;
      fill through_link 1;
      check string "kept through the link" "kept: turn 1" (kept_at through_link);
      check string "and through the other spelling" "kept: turn 1" (kept_at spelled);
      append spelled 2;
      check string "a row through one spelling" "kept: turn 2" (kept_at spelled);
      check string "moves the row of the other" "kept: turn 2" (kept_at through_link))
;;

let steps = 300

(* Rows of every kind, rotations, and changes made by hand and told, in a
   random order. After each step: a kept row is the row the file gives, and
   the reader answers as the file. *)
let test_the_kept_row_is_the_files_over_random_steps () =
  with_workspace (fun config ->
    let random = Random.State.make [| 53_232 |] in
    let half = Keeper_row_facts.decision_window_bytes / 2 in
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
       | 5 -> append config (row_of_bytes (next ()) half)
       | 6 -> append config (row_of_bytes (next ()) (half + 1))
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
            "an append that fails keeps nothing"
            `Quick
            test_an_append_that_fails_keeps_nothing
        ; test_case
            "a record that cannot be read keeps nothing"
            `Quick
            test_a_record_that_cannot_be_read_keeps_nothing
        ; test_case
            "two spellings of a record are one kept row"
            `Quick
            test_two_spellings_of_a_record_are_one_kept_row
        ; test_case
            "the kept row is the file's over random steps"
            `Quick
            test_the_kept_row_is_the_files_over_random_steps
        ] )
    ]
;;
