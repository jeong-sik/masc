(* Checks for the file of the authorization log: opening it at process start,
   appending to it inside a zone, and what each way of failing leaves behind.
   Every case runs on real files in a fresh temporary directory, through the
   production path of [Fs_compat]. The one case with a second process starts
   this executable again (see [hold_lock_child_flag]). *)

open Authz_types
open Authz_records
module R = Authz_record
module L = Authz_log

(* The child of [with_foreign_lock]: takes the lock file of the store the way
   [Fs_compat] does, says so, and holds the lock until its input closes. *)
let hold_lock_child_flag = "--hold-store-lock"

let () =
  if Array.length Sys.argv = 3 && String.equal Sys.argv.(1) hold_lock_child_flag
  then (
    let fd = Unix.openfile Sys.argv.(2) [ Unix.O_WRONLY ] 0o600 in
    Fun.protect
      ~finally:(fun () -> Unix.close fd)
      (fun () ->
        Unix.lockf fd Unix.F_LOCK 0;
        output_char stdout 'R';
        flush stdout;
        try ignore (input_char stdin) with
        | End_of_file -> ());
    exit 0)
;;

(* ---- fixtures ---- *)

let get = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "fixture id rejected by Authz_id"
;;

let author = Author.Authenticated (Principal.Human (get (User_id.of_string "alice")))

let body_of n =
  match Authz_body.of_yojson (`Assoc [ "n", `Int n ]) with
  | Ok body -> body
  | Error error -> Alcotest.failf "fixture body refused: %s" (Authz_body.error_to_string error)
;;

let make_exn ~head ~n =
  match
    R.make ~head ~at_ms:(1000 + n) ~author ~kind:R.Kind.Runtime_grant ~body:(body_of n)
  with
  | Ok record -> record
  | Error (R.Author_not_admitted _) -> Alcotest.fail "fixture author not admitted"
;;

(* [count] records chained from [head]; the body of each holds its own seq. *)
let chain_from ~head ~count =
  let rec go head built remaining =
    if remaining = 0
    then List.rev built
    else (
      let record = make_exn ~head ~n:(R.next_seq head) in
      go (R.head_after record) (record :: built) (remaining - 1))
  in
  go head [] count
;;

let take count records = List.filteri (fun index _ -> index < count) records
let seq_of (record : R.t) = record.R.seq
let lines_of records = List.map R.to_line records
let text_of records = String.concat "" (List.map (fun line -> line ^ "\n") (lines_of records))

(* ---- text and files ---- *)

let find_sub ~sub text =
  let sub_length = String.length sub in
  let rec go at =
    if at + sub_length > String.length text
    then None
    else if String.equal (String.sub text at sub_length) sub
    then Some at
    else go (at + 1)
  in
  go 0
;;

let contains ~sub text = Option.is_some (find_sub ~sub text)

let replace_once ~sub ~by text =
  match find_sub ~sub text with
  | None -> Alcotest.failf "fixture text does not hold %s" sub
  | Some at ->
    let after = at + String.length sub in
    String.sub text 0 at ^ by ^ String.sub text after (String.length text - after)
;;

let read_file path = In_channel.with_open_bin path In_channel.input_all

let write_file path text =
  Out_channel.with_open_bin path (fun channel -> Out_channel.output_string channel text)
;;

(* The lines of a file that ends after a newline. *)
let lines_of_file path =
  match List.rev (String.split_on_char '\n' (read_file path)) with
  | "" :: reversed -> List.rev reversed
  | _ -> Alcotest.fail "the file does not end after a newline"
;;

let rewrite_lines path ~f =
  write_file path (String.concat "" (List.map (fun line -> line ^ "\n") (f (lines_of_file path))))
;;

let rec remove_tree path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | { Unix.st_kind = Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK; _ }
    -> Sys.remove path
;;

(* A fresh base path, inside an Eio event loop because the zone is an
   [Eio.Mutex]. *)
let with_base f =
  Eio_main.run (fun _env ->
    let base = Filename.temp_dir "authz-log-" "" in
    Fun.protect ~finally:(fun () -> remove_tree base) (fun () -> f (L.path_of_base_path ~base_path:base)))
;;

(* ---- opening and writing, as the cases use them ---- *)

let collect state record = Ok (record :: state)

let open_ok ~path =
  match L.open_at_start ~path ~init:[] ~step:collect with
  | Ok (log, state, recovered) -> log, List.rev state, recovered
  | Error error ->
    Alcotest.failf "open refused: %s" (L.open_error_to_string (fun () -> "") error)
;;

let open_error ~path =
  match L.open_at_start ~path ~init:[] ~step:collect with
  | Ok _ -> Alcotest.fail "open succeeded where it should have been refused"
  | Error error -> error
