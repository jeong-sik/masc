(** The facts [Dated_jsonl] keeps in memory about a store ([read_fact]).

    The files are the authority. Every test compares a fact with the strict
    read of the files it stands for, and looks at how the answer was come by:
    [Held] means no file was read. The last row stands for
    [read_recent_result t 1], and the newest row that is JSON for
    [find_latest_entry_result] selecting every [Parsed] row.

    This executable stands for the server: it says it is the one process
    that writes the stores before any test runs. What a process that has not
    said so reads is pinned in [test_dated_jsonl].

    What is pinned:

    1. A reader fills the fact and later readers open no file. A reader
       takes no lock of the store.
    2. An append moves a kept fact over its row and fills nothing.
    3. Whatever removes files forgets the fact: a prune, an append's own
       byte-budget prune, an append that failed or was cancelled, a removal
       told with [directories_removed].
    4. A row that the store's newest file does not hold is not taken for the
       newest row. The rule is also tried as a table, with no file and no
       clock.
    5. One directory has one fact, whichever spelling reached it. A
       spelling is asked about again after a removal, and by an append whose
       directory was not there when it began or that a removal overlapped.
    6. Each read is counted by how its value was come by.
    7. The newest row that is JSON passes over rows that are not, in its own
       file and in later ones, and an append moves it from its own row's
       file. *)

open Alcotest
module D = Dated_jsonl

let counter = ref 0

let tmpdir prefix =
  incr counter;
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "%s_%d_%d_%.0f"
         prefix
         !counter
         (Unix.getpid ())
         (Unix.gettimeofday ()))
  in
  Fs_compat.mkdir_p dir;
  dir
;;

(* A store whose facts the lease holder keeps ([Store.facts]). *)
let kept_store root = D.Store.(keeper root ~keeper:"kept" Keeper.Turn_records)
let location_under root = kept_store (D.Store.root_of_masc_dir root)
let temp_location prefix = location_under (tmpdir prefix)
let row number = `Assoc [ "row", `Int number ]

let equal_entry left right =
  match left, right with
  | D.Parsed left, D.Parsed right -> Yojson.Safe.equal left right
  | D.Malformed_json left, D.Malformed_json right ->
    String.equal left.path right.path
    && Option.equal Int.equal left.line_number right.line_number
    && String.equal left.detail right.detail
  | D.Parsed _, D.Malformed_json _ | D.Malformed_json _, D.Parsed _ -> false
;;

let pp_entry formatter = function
  | D.Parsed json -> Format.fprintf formatter "Parsed %s" (Yojson.Safe.to_string json)
  | D.Malformed_json { path; detail; _ } ->
    Format.fprintf formatter "Malformed_json %s: %s" path detail
;;

let entry = testable pp_entry equal_entry

let pp_row formatter = function
  | None -> Format.pp_print_string formatter "no row"
  | Some row -> pp_entry formatter row
;;

(* How a fact was come by, with a failed read as its message. *)
type answer =
  | Held of D.recent_entry option
  | Read_and_kept of D.recent_entry option
  | Read_not_kept of D.recent_entry option
  | Read_failed of string

let answer =
  let pp formatter = function
    | Held value -> Format.fprintf formatter "Held %a" pp_row value
    | Read_and_kept value ->
      Format.fprintf formatter "Read_and_kept %a" pp_row value
    | Read_not_kept value ->
      Format.fprintf formatter "Read_not_kept %a" pp_row value
    | Read_failed message -> Format.fprintf formatter "Read_failed %s" message
  in
  let equal left right =
    match left, right with
    | Held left, Held right
    | Read_and_kept left, Read_and_kept right
    | Read_not_kept left, Read_not_kept right -> Option.equal equal_entry left right
    | Read_failed left, Read_failed right -> String.equal left right
    | (Held _ | Read_and_kept _ | Read_not_kept _ | Read_failed _), _ -> false
  in
  testable pp equal
;;

let last_row store =
  match D.read_fact store D.last_row with
  | Fact_cell.Held value -> Held value
  | Fact_cell.Read_and_kept value -> Read_and_kept value
  | Fact_cell.Read_not_kept value -> Read_not_kept value
  | Fact_cell.Read_failed error -> Read_failed (D.read_error_to_string error)
;;

(* The strict read the fact stands for. *)
let newest_row_in_the_files store =
  match D.read_recent_result store 1 with
  | Ok rows -> Ok (List.nth_opt (List.rev rows) 0)
  | Error error -> Error (D.read_error_to_string error)
;;

let value_of = function
  | Held value | Read_and_kept value | Read_not_kept value -> Ok value
  | Read_failed message -> Error message
;;

let check_the_fact_is_the_files label store =
  check
    (result (option entry) string)
    label
    (newest_row_in_the_files store)
    (value_of (last_row store))
;;

