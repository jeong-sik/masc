(** [Fs_compat.update_private_jsonl_after_cursor_durable_locked_result]: a
    locked durable update of an append-only JSONL file. Its caller passes a
    cursor with what it kept from the rows before it. The decision receives the
    rows after the cursor and what was kept, or every row and nothing kept when
    the cursor is not the end of rows of the file. *)

open Alcotest

let with_store f =
  let dir = Filename.temp_dir "masc_after_cursor_" "" in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree dir)
    (fun () -> f (Filename.concat dir "rows.jsonl"))
;;

let read_all path = In_channel.with_open_bin path In_channel.input_all

(* Bytes another writer puts at the end of the file, outside the update. *)
let append_raw path bytes =
  Out_channel.with_open_gen
    [ Open_wronly; Open_append; Open_creat; Open_binary ]
    0o600
    path
    (fun channel -> Out_channel.output_string channel bytes)
;;

let committed = function
  | Fs_compat.Private_file_succeeded value -> value
  | Fs_compat.Private_file_succeeded_with_cleanup_failure { cleanup_failure; _ } ->
    failf
      "the descriptor did not close: %s"
      (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure)
  | Fs_compat.Private_file_failed error
  | Fs_compat.Private_file_failed_with_cleanup_failure { error; _ } ->
    fail (Fs_compat.durable_append_error_to_string error)
;;

(* What a caller keeps here is a name for the read it was kept from. *)
type read = string Fs_compat.private_jsonl_rows_from_cursor

(* One update. It appends [append], when given, and answers with what its
   decision received. *)
let update ?append path ~after =
  Fs_compat.update_private_jsonl_after_cursor_durable_locked_result
    path
    ~after
    (fun (file : read) -> append, file)
  |> committed
;;

(* The end of the rows [file] read, with [kept] as what was kept from them. *)
let after (file : read) ~kept = Some (file.Fs_compat.rows_end, kept)

let read_start =
  let pp ppf = function
    | Fs_compat.Rows_after_cursor kept -> Format.fprintf ppf "Rows_after_cursor %S" kept
    | Fs_compat.Rows_from_start -> Format.pp_print_string ppf "Rows_from_start"
  in
  testable pp ( = )
;;

let check_read label (file : read) ~read ~rows =
  check read_start (label ^ ": where the read started") read file.Fs_compat.read;
  check string (label ^ ": rows") rows file.Fs_compat.rows
;;

let test_without_a_cursor_every_row_is_read () =
  with_store (fun path ->
    append_raw path "a\nb\n";
    let file = update path ~after:None in
    check_read "no cursor" file ~read:Fs_compat.Rows_from_start ~rows:"a\nb\n")
;;

let test_only_the_rows_after_the_cursor_are_read () =
  with_store (fun path ->
    append_raw path "a\nb\n";
    let first = update path ~after:None ~append:"c\n" in
    (* [rows_end] is where the first read ended, before the row it appended. *)
    let second = update path ~after:(after first ~kept:"first") in
    check_read
      "the row the first update appended"
      second
      ~read:(Fs_compat.Rows_after_cursor "first")
      ~rows:"c\n";
    append_raw path "d\ne\n";
    let third = update path ~after:(after second ~kept:"second") in
    check_read
      "the rows of another writer"
      third
      ~read:(Fs_compat.Rows_after_cursor "second")
      ~rows:"d\ne\n";
    let fourth = update path ~after:(after third ~kept:"third") in
    check_read
      "nothing new"
      fourth
      ~read:(Fs_compat.Rows_after_cursor "third")
      ~rows:"";
    check string "the file" "a\nb\nc\nd\ne\n" (read_all path))
;;

let test_the_append_lands_after_every_row () =
  with_store (fun path ->
    append_raw path "a\n";
    let first = update path ~after:None in
    append_raw path "b\n";
    let second = update path ~after:(after first ~kept:"first") ~append:"c\n" in
    check_read
      "the rows after the cursor"
      second
      ~read:(Fs_compat.Rows_after_cursor "first")
      ~rows:"b\n";
    check string "the file" "a\nb\nc\n" (read_all path))
;;

let test_a_replaced_file_is_read_from_its_start () =
  with_store (fun path ->
    append_raw path "a\nb\n";
    let first = update path ~after:None in
    (* Renamed over the path while the old file still exists: another inode,
       and longer than what the cursor covers. *)
    let replacement = path ^ ".new" in
    append_raw replacement "x\ny\nz\n";
    Sys.rename replacement path;
    let second = update path ~after:(after first ~kept:"of the file that was there before") in
    check_read
      "a cursor of the file that was there before"
      second
      ~read:Fs_compat.Rows_from_start
      ~rows:"x\ny\nz\n")