;;

(* The zone of a log that is not stopped. *)
let in_zone log f =
  match L.with_writer log f with
  | Ok value -> value
  | Error stop -> Alcotest.failf "the log is stopped: %s" stop.L.reason
;;

let append_ok log records =
  in_zone log (fun writer _head ->
    match L.append writer records with
    | Ok head -> head
    | Error error -> Alcotest.failf "append refused: %s" (L.append_error_to_string error))
;;

let append_error log records =
  in_zone log (fun writer _head ->
    match L.append writer records with
    | Ok _ -> Alcotest.fail "append succeeded where it should have been refused"
    | Error error -> error)
;;

let head_of_log log = in_zone log (fun _writer head -> head)

let check_contents label expected (recovered : L.recovered) =
  let name = function
    | L.Missing -> "Missing"
    | L.Empty -> "Empty"
    | L.Lines count -> Printf.sprintf "Lines %d" count
  in
  Alcotest.(check string) label (name expected) (name recovered.L.contents)
;;

let check_complete (recovered : L.recovered) =
  match recovered.L.tail with
  | L.Complete -> ()
  | L.Cut { kept_bytes; discarded_bytes } ->
    Alcotest.failf "tail cut: kept %d, discarded %d" kept_bytes discarded_bytes
;;

let check_seqs label expected records =
  Alcotest.(check (list int)) label expected (List.map seq_of records)
;;

(* Every constructor is named here, so that a new one fails to compile until
   the cases below have decided what it means for them. *)
let decode_error_name : R.decode_error -> string = function
  | R.Not_json -> "Not_json"
  | R.Unexpected_shape -> "Unexpected_shape"
  | R.Unknown_kind _ -> "Unknown_kind"
  | R.Invalid_author -> "Invalid_author"
  | R.Invalid_hash -> "Invalid_hash"
  | R.Seq_mismatch { expected; actual } ->
    Printf.sprintf "Seq_mismatch expected=%d actual=%d" expected actual
  | R.Previous_hash_mismatch -> "Previous_hash_mismatch"
  | R.Author_not_admitted_to_write _ -> "Author_not_admitted_to_write"
  | R.Invalid_body _ -> "Invalid_body"
  | R.Hash_mismatch -> "Hash_mismatch"
  | R.Non_canonical -> "Non_canonical"
;;

let append_error_name : L.append_error -> string = function
  | L.Writer_expired -> "Writer_expired"
  | L.Stopped { path; _ } -> Printf.sprintf "Stopped path=%s" path
  | L.Rejected { index; reject = L.Wrong_seq { expected; actual } } ->
    Printf.sprintf "Wrong_seq index=%d expected=%d actual=%d" index expected actual
  | L.Rejected { index; reject = L.Wrong_previous_hash } ->
    Printf.sprintf "Wrong_previous_hash index=%d" index
  | L.Would_not_read_back { index; _ } -> Printf.sprintf "Would_not_read_back index=%d" index
  | L.Write_locked { path } -> Printf.sprintf "Write_locked path=%s" path
  | L.Diverged { path } -> Printf.sprintf "Diverged path=%s" path
  | L.Write_failed { path; _ } -> Printf.sprintf "Write_failed path=%s" path
;;

let outcome_name = function
  | Ok _ -> "Ok"
  | Error error -> append_error_name error
;;

let open_error_name : 'reason L.open_error -> string = function
  | L.Locked { path } -> Printf.sprintf "Locked path=%s" path
  | L.Unreadable { path; _ } -> Printf.sprintf "Unreadable path=%s" path
  | L.Line_rejected { path; line_number; error } ->
    Printf.sprintf "Line_rejected path=%s line=%d %s" path line_number (decode_error_name error)
  | L.Fold_refused { path; line_number; _ } ->
    Printf.sprintf "Fold_refused path=%s line=%d" path line_number
;;

let check_append_error label expected log records =
  Alcotest.(check string) label expected (append_error_name (append_error log records))
;;

let check_open_error label expected ~path =
  Alcotest.(check string) label expected (open_error_name (open_error ~path))
;;

(* ---- opening ---- *)

let path_is_under_the_auth_directory () =
  Alcotest.(check string)
    "path"
    "/base/.masc/auth/authz.jsonl"
    (L.path_of_base_path ~base_path:"/base")
;;

let missing_file () =
  with_base (fun path ->
    let _log, state, recovered = open_ok ~path in
    check_contents "no file" L.Missing recovered;
    check_complete recovered;
    check_seqs "nothing replayed" [] state;
    Alcotest.(check bool) "opening does not create the log file" false (Sys.file_exists path))
;;