(* The newest row that is JSON, as an [answer]: its rows are all [Parsed]. *)
let newest_parsed_row store =
  let parsed = Option.map (fun json -> D.Parsed json) in
  match D.read_fact store D.newest_parsed_row with
  | Fact_cell.Held value -> Held (parsed value)
  | Fact_cell.Read_and_kept value -> Read_and_kept (parsed value)
  | Fact_cell.Read_not_kept value -> Read_not_kept (parsed value)
  | Fact_cell.Read_failed error -> Read_failed (D.read_error_to_string error)
;;

(* The strict read that fact stands for. *)
let newest_parsed_row_in_the_files store =
  D.find_latest_entry_result store (function
    | D.Parsed _ as row -> Some row
    | D.Malformed_json _ -> None)
  |> Result.map_error D.read_error_to_string
;;

let check_the_newest_parsed_row_is_the_files label store =
  check
    (result (option entry) string)
    label
    (newest_parsed_row_in_the_files store)
    (value_of (newest_parsed_row store))
;;

(* Text put into the day file of [ts] behind the store's back. *)
let write_behind_the_store location ~ts text =
  let dated = D.Store.dated_path location ~ts in
  Fs_compat.mkdir_p (Filename.dirname dated.path);
  Out_channel.with_open_gen
    [ Open_wronly; Open_creat; Open_append; Open_binary ]
    0o644
    dated.path
    (fun channel -> output_string channel text);
  dated.path
;;

let day = 86_400.
let now () = Unix.gettimeofday ()

(* --- 1. a reader fills the fact --------------------------------------- *)

let test_a_store_without_rows () =
  let store = D.open_store (temp_location "djkf_empty") in
  check answer "the first read reads the files" (Read_and_kept None) (last_row store);
  check answer "the second is handed the answer" (Held None) (last_row store)
;;

let test_later_readers_open_no_file () =
  let location = temp_location "djkf_no_file" in
  let store = D.open_store location in
  D.append store (row 1);
  D.append store (row 2);
  check answer "the first read reads the files" (Read_and_kept (Some (D.Parsed (row 2)))) (last_row store);
  (* The day file goes, and nobody is told. A reader that opened a file
     would now find no row. *)
  D.prepare_for_directory_removal store;
  Sys.remove (D.Store.dated_path_now location).path;
  check answer "the second read opens no file" (Held (Some (D.Parsed (row 2)))) (last_row store);
  D.directories_removed ();
  check answer "a removal that is told is read again" (Read_and_kept None) (last_row store)
;;

let test_a_store_that_cannot_be_read_keeps_nothing () =
  let location = temp_location "djkf_unreadable" in
  let store = D.open_store location in
  D.append store (row 1);
  (* An entry beside the month directories that the store does not declare
     fails the strict listing. *)
  let foreign = Filename.concat (D.Store.dir location) "not-a-month" in
  Out_channel.with_open_text foreign (fun channel -> output_string channel "x");
  let failed = function
    | Read_failed _ -> true
    | Held _ | Read_and_kept _ | Read_not_kept _ -> false
  in
  check bool "the read fails" true (failed (last_row store));
  check bool "and fails again: no row was made of it" true (failed (last_row store));
  Sys.remove foreign;
  check answer "once it can be read it is" (Read_and_kept (Some (D.Parsed (row 1)))) (last_row store)
;;

let test_a_row_that_is_not_json () =
  let location = temp_location "djkf_malformed" in
  let store = D.open_store location in
  D.append store (row 1);
  let path = write_behind_the_store location ~ts:(now ()) "{\"cut\": \n" in
  D.directories_removed ();
  (match last_row store with
   | Read_and_kept (Some (D.Malformed_json { path = reported; _ })) ->
     check string "the row's file" path reported
   | other -> failf "expected the malformed row, got %a" (pp answer) other);
  check_the_fact_is_the_files "as the strict read reports it" store;
  D.append store (row 2);
  check answer "the next row replaces it" (Held (Some (D.Parsed (row 2)))) (last_row store)
;;

(* A reader takes no lock of the store, so it fills the fact while a writer
   holds the store's mutex. A reader that waited for the mutex would not come
   back from this test. *)
let test_a_reader_fills_while_the_store_is_locked () =
  let store = D.open_store (temp_location "djkf_locked") in
  D.append store (row 1);
  let filled =
    Cross_context_mutex.with_lock (D.For_testing.cross_context_mutex store) (fun () ->
      last_row store)
  in
  check answer "filled under the writer's lock" (Read_and_kept (Some (D.Parsed (row 1)))) filled
;;

(* --- 2. an append moves the fact -------------------------------------- *)

let test_an_append_moves_the_fact () =
  let store = D.open_store (temp_location "djkf_append") in
  D.append store (row 1);
  ignore (last_row store : answer);
  D.append store (row 2);
  check answer "no file is read for the new row" (Held (Some (D.Parsed (row 2)))) (last_row store);
  check_the_fact_is_the_files "and it is the files' newest row" store
;;

(* The value is the text on disk read back, not the tree that was handed in:
   the two differ for a tree JSON text cannot carry. *)
let test_the_fact_is_the_row_as_it_is_read () =
  let store = D.open_store (temp_location "djkf_read_back") in
  ignore (last_row store : answer);
  D.append store (`Assoc [ "n", `Intlit "7" ]);
  check answer "the literal comes back as a number" (Held (Some (D.Parsed (`Assoc [ "n", `Int 7 ])))) (last_row store);
  check_the_fact_is_the_files "as the strict read reads it" store
