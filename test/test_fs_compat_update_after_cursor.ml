(** [Fs_compat.update_private_jsonl_after_cursor_durable_locked_result]: a
    locked durable update of an append-only JSONL file. Its caller passes a
    cursor with what it kept from the rows before it. The decision receives the
    rows after the cursor and what was kept, or every row and nothing kept when
    the cursor is not a prefix of the file. *)

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

let check_read label (file : read) ~read ~rows ~incomplete_tail =
  check read_start (label ^ ": where the read started") read file.Fs_compat.read;
  check string (label ^ ": rows") rows file.Fs_compat.rows;
  check string (label ^ ": incomplete tail") incomplete_tail file.Fs_compat.incomplete_tail
;;

let test_without_a_cursor_every_row_is_read () =
  with_store (fun path ->
    append_raw path "a\nb\n";
    let file = update path ~after:None in
    check_read "no cursor" file ~read:Fs_compat.Rows_from_start ~rows:"a\nb\n" ~incomplete_tail:"")
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
      ~rows:"c\n"
      ~incomplete_tail:"";
    append_raw path "d\ne\n";
    let third = update path ~after:(after second ~kept:"second") in
    check_read
      "the rows of another writer"
      third
      ~read:(Fs_compat.Rows_after_cursor "second")
      ~rows:"d\ne\n"
      ~incomplete_tail:"";
    let fourth = update path ~after:(after third ~kept:"third") in
    check_read
      "nothing new"
      fourth
      ~read:(Fs_compat.Rows_after_cursor "third")
      ~rows:""
      ~incomplete_tail:"";
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
      ~rows:"b\n"
      ~incomplete_tail:"";
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
      ~rows:"x\ny\nz\n"
      ~incomplete_tail:"")
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
      ~rows:"a\n"
      ~incomplete_tail:"")
;;

let test_an_incomplete_tail_is_kept_apart () =
  with_store (fun path ->
    append_raw path "a\nb";
    let first = update path ~after:None in
    check_read "the whole file" first ~read:Fs_compat.Rows_from_start ~rows:"a\n" ~incomplete_tail:"b";
    (* The cursor stands after the last whole row, so the tail is read again. *)
    let second = update path ~after:(after first ~kept:"first") in
    check_read
      "the same tail"
      second
      ~read:(Fs_compat.Rows_after_cursor "first")
      ~rows:""
      ~incomplete_tail:"b";
    append_raw path "c\nd";
    let third = update path ~after:(after second ~kept:"second") in
    check_read
      "the tail became a row"
      third
      ~read:(Fs_compat.Rows_after_cursor "second")
      ~rows:"bc\n"
      ~incomplete_tail:"d")
;;

let test_a_missing_file_is_created_empty () =
  with_store (fun path ->
    let first = update path ~after:None ~append:"a\n" in
    check_read "a new file" first ~read:Fs_compat.Rows_from_start ~rows:"" ~incomplete_tail:"";
    let second = update path ~after:(after first ~kept:"first") in
    check_read
      "its first row"
      second
      ~read:(Fs_compat.Rows_after_cursor "first")
      ~rows:"a\n"
      ~incomplete_tail:"")
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
        ; test_case "an incomplete tail is kept apart" `Quick test_an_incomplete_tail_is_kept_apart
        ; test_case "a missing file is created empty" `Quick test_a_missing_file_is_created_empty
        ] )
    ; ( "a cursor that is not a prefix of the file"
      , [ test_case
            "a replaced file is read from its start"
            `Quick
            test_a_replaced_file_is_read_from_its_start
        ; test_case
            "a shortened file is read from its start"
            `Quick
            test_a_shortened_file_is_read_from_its_start
        ] )
    ]
;;