let empty_file () =
  with_base (fun path ->
    Fs_compat.mkdir_p (Filename.dirname path);
    write_file path "";
    let log, state, recovered = open_ok ~path in
    check_contents "an empty file is not a missing file" L.Empty recovered;
    check_complete recovered;
    check_seqs "nothing replayed" [] state;
    let records = chain_from ~head:R.genesis ~count:1 in
    ignore (append_ok log records : R.head);
    Alcotest.(check (list string)) "first line written" (lines_of records) (lines_of_file path))
;;

let append_then_reopen () =
  with_base (fun path ->
    let log, _, _ = open_ok ~path in
    let records = chain_from ~head:R.genesis ~count:5 in
    ignore (append_ok log (take 1 records) : R.head);
    Alcotest.(check int)
      "only the owner can read the log"
      0o600
      ((Unix.stat path).Unix.st_perm land 0o777);
    ignore (append_ok log (List.tl records) : R.head);
    Alcotest.(check (list string)) "file holds the lines" (lines_of records) (lines_of_file path);
    let reopened, state, recovered = open_ok ~path in
    check_contents "five lines" (L.Lines 5) recovered;
    check_complete recovered;
    check_seqs "replayed in file order" [ 1; 2; 3; 4; 5 ] state;
    Alcotest.(check (list string)) "same bytes" (lines_of records) (lines_of state);
    let head = head_of_log reopened in
    Alcotest.(check int) "next seq" 6 (R.next_seq head);
    ignore (append_ok reopened [ make_exn ~head ~n:6 ] : R.head);
    let _, state, _ = open_ok ~path in
    check_seqs "a line appended after reopening" [ 1; 2; 3; 4; 5; 6 ] state)
;;

let many_records_in_one_write () =
  with_base (fun path ->
    let log, _, _ = open_ok ~path in
    let count = 2000 in
    let records = chain_from ~head:R.genesis ~count in
    let head = append_ok log records in
    Alcotest.(check int) "head after the list" (count + 1) (R.next_seq head);
    let _, state, recovered = open_ok ~path in
    check_contents "all lines" (L.Lines count) recovered;
    Alcotest.(check (list string)) "same bytes" (lines_of records) (lines_of state))
;;

let fold_refusal_names_the_line () =
  with_base (fun path ->
    let log, _, _ = open_ok ~path in
    ignore (append_ok log (chain_from ~head:R.genesis ~count:4) : R.head);
    let step seen (record : R.t) =
      if record.R.seq = 3
      then Error (Printf.sprintf "refused after %d" (List.length seen))
      else Ok (record :: seen)
    in
    match L.open_at_start ~path ~init:[] ~step with
    | Ok _ -> Alcotest.fail "the fold refused line 3 but open succeeded"
    | Error (L.Fold_refused { line_number; reason; path = reported }) ->
      Alcotest.(check int) "line number" 3 line_number;
      Alcotest.(check string) "reason is the caller's" "refused after 2" reason;
      Alcotest.(check string) "path" path reported
    | Error (L.Locked _ | L.Unreadable _ | L.Line_rejected _) ->
      Alcotest.fail "wrong kind of open error")
;;

let parent_that_is_a_file () =
  Eio_main.run (fun _env ->
    let base = Filename.temp_dir "authz-log-" "" in
    Fun.protect
      ~finally:(fun () -> remove_tree base)
      (fun () ->
        write_file (Filename.concat base ".masc") "not a directory";
        let path = L.path_of_base_path ~base_path:base in
        match open_error ~path with
        | L.Unreadable { path = reported; detail } ->
          Alcotest.(check string) "path" path reported;
          Alcotest.(check bool) "detail is not empty" true (String.length detail > 0)
        | L.Locked _ | L.Line_rejected _ | L.Fold_refused _ ->
          Alcotest.fail "wrong kind of open error"))
;;

let log_path_is_a_directory () =
  with_base (fun path ->
    Fs_compat.mkdir_p path;
    check_open_error "a directory where the log should be" (Printf.sprintf "Unreadable path=%s" path) ~path)
;;

let file_with_two_names () =
  with_base (fun path ->
    let log, _, _ = open_ok ~path in
    ignore (append_ok log (chain_from ~head:R.genesis ~count:2) : R.head);
    (* A second name could be used to change the bytes without the path
       noticing; the store refuses such a file. *)
    Unix.link path (path ^ ".other-name");
    let before = read_file path in
    check_open_error "a file with two names" (Printf.sprintf "Unreadable path=%s" path) ~path;
    Alcotest.(check string) "the file is not touched" before (read_file path))
;;

(* ---- files that do not hold a chain ---- *)

let with_five_lines f =
  with_base (fun path ->
    let log, _, _ = open_ok ~path in
    ignore (append_ok log (chain_from ~head:R.genesis ~count:5) : R.head);
    f path)