;;

let test_an_append_fills_nothing () =
  let store = D.open_store (temp_location "djkf_no_fill") in
  D.append store (row 1);
  check answer "a store nobody read has no fact" (Read_and_kept (Some (D.Parsed (row 1)))) (last_row store);
  D.directories_removed ();
  D.append store (row 2);
  check answer "a forgotten fact is not made by an append" (Read_and_kept (Some (D.Parsed (row 2)))) (last_row store)
;;

(* Whoever the acknowledgement wakes reads the fact with the row in it. *)
let test_the_fact_moves_before_the_acknowledgement () =
  let store = D.open_store (temp_location "djkf_ack") in
  ignore (last_row store : answer);
  let seen_at_the_acknowledgement = ref None in
  D.append_notifying_commit store (row 1) ~on_committed:(fun () ->
    seen_at_the_acknowledgement := Some (last_row store));
  check
    (option answer)
    "the acknowledged row is the fact"
    (Some (Held (Some (D.Parsed (row 1)))))
    !seen_at_the_acknowledgement
;;

let test_rotating_the_current_file_out_keeps_the_fact () =
  let store = D.open_store (temp_location "djkf_rotate") in
  ignore (last_row store : answer);
  let rotations = ref 0 in
  for number = 1 to 12 do
    (match D.append_rotating store ~max_current_file_bytes:40 (row number) with
     | D.Appended_after_rotation _ -> incr rotations
     | D.Appended_to_current -> ()
     | D.Skipped_rotation_exhausted _ | D.Skipped_by_append_guard ->
       fail "the row was not written");
    check answer "no file is read" (Held (Some (D.Parsed (row number)))) (last_row store);
    check_the_fact_is_the_files "and it is the files' newest row" store
  done;
  check bool "the current file was rotated out on the way" true (!rotations >= 2)
;;

(* --- 3. whatever removes files forgets -------------------------------- *)

let with_eio f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  f ()
;;

let test_a_prune_forgets () =
  with_eio
  @@ fun () ->
  let location = temp_location "djkf_prune" in
  let store = D.open_store location in
  ignore (write_behind_the_store location ~ts:(now () -. (60. *. day)) "{\"row\":1}\n" : string);
  check answer "the old row is the newest" (Read_and_kept (Some (D.Parsed (row 1)))) (last_row store);
  check bool "the prune removes its file" true (D.prune store ~days:30 >= 1);
  check answer "the fact is read again" (Read_and_kept None) (last_row store);
  (* Also when the prune removed nothing: it does not look. *)
  check int "nothing left to remove" 0 (D.prune store ~days:30);
  check answer "read again" (Read_and_kept None) (last_row store)
;;

let test_the_pass_over_the_listed_stores_forgets () =
  with_eio
  @@ fun () ->
  let base_path = tmpdir "djkf_pass" in
  let root = D.Store.root_of_base_path ~base_path in
  let location = kept_store root in
  let store = D.open_store location in
  ignore (write_behind_the_store location ~ts:(now () -. (60. *. day)) "{\"row\":1}\n" : string);
  check answer "the old row is the newest" (Read_and_kept (Some (D.Parsed (row 1)))) (last_row store);
  let removed =
    D.Store.with_retention_root root (fun held ->
      D.prune_listed_stores_bound root held ~operator_window_days:30 ~on_pruned:ignore)
  in
  check bool "the pass removes the file" true (Option.value removed ~default:0 >= 1);
  check answer "the fact is read again" (Read_and_kept None) (last_row store)
;;

let test_an_appends_own_prune_forgets () =
  let location = temp_location "djkf_budget" in
  let store = D.open_store ~max_bytes:60 location in
  ignore
    (write_behind_the_store
       location
       ~ts:(now () -. (3. *. day))
       (Yojson.Safe.to_string (`Assoc [ "pad", `String (String.make 100 'x') ]) ^ "\n")
     : string);
  ignore (last_row store : answer);
  D.append store (row 2);
  check answer "the append removed a file, so the fact is read again" (Read_and_kept (Some (D.Parsed (row 2)))) (last_row store);
  D.append store (row 3);
  check answer "an append that removes none moves the fact" (Held (Some (D.Parsed (row 3)))) (last_row store)
;;