;;

let test_a_shortened_file_is_read_from_its_start () =
  with_store (fun path ->
    append_raw path "a\nb\nc\n";
    let first = update path ~after:None in
    Unix.truncate path (String.length "a\n");
    let second = update path ~after:(after first ~kept:"of the longer file") in
    check_read
      "a cursor past the end of the file"
      second
      ~read:Fs_compat.Rows_from_start
      ~rows:"a\n")
;;

let test_a_cursor_inside_a_row_is_read_from_the_start () =
  with_store (fun path ->
    append_raw path "a\nb\n";
    let first = update path ~after:None in
    (* Written through the path: the same inode, and longer than what the
       cursor covers. The cursor stands after "a\nb\n", where the new first
       row is still going on. *)
    Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel "abcdef\ng\n");
    let second = update path ~after:(after first ~kept:"of the rows that were there before") in
    check_read
      "a cursor where no row starts"
      second
      ~read:Fs_compat.Rows_from_start
      ~rows:"abcdef\ng\n")
;;

let test_an_incomplete_tail_is_not_a_row () =
  with_store (fun path ->
    append_raw path "a\nb";
    let first = update path ~after:None in
    check_read "the whole file" first ~read:Fs_compat.Rows_from_start ~rows:"a\n";
    (* The cursor stands after the last whole row, so the tail is read again. *)
    let second = update path ~after:(after first ~kept:"first") in
    check_read "the same tail" second ~read:(Fs_compat.Rows_after_cursor "first") ~rows:"";
    check string "an update that appends nothing leaves the tail" "a\nb" (read_all path);
    append_raw path "c\nd";
    let third = update path ~after:(after second ~kept:"second") in
    check_read "the tail became a row" third ~read:(Fs_compat.Rows_after_cursor "second") ~rows:"bc\n")
;;

let test_an_append_cuts_the_incomplete_tail () =
  with_store (fun path ->
    append_raw path "a\nb";
    let first = update path ~after:None ~append:"c\n" in
    check_read "the whole file" first ~read:Fs_compat.Rows_from_start ~rows:"a\n";
    check string "the suffix follows the last row" "a\nc\n" (read_all path);
    append_raw path "d";
    let second = update path ~after:(after first ~kept:"first") ~append:"e\n" in
    check_read "the appended row" second ~read:(Fs_compat.Rows_after_cursor "first") ~rows:"c\n";
    check string "the suffix follows the last row again" "a\nc\ne\n" (read_all path);
    let third = update path ~after:(after second ~kept:"second") in
    check_read "the cursor still stands" third ~read:(Fs_compat.Rows_after_cursor "second") ~rows:"e\n")
;;

let test_a_missing_file_is_created_empty () =
  with_store (fun path ->
    let first = update path ~after:None ~append:"a\n" in
    check_read "a new file" first ~read:Fs_compat.Rows_from_start ~rows:"";
    let second = update path ~after:(after first ~kept:"first") in
    check_read
      "its first row"
      second
      ~read:(Fs_compat.Rows_after_cursor "first")
      ~rows:"a\n")
;;

let () =
  run
    "fs_compat_update_after_cursor"
    [ ( "what the decision receives"
      , [ test_case "every row without a cursor" `Quick test_without_a_cursor_every_row_is_read
        ; test_case
            "only the rows after the cursor"
            `Quick
            test_only_the_rows_after_the_cursor_are_read
        ; test_case "the append lands after every row" `Quick test_the_append_lands_after_every_row
        ; test_case "an incomplete tail is not a row" `Quick test_an_incomplete_tail_is_not_a_row
        ; test_case "an append cuts the incomplete tail" `Quick test_an_append_cuts_the_incomplete_tail
        ; test_case "a missing file is created empty" `Quick test_a_missing_file_is_created_empty
        ] )
    ; ( "a cursor that is not the end of rows of the file"
      , [ test_case
            "a replaced file is read from its start"
            `Quick
            test_a_replaced_file_is_read_from_its_start
        ; test_case
            "a shortened file is read from its start"
            `Quick
            test_a_shortened_file_is_read_from_its_start
        ; test_case
            "a cursor inside a row is read from the start"
            `Quick
            test_a_cursor_inside_a_row_is_read_from_the_start
        ] )
    ]
;;