;;

let expect_rejected path ~line_number ~error =
  check_open_error
    "the line that breaks the chain"
    (Printf.sprintf "Line_rejected path=%s line=%d %s" path line_number error)
    ~path
;;

let changed_body_breaks_the_hash () =
  with_five_lines (fun path ->
    rewrite_lines path ~f:(List.mapi (fun index line ->
      if index = 1 then replace_once ~sub:{|"n":2|} ~by:{|"n":9|} line else line));
    expect_rejected path ~line_number:2 ~error:"Hash_mismatch")
;;

let removed_line_breaks_the_sequence () =
  with_five_lines (fun path ->
    rewrite_lines path ~f:(List.filteri (fun index _ -> index <> 1));
    expect_rejected path ~line_number:2 ~error:"Seq_mismatch expected=2 actual=3")
;;

let swapped_lines_break_the_sequence () =
  with_five_lines (fun path ->
    rewrite_lines path ~f:(function
      | l1 :: l2 :: l3 :: rest -> l1 :: l3 :: l2 :: rest
      | _ -> Alcotest.fail "fixture is shorter than three lines");
    expect_rejected path ~line_number:2 ~error:"Seq_mismatch expected=2 actual=3")
;;

let first_line_replaced () =
  with_five_lines (fun path ->
    rewrite_lines path ~f:(fun lines -> "not a record" :: List.tl lines);
    expect_rejected path ~line_number:1 ~error:"Not_json")
;;

let empty_line_in_the_middle () =
  with_five_lines (fun path ->
    rewrite_lines path ~f:(function
      | l1 :: l2 :: rest -> l1 :: l2 :: "" :: rest
      | _ -> Alcotest.fail "fixture is shorter than two lines");
    expect_rejected path ~line_number:3 ~error:"Not_json")
;;

let line_that_is_not_the_written_form () =
  with_five_lines (fun path ->
    (* A space before the record: a record with a valid hash, but not the line
       that is written for it. *)
    rewrite_lines path ~f:(List.mapi (fun index line -> if index = 4 then " " ^ line else line));
    expect_rejected path ~line_number:5 ~error:"Non_canonical")
;;

let rejected_file_is_left_alone () =
  with_five_lines (fun path ->
    rewrite_lines path ~f:(List.filteri (fun index _ -> index <> 1));
    let before = read_file path in
    ignore (open_error ~path : unit L.open_error);
    Alcotest.(check string) "the file is not touched" before (read_file path))
;;

(* ---- a last line that never ended ---- *)

let torn_last_line_is_cut () =
  with_base (fun path ->
    let records = chain_from ~head:R.genesis ~count:3 in
    let complete = text_of (take 2 records) in
    let torn = R.to_line (List.nth records 2) in
    let fragment = String.sub torn 0 (String.length torn / 2) in
    Fs_compat.mkdir_p (Filename.dirname path);
    write_file path (complete ^ fragment);
    let log, state, recovered = open_ok ~path in
    check_contents "two lines survive" (L.Lines 2) recovered;
    (match recovered.L.tail with
     | L.Cut { kept_bytes; discarded_bytes } ->
       Alcotest.(check int) "kept bytes" (String.length complete) kept_bytes;
       Alcotest.(check int) "discarded bytes" (String.length fragment) discarded_bytes
     | L.Complete -> Alcotest.fail "the torn tail was not reported");
    check_seqs "replayed" [ 1; 2 ] state;
    Alcotest.(check string) "the file ends after the last complete line" complete (read_file path);
    ignore (append_ok log [ List.nth records 2 ] : R.head);
    let _, state, recovered = open_ok ~path in
    check_contents "three lines" (L.Lines 3) recovered;
    check_complete recovered;
    check_seqs "the third line written after the cut" [ 1; 2; 3 ] state)
;;