let test_a_rotating_appends_own_prune_forgets () =
  let location = temp_location "djkf_rotating_budget" in
  let store = D.open_store ~max_bytes:60 location in
  ignore
    (write_behind_the_store
       location
       ~ts:(now () -. (3. *. day))
       (Yojson.Safe.to_string (`Assoc [ "pad", `String (String.make 100 'x') ]) ^ "\n")
     : string);
  ignore (last_row store : answer);
  ignore (D.append_rotating store ~max_current_file_bytes:1_000 (row 2) : D.append_outcome);
  check answer "the append removed a file, so the fact is read again" (Read_and_kept (Some (D.Parsed (row 2)))) (last_row store);
  ignore (D.append_rotating store ~max_current_file_bytes:1_000 (row 3) : D.append_outcome);
  check answer "an append that removes none moves the fact" (Held (Some (D.Parsed (row 3)))) (last_row store)
;;

let test_an_append_that_fails_forgets () =
  let location = temp_location "djkf_failed" in
  let store = D.open_store location in
  D.append store (row 1);
  check answer "kept" (Read_and_kept (Some (D.Parsed (row 1)))) (last_row store);
  let path = (D.Store.dated_path_now location).path in
  (* The cached writer goes, so the next append opens the file again. *)
  D.close store;
  Unix.chmod path 0o400;
  let refused =
    match D.append store (row 2) with
    | () -> false
    | exception Sys_error _ -> true
  in
  Unix.chmod path 0o600;
  (* The owner check does not apply to the superuser. *)
  if Unix.geteuid () <> 0
  then begin
    check bool "the append is refused" true refused;
    check answer "the fact is read again" (Read_and_kept (Some (D.Parsed (row 1)))) (last_row store)
  end;
  check_the_fact_is_the_files "and is the files' newest row" store
;;

(* An append cancelled before its row was handed over raises like one that
   failed, and is treated like one: the fact is forgotten and read again. *)
let test_an_append_that_is_cancelled_forgets () =
  with_eio
  @@ fun () ->
  let store = D.open_store (temp_location "djkf_cancelled") in
  D.append store (row 1);
  check answer "kept" (Read_and_kept (Some (D.Parsed (row 1)))) (last_row store);
  let cancelled =
    try
      Eio.Cancel.sub (fun context ->
        Eio.Cancel.cancel context Exit;
        D.append store (row 2));
      false
    with
    | Eio.Cancel.Cancelled _ -> true
  in
  check bool "the append is cancelled" true cancelled;
  check answer "the fact is read again" (Read_and_kept (Some (D.Parsed (row 1)))) (last_row store);
  check_the_fact_is_the_files "and is the files' newest row" store
;;

(* --- 4. a row outside the newest file --------------------------------- *)

(* A clock that went back puts a row in a day file older than the newest
   one. The strict read still answers from the newest file. *)
let test_a_row_in_an_older_file_is_not_the_newest () =
  let location = temp_location "djkf_older" in
  let store = D.open_store location in
  ignore (write_behind_the_store location ~ts:(now () +. (3. *. day)) "{\"row\":9}\n" : string);
  check answer "the later file's row is the newest" (Read_and_kept (Some (D.Parsed (row 9)))) (last_row store);
  D.append store (row 1);
  check answer "today's row does not replace it" (Read_and_kept (Some (D.Parsed (row 9)))) (last_row store);
  check_the_fact_is_the_files "as the strict read says" store
;;

(* The same rule with the day files given by name. [newest] is the file the
   kept value saw its newest row in and [written] the file the append's row
   went to; the answer is the newest file after the append, or [None] when
   the append forgets. *)
let test_which_file_holds_the_newest_row () =
  let previous = Some (D.Parsed (row 1)) in
  let appended = D.Parsed (row 2) in
  let after ~newest ~written =
    D.For_testing.after_row D.last_row ~value:previous ~newest ~row:appended ~written
  in
  let moved_to written = Some (Some appended, Some written) in
  let answer = option (pair (option entry) (option (pair string string))) in
  List.iter
    (fun (label, newest, written, expected) ->
       check answer label expected (after ~newest ~written))
    [ "a store without rows", None, ("2026-11", "18.jsonl"), moved_to ("2026-11", "18.jsonl")
    ; ( "the same file"
      , Some ("2026-11", "18.jsonl")
      , ("2026-11", "18.jsonl")
      , moved_to ("2026-11", "18.jsonl") )
    ; ( "the next day"
      , Some ("2026-11", "17.jsonl")
      , ("2026-11", "18.jsonl")
      , moved_to ("2026-11", "18.jsonl") )
    ; ( "the next month, with a smaller day"
      , Some ("2026-10", "31.jsonl")
      , ("2026-11", "01.jsonl")
      , moved_to ("2026-11", "01.jsonl") )
    ; ( "a file rotated out earlier the same day"
      , Some ("2026-11", "18.2.jsonl")
      , ("2026-11", "18.jsonl")
      , moved_to ("2026-11", "18.jsonl") )
    ; "the day before the newest", Some ("2026-11", "18.jsonl"), ("2026-11", "17.jsonl"), None
    ; ( "the month before the newest, with a larger day"
      , Some ("2026-12", "01.jsonl")
      , ("2026-11", "30.jsonl")
      , None )
    ]
;;

(* --- 7. the newest row that is JSON ------------------------------------ *)

let test_the_newest_parsed_row_passes_over_a_row_that_is_not_json () =
  let location = temp_location "djkf_parsed" in
  let store = D.open_store location in
  check answer "a store without rows" (Read_and_kept None) (newest_parsed_row store);
  D.append store (row 1);
  check answer "an append moves it" (Held (Some (D.Parsed (row 1)))) (newest_parsed_row store);
  ignore (write_behind_the_store location ~ts:(now ()) "{\"cut\": \n" : string);
  D.directories_removed ();
  check
    answer
    "the cut row after it is passed over"
    (Read_and_kept (Some (D.Parsed (row 1))))
    (newest_parsed_row store);
  check_the_newest_parsed_row_is_the_files "as the strict search says" store;
  check
    answer
    "later readers open no file"
    (Held (Some (D.Parsed (row 1))))
    (newest_parsed_row store);
  D.append store (row 2);
  check
    answer
    "the next row replaces it"
    (Held (Some (D.Parsed (row 2))))
    (newest_parsed_row store)
;;

(* A later day file holds one row, and it is not JSON. It is the store's last
   row, and it is nothing to the newest row that is JSON: that fact counts
   from the file of its own row, so today's append moves it and reads no
   file, while the same append forgets the last row. *)
let test_the_newest_parsed_row_counts_from_its_own_file () =
  let location = temp_location "djkf_parsed_later" in
  let store = D.open_store location in
  D.append store (row 1);
  let later =
    write_behind_the_store location ~ts:(now () +. (3. *. day)) "not json\n"
  in
  D.directories_removed ();
  let is_the_later_row label = function
    | Read_and_kept (Some (D.Malformed_json { path; _ })) -> check string label later path
    | other -> failf "%s: expected the later file's row, got %a" label (pp answer) other
  in
  check
    answer
    "the later file's row is passed over"
    (Read_and_kept (Some (D.Parsed (row 1))))
    (newest_parsed_row store);
  is_the_later_row "the last row is the later file's" (last_row store);
  D.append store (row 2);
  check
    answer
    "today's row is the newest row that is JSON"
    (Held (Some (D.Parsed (row 2))))
    (newest_parsed_row store);
  check_the_newest_parsed_row_is_the_files "as the strict search says" store;
  is_the_later_row "the last row is read again, and is the later file's" (last_row store)
;;

let test_a_json_row_in_a_later_file_stays_the_newest () =
  let location = temp_location "djkf_parsed_older" in
  let store = D.open_store location in
  ignore
    (write_behind_the_store location ~ts:(now () +. (3. *. day)) "{\"row\":9}\n" : string);
  check
    answer
    "the later file's row is the newest"
    (Read_and_kept (Some (D.Parsed (row 9))))
    (newest_parsed_row store);
  D.append store (row 1);
  check
    answer
    "today's row does not replace it"
    (Read_and_kept (Some (D.Parsed (row 9))))
    (newest_parsed_row store);
  check_the_newest_parsed_row_is_the_files "as the strict search says" store
;;

(* What an append makes of the kept value, with no file and no clock. *)
let test_what_a_row_makes_of_the_newest_parsed_row () =
  let previous = Some (row 1) in
  let after ~newest ~row ~written =
    D.For_testing.after_row D.newest_parsed_row ~value:previous ~newest ~row ~written
    |> Option.map (fun (value, newest) -> Option.map (fun json -> D.Parsed json) value, newest)
  in
  let answer = option (pair (option entry) (option (pair string string))) in
  let today = "2026-11", "18.jsonl" in
  let cut = D.Malformed_json { path = "18.jsonl"; line_number = None; detail = "cut" } in
  List.iter
    (fun (label, newest, row, written, expected) ->
       check answer label expected (after ~newest ~row ~written))
    [ ( "a JSON row in a store without one"
      , None
      , D.Parsed (row 2)
      , today
      , Some (Some (D.Parsed (row 2)), Some today) )
    ; ( "a JSON row in the file of the kept one"
      , Some today
      , D.Parsed (row 2)
      , today
      , Some (Some (D.Parsed (row 2)), Some today) )
    ; ( "a JSON row in a file before the kept one's"
      , Some today
      , D.Parsed (row 2)
      , ("2026-11", "17.jsonl")
      , None )
    ; "a row that is not JSON: the files are asked", Some today, cut, today, None
    ]
;;

(* --- a store another process writes ------------------------------------- *)

(* This executable has said it holds the writer lease. The cost log is also
   appended to by [masc-cost], which takes no lease, so its facts are not
   kept here either: a row that reached the file without this process's
   [append] is the next answer, and an append of this process starts no
   keeping. *)