let file_that_is_only_a_fragment () =
  with_base (fun path ->
    let fragment = {|{"seq":1,"previous_hash":"00|} in
    Fs_compat.mkdir_p (Filename.dirname path);
    write_file path fragment;
    let _log, state, recovered = open_ok ~path in
    check_contents "nothing complete" L.Empty recovered;
    (match recovered.L.tail with
     | L.Cut { kept_bytes = 0; discarded_bytes } ->
       Alcotest.(check int) "discarded bytes" (String.length fragment) discarded_bytes
     | L.Cut _ | L.Complete -> Alcotest.fail "expected a cut down to zero bytes");
    check_seqs "nothing replayed" [] state;
    Alcotest.(check string) "the file is empty" "" (read_file path))
;;

(* ---- zones ---- *)

let zone_starts_at_the_head () =
  with_base (fun path ->
    let log, _, _ = open_ok ~path in
    Alcotest.(check int) "empty log" 1 (R.next_seq (head_of_log log));
    let appended = append_ok log (chain_from ~head:R.genesis ~count:2) in
    Alcotest.(check int) "head returned by append" 3 (R.next_seq appended);
    let seen = head_of_log log in
    Alcotest.(check int) "next zone starts at the head" 3 (R.next_seq seen);
    Alcotest.(check bool) "same hash" true (R.Hash.equal (R.head_hash appended) (R.head_hash seen)))
;;

let empty_list_writes_nothing () =
  with_base (fun path ->
    let log, _, _ = open_ok ~path in
    let head = append_ok log [] in
    Alcotest.(check int) "head unchanged" 1 (R.next_seq head);
    Alcotest.(check bool) "no file" false (Sys.file_exists path))
;;

let continuity_is_checked_before_any_byte () =
  with_base (fun path ->
    let log, _, _ = open_ok ~path in
    let three = chain_from ~head:R.genesis ~count:3 in
    let first, second, third = List.nth three 0, List.nth three 1, List.nth three 2 in
    ignore (append_ok log [ first ] : R.head);
    let before = read_file path in
    (* The first record again: seq 1 where 2 is next. *)
    check_append_error
      "a record that is behind"
      "Wrong_seq index=0 expected=2 actual=1"
      log
      [ first ];
    (* A record at seq 2 that names another record before it. *)
    let other_first = make_exn ~head:R.genesis ~n:99 in
    let wrong_parent = make_exn ~head:(R.head_after other_first) ~n:2 in
    check_append_error
      "a record that names another parent"
      "Wrong_previous_hash index=0"
      log
      [ wrong_parent ];
    (* A good record followed by a bad one: neither is written. *)
    check_append_error
      "the second record of a list does not continue"
      "Wrong_seq index=1 expected=3 actual=2"
      log
      [ second; second ];
    Alcotest.(check string) "no byte written by the refused calls" before (read_file path);
    (* None of these refusals stopped the log. *)
    Alcotest.(check bool) "not stopped" true (Option.is_none (L.stopped log));
    ignore (append_ok log [ second; third ] : R.head);
    let _, state, _ = open_ok ~path in
    check_seqs "the log still takes the chain" [ 1; 2; 3 ] state)
;;

let writer_expires_with_its_zone () =
  with_base (fun path ->
    let log, _, _ = open_ok ~path in
    let kept = in_zone log (fun writer _head -> writer) in
    Alcotest.(check string)
      "a writer outside its zone"
      "Writer_expired"
      (outcome_name (L.append kept (chain_from ~head:R.genesis ~count:1)));
    Alcotest.(check bool) "nothing written" false (Sys.file_exists path))
;;

exception Caller_failure

let exception_in_a_zone_leaves_the_log_usable () =
  with_base (fun path ->
    let log, _, _ = open_ok ~path in
    let records = chain_from ~head:R.genesis ~count:3 in
    Alcotest.check_raises "the caller's exception comes out unchanged" Caller_failure (fun () ->
      in_zone log (fun writer _head ->
        (match L.append writer (take 1 records) with
         | Ok _ -> ()
         | Error error -> Alcotest.failf "append refused: %s" (L.append_error_to_string error));
        raise Caller_failure));
    (* The line written before the exception is in the file and in the head. *)
    Alcotest.(check int) "head follows the write" 2 (R.next_seq (head_of_log log));
    ignore (append_ok log (List.tl records) : R.head);
    let _, state, _ = open_ok ~path in
    check_seqs "three lines" [ 1; 2; 3 ] state)
;;

let zones_do_not_overlap () =
  with_base (fun path ->
    let log, _, _ = open_ok ~path in
    let trace = ref [] in
    let note entry = trace := entry :: !trace in
    let zone name =
      in_zone log (fun writer head ->
        note (Printf.sprintf "%s enters at %d" name (R.next_seq head));
        (* Hand the domain over while holding the zone: the other fiber would
           run here if the zone did not keep it out. *)
        Eio.Fiber.yield ();
        Eio.Fiber.yield ();
        (match L.append writer [ make_exn ~head ~n:(R.next_seq head) ] with
         | Ok _ -> ()
         | Error error -> Alcotest.failf "append refused: %s" (L.append_error_to_string error));
        note (name ^ " leaves"))
    in
    Eio.Fiber.both (fun () -> zone "a") (fun () -> zone "b");
    let trace = List.rev !trace in
    let first, second =
      match trace with
      | entry :: _ when String.starts_with ~prefix:"a " entry -> "a", "b"
      | _ -> "b", "a"
    in
    Alcotest.(check (list string))
      "the second zone starts from the head the first one left"
      [ first ^ " enters at 1"; first ^ " leaves"; second ^ " enters at 2"; second ^ " leaves" ]
      trace;
    let _, state, _ = open_ok ~path in
    check_seqs "both lines" [ 1; 2 ] state)
;;

let cancelled_waiter_never_enters () =
  with_base (fun path ->
    let log, _, _ = open_ok ~path in
    let holder_inside, resolve_holder_inside = Eio.Promise.create () in
    let release, resolve_release = Eio.Promise.create () in
    let waiter_entered = ref false in
    Eio.Fiber.both
      (fun () ->
        in_zone log (fun _writer _head ->
          Eio.Promise.resolve resolve_holder_inside ();
          Eio.Promise.await release))
      (fun () ->
        Eio.Promise.await holder_inside;
        (match
           Eio.Fiber.first
             (fun () ->
               in_zone log (fun _writer _head -> waiter_entered := true);
               `Entered)
             (fun () ->
               Eio.Fiber.yield ();
               `Gave_up)
         with
         | `Gave_up -> ()
         | `Entered -> Alcotest.fail "the waiter entered a zone that was held");
        Eio.Promise.resolve resolve_release ());
    Alcotest.(check bool) "the cancelled waiter never ran its function" false !waiter_entered;
    (* The cancelled wait left the zone usable. *)
    ignore (append_ok log (chain_from ~head:R.genesis ~count:1) : R.head))
;;

let cancellation_waits_for_the_zone () =
  with_base (fun path ->
    let log, _, _ = open_ok ~path in
    let record = List.hd (chain_from ~head:R.genesis ~count:1) in
    let inside, resolve_inside = Eio.Promise.create () in
    let outcome =
      Eio.Fiber.first
        (fun () ->
          in_zone log (fun writer _head ->
            Eio.Promise.resolve resolve_inside ();
            (* The other fiber finishes while this one is suspended here, which
               cancels this fiber. Cancellation must not reach it before the
               zone ends. *)
            Eio.Fiber.yield ();
            (match L.append writer [ record ] with
             | Ok _ -> ()
             | Error error -> Alcotest.failf "append refused: %s" (L.append_error_to_string error));
            `Zone_finished))
        (fun () ->
          Eio.Promise.await inside;
          `Other_finished_first)
    in
    (match outcome with
     | `Other_finished_first -> ()
     | `Zone_finished -> Alcotest.fail "the zone finished before the other fiber");
    Alcotest.(check (list string))
      "the line of the cancelled zone is in the file"
      (lines_of [ record ])
      (lines_of_file path);
    Alcotest.(check int) "and in the head" 2 (R.next_seq (head_of_log log)))
;;

(* ---- another writer ---- *)

let second_log_on_the_same_file_diverges () =
  with_base (fun path ->
    let first, _, _ = open_ok ~path in
    let second, _, _ = open_ok ~path in
    let records = chain_from ~head:R.genesis ~count:2 in
    ignore (append_ok first (take 1 records) : R.head);
    let before = read_file path in
    let outcomes =
      in_zone second (fun writer _head ->
        let diverged = L.append writer (take 1 records) in
        (* The log that diverged refuses everything after it. *)
        let refused = L.append writer (take 1 records) in
        [ outcome_name diverged; outcome_name refused ])
    in
    Alcotest.(check (list string))
      "another log appended first, then the diverged log refuses"
      [ Printf.sprintf "Diverged path=%s" path; Printf.sprintf "Stopped path=%s" path ]
      outcomes;
    Alcotest.(check string) "the diverged log wrote nothing" before (read_file path);
    (match L.stopped second with
     | Some { L.path = reported; _ } -> Alcotest.(check string) "stop path" path reported
     | None -> Alcotest.fail "the diverged log is not stopped");
    (match L.with_writer second (fun _writer _head -> ()) with
     | Error _ -> ()
     | Ok () -> Alcotest.fail "a stopped log was entered");
    Alcotest.(check bool) "the other log is not stopped" true (Option.is_none (L.stopped first));
    (* The other log goes on. *)
    ignore (append_ok first [ List.nth records 1 ] : R.head);
    let _, state, _ = open_ok ~path in
    check_seqs "the file holds one chain" [ 1; 2 ] state)
;;

let outside_cut_diverges () =
  with_base (fun path ->
    let log, _, _ = open_ok ~path in
    let records = chain_from ~head:R.genesis ~count:3 in
    ignore (append_ok log (take 2 records) : R.head);
    Unix.truncate path 0;
    check_append_error
      "the file was cut from outside"
      (Printf.sprintf "Diverged path=%s" path)
      log
      [ List.nth records 2 ];
    Alcotest.(check bool) "stopped" true (Option.is_some (L.stopped log));
    Alcotest.(check string) "the file stays as it was left" "" (read_file path))
;;

let outside_replacement_diverges () =
  with_base (fun path ->
    let log, _, _ = open_ok ~path in
    let records = chain_from ~head:R.genesis ~count:3 in
    ignore (append_ok log (take 2 records) : R.head);
    (* The same bytes in another file. The old file stays on disk until the
       copy exists, so the copy cannot get the old inode number. *)
    let text = read_file path in
    Unix.rename path (path ^ ".replaced");
    write_file path text;
    check_append_error
      "the file was replaced from outside"
      (Printf.sprintf "Diverged path=%s" path)
      log
      [ List.nth records 2 ];
    Alcotest.(check bool) "stopped" true (Option.is_some (L.stopped log));
    Alcotest.(check string) "the copy stays as it was" text (read_file path))
;;

(* ---- a lock that another process holds ---- *)

let with_foreign_lock ~lock_path f =
  (* Close-on-exec, so that the child does not inherit the write end of the
     release pipe and the parent's close of it can reach the child as EOF. *)
  let ready_read, ready_write = Unix.pipe ~cloexec:true () in
  let release_read, release_write = Unix.pipe ~cloexec:true () in
  let pid =
    Unix.create_process
      Sys.executable_name
      [| Sys.executable_name; hold_lock_child_flag; lock_path |]
      release_read
      ready_write
      Unix.stderr
  in
  Unix.close ready_write;
  Unix.close release_read;
  let released = ref false in
  (* One byte ends the child's wait, and so does the close that follows it. *)
  let release () =
    if not !released
    then (
      released := true;
      Fun.protect
        ~finally:(fun () -> Unix.close release_write)
        (fun () ->
          if Unix.write_substring release_write "X" 0 1 <> 1
          then Alcotest.fail "the release byte was not written"))
  in
  let rec wait_for_child () =
    match Unix.waitpid [] pid with
    | result -> result
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait_for_child ()
  in
  Fun.protect
    ~finally:(fun () ->
      release ();
      ignore (wait_for_child () : int * Unix.process_status))
    (fun () ->
      let ready = Bytes.create 1 in
      let count = Unix.read ready_read ready 0 1 in
      Unix.close ready_read;
      if count <> 1 || Bytes.get ready 0 <> 'R'
      then Alcotest.fail "the lock holder did not start";
      f release)
;;

let foreign_lock_blocks_open_and_append () =
  with_base (fun path ->
    let log, _, _ = open_ok ~path in
    let records = chain_from ~head:R.genesis ~count:2 in
    ignore (append_ok log (take 1 records) : R.head);
    let before = read_file path in
    with_foreign_lock ~lock_path:(Fs_compat.private_jsonl_lock_path path) (fun release ->
      check_append_error
        "append while another process holds the lock"
        (Printf.sprintf "Write_locked path=%s" path)
        log
        [ List.nth records 1 ];
      check_open_error
        "open while another process holds the lock"
        (Printf.sprintf "Locked path=%s" path)
        ~path;
      Alcotest.(check string) "nothing written while the lock was held" before (read_file path);
      release ());
    (* A refusal that wrote nothing does not stop the log. *)
    ignore (append_ok log [ List.nth records 1 ] : R.head);
    let _, state, _ = open_ok ~path in
    check_seqs "both lines once the lock is free" [ 1; 2 ] state)
;;

(* ---- a write that fails ---- *)

let failed_write_stops_the_log () =
  (* The superuser writes to a file of mode 0400. *)
  if Unix.geteuid () = 0 then Alcotest.skip ();
  with_base (fun path ->
    let log, _, _ = open_ok ~path in
    let records = chain_from ~head:R.genesis ~count:3 in
    ignore (append_ok log (take 1 records) : R.head);
    let before = read_file path in
    Unix.chmod path 0o400;
    Fun.protect
      ~finally:(fun () -> Unix.chmod path 0o600)
      (fun () ->
        check_append_error
          "a file that cannot be written"
          (Printf.sprintf "Write_failed path=%s" path)
          log
          [ List.nth records 1 ]);
    Alcotest.(check string) "nothing was written" before (read_file path);
    (* The file is writable again, but this process no longer knows its end. *)
    (match L.stopped log with
     | Some { L.path = reported; _ } -> Alcotest.(check string) "stop path" path reported
     | None -> Alcotest.fail "the log is not stopped after an unknown failure");
    (match L.with_writer log (fun _writer _head -> ()) with
     | Error _ -> ()
     | Ok () -> Alcotest.fail "a stopped log was entered");
    (* A new start reads the file, which is the only truth. *)
    let restarted, state, _ = open_ok ~path in
    check_seqs "the file holds what was acknowledged" [ 1 ] state;
    ignore (append_ok restarted (List.tl records) : R.head);
    let _, state, _ = open_ok ~path in
    check_seqs "the restarted log writes" [ 1; 2; 3 ] state)
;;

(* ---- error messages ---- *)

(* Not the wording: the facts an operator needs to find the problem. *)
let open_errors_name_the_file_and_line () =
  let path = "/base/.masc/auth/authz.jsonl" in
  let to_string = L.open_error_to_string Fun.id in
  let line_number = 42 in
  List.iter
    (fun (label, error, names_line) ->
      let text = to_string error in
      Alcotest.(check bool) (label ^ " names the file") true (contains ~sub:path text);
      if names_line
      then
        Alcotest.(check bool)
          (label ^ " names the line")
          true
          (contains ~sub:(string_of_int line_number) text))
    [ "Locked", L.Locked { path }, false
    ; "Unreadable", L.Unreadable { path; detail = "boom" }, false
    ; "Line_rejected", L.Line_rejected { path; line_number; error = R.Hash_mismatch }, true
    ; "Fold_refused", L.Fold_refused { path; line_number; reason = "no" }, true
    ];
  Alcotest.(check bool)
    "the caller's reason is in the message"
    true
    (contains ~sub:"because" (to_string (L.Fold_refused { path; line_number; reason = "because" })))
;;

let () =
  Alcotest.run
    "authz_log"
    [ ( "open"
      , [ Alcotest.test_case "path" `Quick path_is_under_the_auth_directory
        ; Alcotest.test_case "missing file" `Quick missing_file
        ; Alcotest.test_case "empty file" `Quick empty_file
        ; Alcotest.test_case "append then reopen" `Quick append_then_reopen
        ; Alcotest.test_case "many records in one write" `Quick many_records_in_one_write
        ; Alcotest.test_case "fold refusal names the line" `Quick fold_refusal_names_the_line
        ; Alcotest.test_case "parent that is a file" `Quick parent_that_is_a_file
        ; Alcotest.test_case "log path is a directory" `Quick log_path_is_a_directory
        ; Alcotest.test_case "file with two names" `Quick file_with_two_names
        ; Alcotest.test_case "errors name file and line" `Quick open_errors_name_the_file_and_line
        ] )
    ; ( "files that do not hold a chain"
      , [ Alcotest.test_case "changed body" `Quick changed_body_breaks_the_hash
        ; Alcotest.test_case "removed line" `Quick removed_line_breaks_the_sequence
        ; Alcotest.test_case "swapped lines" `Quick swapped_lines_break_the_sequence
        ; Alcotest.test_case "first line replaced" `Quick first_line_replaced
        ; Alcotest.test_case "empty line" `Quick empty_line_in_the_middle
        ; Alcotest.test_case "line not in written form" `Quick line_that_is_not_the_written_form
        ; Alcotest.test_case "rejected file is left alone" `Quick rejected_file_is_left_alone
        ] )
    ; ( "last line that never ended"
      , [ Alcotest.test_case "torn last line is cut" `Quick torn_last_line_is_cut
        ; Alcotest.test_case "only a fragment" `Quick file_that_is_only_a_fragment
        ] )
    ; ( "zones"
      , [ Alcotest.test_case "starts at the head" `Quick zone_starts_at_the_head
        ; Alcotest.test_case "empty list writes nothing" `Quick empty_list_writes_nothing
        ; Alcotest.test_case "continuity before any byte" `Quick continuity_is_checked_before_any_byte
        ; Alcotest.test_case "writer expires" `Quick writer_expires_with_its_zone
        ; Alcotest.test_case "exception leaves log usable" `Quick exception_in_a_zone_leaves_the_log_usable
        ; Alcotest.test_case "zones do not overlap" `Quick zones_do_not_overlap
        ; Alcotest.test_case "cancelled waiter never enters" `Quick cancelled_waiter_never_enters
        ; Alcotest.test_case "cancellation waits for the zone" `Quick cancellation_waits_for_the_zone
        ] )
    ; ( "another writer"
      , [ Alcotest.test_case "second log diverges" `Quick second_log_on_the_same_file_diverges
        ; Alcotest.test_case "outside cut diverges" `Quick outside_cut_diverges
        ; Alcotest.test_case "outside replacement diverges" `Quick outside_replacement_diverges
        ; Alcotest.test_case "foreign lock" `Quick foreign_lock_blocks_open_and_append
        ] )
    ; "failed write", [ Alcotest.test_case "failed write stops the log" `Quick failed_write_stops_the_log ]
    ]
;;