let test_a_store_another_process_writes_is_read_every_time () =
  let root = D.Store.root_of_masc_dir (tmpdir "djkf_costs") in
  let location = D.Store.at root D.Store.Root.Costs in
  let store = D.open_store location in
  D.append store (row 1);
  check answer "the files are read" (Read_not_kept (Some (D.Parsed (row 1)))) (last_row store);
  check answer "and read again" (Read_not_kept (Some (D.Parsed (row 1)))) (last_row store);
  ignore (write_behind_the_store location ~ts:(now ()) "{\"row\":2}\n" : string);
  check
    answer
    "another process's row is the next answer"
    (Read_not_kept (Some (D.Parsed (row 2))))
    (last_row store);
  D.append store (row 3);
  check
    answer
    "after an append of this process"
    (Read_not_kept (Some (D.Parsed (row 3))))
    (last_row store)
;;

(* Every store says whether its facts are kept, and the ones kept are the
   ones whose writers have been gone through. A store added to the kept ones
   changes this list, and with it comes the account of who writes it. *)
let test_which_stores_keep_their_facts () =
  let kept =
    List.filter
      (fun store ->
         match D.Store.facts store with
         | D.Store.Kept_by_the_lease_holder -> true
         | D.Store.Read_from_the_files -> false)
      D.Store.all
  in
  let store =
    testable
      (fun formatter store -> Format.pp_print_string formatter (D.Store.pool_job_name store))
      (fun (left : D.Store.t) right -> left = right)
  in
  check
    (list store)
    "the stores whose facts are kept"
    [ D.Store.Keeper D.Store.Keeper.Execution_receipts
    ; D.Store.Keeper D.Store.Keeper.Turn_records
    ]
    kept
;;

(* --- 5. one directory, one fact ---------------------------------------- *)

let test_two_spellings_of_a_directory_share_the_fact () =
  let real = tmpdir "djkf_spelling" in
  let link = real ^ "_link" in
  Unix.symlink real link;
  let through_the_link = D.open_store (location_under link) in
  let direct = D.open_store (location_under real) in
  D.append through_the_link (row 1);
  check answer "read under one spelling" (Read_and_kept (Some (D.Parsed (row 1)))) (last_row direct);
  D.append through_the_link (row 2);
  check answer "moved by an append under the other" (Held (Some (D.Parsed (row 2)))) (last_row direct);
  check answer "and held under both" (Held (Some (D.Parsed (row 2)))) (last_row through_the_link)
;;

(* The link is pointed at another directory. After the removal is told, the
   spelling is asked about again and its appends move the facts of the
   directory it now reaches. *)
let test_a_spelling_is_asked_about_again_after_a_removal () =
  let first = tmpdir "djkf_repoint_first" in
  let second = tmpdir "djkf_repoint_second" in
  let link = first ^ "_link" in
  Unix.symlink first link;
  let through_the_link = D.open_store (location_under link) in
  D.append through_the_link (row 1);
  ignore (last_row through_the_link : answer);
  D.prepare_for_directory_removal through_the_link;
  Unix.unlink link;
  Unix.symlink second link;
  D.directories_removed ();
  let direct = D.open_store (location_under second) in
  D.append through_the_link (row 2);
  check answer "the row went to the second directory" (Read_and_kept (Some (D.Parsed (row 2)))) (last_row direct);
  D.append through_the_link (row 3);
  check answer "and the link's appends move that directory's fact" (Held (Some (D.Parsed (row 3)))) (last_row direct);
  check_the_fact_is_the_files "which is the files' newest row" direct
;;

(* The append's spelling goes through [missing/..], which names nothing
   until [missing] is there, so the append begins without the directory's
   name. It makes [missing] on its way and its row lands in a directory that
   has a fact under its own name. After the row the append asks about its
   spelling again and forgets that fact. *)
let test_a_spelling_that_resolves_only_after_the_append () =
  let root = tmpdir "djkf_late_name" in
  let direct = D.open_store (location_under (Filename.concat root "store")) in
  D.append direct (row 1);
  check answer "the directory's fact" (Read_and_kept (Some (D.Parsed (row 1)))) (last_row direct);
  let roundabout =
    D.open_store
      (location_under
         (List.fold_left
            Filename.concat
            root
            [ "missing"; Filename.parent_dir_name; "store" ]))
  in
  D.append roundabout (row 2);
  check
    answer
    "is forgotten by the append that reached the directory"
    (Read_and_kept (Some (D.Parsed (row 2))))
    (last_row direct);
  D.append roundabout (row 3);
  check
    answer
    "whose spelling is the directory's from then on"
    (Held (Some (D.Parsed (row 3))))
    (last_row direct)
;;

(* A removal is told while an append is under way. The acknowledgement is the
   one place a test can stand between an append's first look at its spelling
   and its last, so the removal happens there, after the row. An append
   cannot tell which side of an overlapping removal its row went to: it asks
   about its spelling again and forgets the facts of the directory the
   spelling reaches now, here one filled after the removal. *)
let test_a_removal_told_during_an_append () =
  let first = tmpdir "djkf_during_first" in
  let second = tmpdir "djkf_during_second" in
  let link = first ^ "_link" in
  Unix.symlink first link;
  let through_the_link = D.open_store (location_under link) in
  let second_directly = D.open_store (location_under second) in
  D.append through_the_link (row 1);
  D.append second_directly (row 2);
  D.append_notifying_commit through_the_link (row 3) ~on_committed:(fun () ->
    Unix.unlink link;
    Unix.symlink second link;
    D.directories_removed ();
    check
      answer
      "the second directory's fact, filled after the removal"
      (Read_and_kept (Some (D.Parsed (row 2))))
      (last_row second_directly));
  check
    answer
    "is forgotten by the append the removal overlapped"
    (Read_and_kept (Some (D.Parsed (row 2))))
    (last_row second_directly);
  D.append through_the_link (row 4);
  check
    answer
    "and the link's appends move it from then on"
    (Held (Some (D.Parsed (row 4))))
    (last_row second_directly)
;;

(* --- 6. each read is counted -------------------------------------------- *)

(* The counter says whether a fact is being kept: a fact whose reads are
   never [held] costs a file read each time. The counts are the process's, so
   the test takes the difference its own reads made. *)
let test_reads_are_counted_by_how_they_were_come_by () =
  let location = temp_location "djkf_counted" in
  let store = D.open_store location in
  let outcomes = [ "held"; "read_and_kept"; "read_not_kept"; "read_failed" ] in
  let counted () =
    List.map
      (fun outcome ->
         Otel_metric_store_core.metric_value_or_zero
           Otel_builtin_metric_names.metric_dated_jsonl_fact_reads
           ~labels:
             [ "store", D.Store.pool_job_name (D.Store.of_location location)
             ; "fact", "last_row"
             ; "outcome", outcome
             ]
           ())
      outcomes
  in
  let before = counted () in
  ignore (last_row store : answer);
  ignore (last_row store : answer);
  D.append store (row 1);
  ignore (last_row store : answer);
  let foreign = Filename.concat (D.Store.dir location) "not-a-month" in
  Out_channel.with_open_text foreign (fun channel -> output_string channel "x");
  D.directories_removed ();
  ignore (last_row store : answer);
  Sys.remove foreign;
  check
    (list (pair string (float 0.)))
    "one read kept, two held, one failed"
    (List.combine outcomes [ 2.; 1.; 0.; 1. ])
    (List.combine outcomes (List.map2 ( -. ) (counted ()) before))
;;

(* --- every path, in a row and at once ---------------------------------- *)

(* A long run of every operation in an order drawn from a fixed seed. After
   each one the fact is the strict read's answer. *)
let test_the_fact_is_the_files_after_every_operation () =
  with_eio
  @@ fun () ->
  let random = Random.State.make [| 20261118 |] in
  let location = temp_location "djkf_run" in
  let store = D.open_store location in
  let number = ref 0 in
  let next () =
    incr number;
    row !number
  in
  let held = ref 0 in
  let parsed_held = ref 0 in
  for step = 1 to 400 do
    (match Random.State.int random 16 with
     | 0 | 1 | 2 | 3 | 4 | 5 -> D.append store (next ())
     | 6 | 7 | 8 | 9 ->
       ignore
         (D.append_rotating store ~max_current_file_bytes:60 (next ()) : D.append_outcome)
     | 10 | 11 -> ignore (last_row store : answer)
     | 12 ->
       ignore (write_behind_the_store location ~ts:(now ()) "not json\n" : string);
       D.directories_removed ()
     | 13 -> ignore (D.prune store ~days:30 : int)
     | 14 ->
       ignore
         (write_behind_the_store location ~ts:(now () -. (60. *. day)) "{\"row\":0}\n"
          : string);
       D.directories_removed ()
     | _ ->
       D.prepare_for_directory_removal store;
       (try Sys.remove (D.Store.dated_path_now location).path with
        | Sys_error _ -> ());
       D.directories_removed ());
    (match last_row store with
     | Held _ -> incr held
     | Read_and_kept _ | Read_not_kept _ | Read_failed _ -> ());
    (match newest_parsed_row store with
     | Held _ -> incr parsed_held
     | Read_and_kept _ | Read_not_kept _ | Read_failed _ -> ());
    check_the_fact_is_the_files (Printf.sprintf "after step %d" step) store;
    check_the_newest_parsed_row_is_the_files
      (Printf.sprintf "the newest row that is JSON, after step %d" step)
      store
  done;
  (* The run is not a run of file reads: most answers came from memory. *)
  check bool "most answers were held" true (!held > 200);
  check bool "most answers of the newest row that is JSON were held" true (!parsed_held > 200)
;;

(* One append and one reader of a forgotten fact, started together, many
   times over. Whoever wins, a fact that is held afterwards is the files'
   newest row. *)
let test_an_append_and_a_reader_together () =
  let store = D.open_store (temp_location "djkf_together") in
  for number = 1 to 300 do
    D.directories_removed ();
    let start = Atomic.make false in
    let wait_for_start () =
      while not (Atomic.get start) do
        Domain.cpu_relax ()
      done
    in
    let appender =
      Domain.spawn (fun () ->
        wait_for_start ();
        D.append store (row number))
    in
    let reader =
      Domain.spawn (fun () ->
        wait_for_start ();
        ignore (last_row store : answer))
    in
    Atomic.set start true;
    Domain.join appender;
    Domain.join reader;
    match last_row store with
    | Held value ->
      check
        (result (option entry) string)
        (Printf.sprintf "round %d: the held fact is the files' newest row" number)
        (newest_row_in_the_files store)
        (Ok value)
    | Read_and_kept _ | Read_not_kept _ | Read_failed _ -> ()
  done
;;

let () =
  D.keep_facts_in_this_process ();
  run
    "dated_jsonl_kept_facts"
    [ ( "a reader fills the fact"
      , [ test_case "a store without rows" `Quick test_a_store_without_rows
        ; test_case "later readers open no file" `Quick test_later_readers_open_no_file
        ; test_case
            "a store that cannot be read keeps nothing"
            `Quick
            test_a_store_that_cannot_be_read_keeps_nothing
        ; test_case "a row that is not JSON" `Quick test_a_row_that_is_not_json
        ; test_case
            "a reader fills while the store is locked"
            `Quick
            test_a_reader_fills_while_the_store_is_locked
        ] )
    ; ( "an append moves the fact"
      , [ test_case "an append moves the fact" `Quick test_an_append_moves_the_fact
        ; test_case
            "the fact is the row as it is read"
            `Quick
            test_the_fact_is_the_row_as_it_is_read
        ; test_case "an append fills nothing" `Quick test_an_append_fills_nothing
        ; test_case
            "the fact moves before the acknowledgement"
            `Quick
            test_the_fact_moves_before_the_acknowledgement
        ; test_case
            "rotating the current file out keeps the fact"
            `Quick
            test_rotating_the_current_file_out_keeps_the_fact
        ] )
    ; ( "whatever removes files forgets"
      , [ test_case "a prune forgets" `Quick test_a_prune_forgets
        ; test_case
            "the pass over the listed stores forgets"
            `Quick
            test_the_pass_over_the_listed_stores_forgets
        ; test_case "an append's own prune forgets" `Quick test_an_appends_own_prune_forgets
        ; test_case
            "a rotating append's own prune forgets"
            `Quick
            test_a_rotating_appends_own_prune_forgets
        ; test_case "an append that fails forgets" `Quick test_an_append_that_fails_forgets
        ; test_case
            "an append that is cancelled forgets"
            `Quick
            test_an_append_that_is_cancelled_forgets
        ] )
    ; ( "a row outside the newest file"
      , [ test_case
            "a row in an older file is not the newest"
            `Quick
            test_a_row_in_an_older_file_is_not_the_newest
        ; test_case
            "which file holds the newest row"
            `Quick
            test_which_file_holds_the_newest_row
        ] )
    ; ( "one directory, one fact"
      , [ test_case
            "two spellings of a directory share the fact"
            `Quick
            test_two_spellings_of_a_directory_share_the_fact
        ; test_case
            "a spelling is asked about again after a removal"
            `Quick
            test_a_spelling_is_asked_about_again_after_a_removal
        ; test_case
            "a spelling that resolves only after the append"
            `Quick
            test_a_spelling_that_resolves_only_after_the_append
        ; test_case
            "a removal told during an append"
            `Quick
            test_a_removal_told_during_an_append
        ] )
    ; ( "each read is counted"
      , [ test_case
            "reads are counted by how they were come by"
            `Quick
            test_reads_are_counted_by_how_they_were_come_by
        ] )
    ; ( "the newest row that is JSON"
      , [ test_case
            "it passes over a row that is not JSON"
            `Quick
            test_the_newest_parsed_row_passes_over_a_row_that_is_not_json
        ; test_case
            "it counts from the file of its own row"
            `Quick
            test_the_newest_parsed_row_counts_from_its_own_file
        ; test_case
            "a JSON row in a later file stays the newest"
            `Quick
            test_a_json_row_in_a_later_file_stays_the_newest
        ; test_case
            "what a row makes of it"
            `Quick
            test_what_a_row_makes_of_the_newest_parsed_row
        ] )
    ; ( "a store another process writes"
      , [ test_case
            "is read every time"
            `Quick
            test_a_store_another_process_writes_is_read_every_time
        ; test_case "which stores keep their facts" `Quick test_which_stores_keep_their_facts
        ]
      )
    ; ( "every path"
      , [ test_case
            "the fact is the files after every operation"
            `Quick
            test_the_fact_is_the_files_after_every_operation
        ; test_case
            "an append and a reader together"
            `Quick
            test_an_append_and_a_reader_together
        ] )
    ]
;;
