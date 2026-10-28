(* Checks for the file machinery under the authorization log, with line formats
   that have nothing to do with [Authz_record]. The cases of [test_authz_log]
   run the same machinery through the format of the log. These cases show what
   the module takes from the format and nothing else: the state that each line
   advances, the refusal of a record before any byte is written, the read-back
   of a line, and the texts of the errors. Every case runs on real files in a
   fresh temporary directory, through the production path of [Fs_compat]. *)

module J = Authz_jsonl_file

(* A file of numbers, one per line. The k-th line holds k, so the state is the
   number of lines so far. *)
module Counter = struct
  type state = int
  type record = int

  type line_error =
    | Not_a_number of string
    | Not_the_next of
        { expected : int
        ; actual : int
        }

  type reject =
    | Skips of
        { expected : int
        ; actual : int
        }

  let description = "counter file"
  let thread_label = "counter-file"
  let genesis = 0

  let of_line count line =
    match int_of_string_opt line with
    | None -> Error (Not_a_number line)
    | Some number when number = count + 1 -> Ok number
    | Some number -> Error (Not_the_next { expected = count + 1; actual = number })
  ;;

  let to_line = string_of_int
  let advance _count number = number

  let check_next count number =
    if number = count + 1 then Ok () else Error (Skips { expected = count + 1; actual = number })
  ;;

  let describe_state count = Printf.sprintf "%d lines so far" count

  let line_error_to_string = function
    | Not_a_number text -> Printf.sprintf "%S is not a number" text
    | Not_the_next { expected; actual } ->
      Printf.sprintf "the line holds %d where %d was expected" actual expected
  ;;

  let reject_to_string (Skips { expected; actual }) =
    Printf.sprintf "%d skips %d" actual expected
  ;;
end

(* The same file, except that the line it writes is not one that it reads. *)
module Broken = struct
  include Counter

  let to_line number = string_of_int number ^ "!"
end

module Numbers = J.Make (Counter)
module Broken_numbers = J.Make (Broken)

(* ---- fixtures ---- *)

let read_file path = In_channel.with_open_bin path In_channel.input_all

let write_file path text =
  Fs_compat.mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun channel -> Out_channel.output_string channel text)
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

(* A fresh path, inside an Eio event loop because the zone is an [Eio.Mutex]. *)
let with_path f =
  Eio_main.run (fun _env ->
    let dir = Filename.temp_dir "authz-jsonl-file-" "" in
    Fun.protect
      ~finally:(fun () -> remove_tree dir)
      (fun () -> f (Filename.concat (Filename.concat dir "numbers") "counter.jsonl")))
;;

let collect state record = Ok (record :: state)

let open_ok ~path =
  match Numbers.open_at_start ~path ~init:[] ~step:collect with
  | Ok (file, state, recovered) -> file, List.rev state, recovered
  | Error error ->
    Alcotest.failf "open refused: %s" (Numbers.open_error_to_string (fun () -> "") error)
;;

let in_zone file f =
  match Numbers.with_writer file f with
  | Ok value -> value
  | Error stop -> Alcotest.failf "the file is stopped: %s" stop.J.reason
;;

let state_of file = in_zone file (fun _writer state -> state)

let append_ok file numbers =
  in_zone file (fun writer _state ->
    match Numbers.append writer numbers with
    | Ok state -> state
    | Error error -> Alcotest.failf "append refused: %s" (Numbers.append_error_to_string error))
;;

let append_error file numbers =
  in_zone file (fun writer _state ->
    match Numbers.append writer numbers with
    | Ok _ -> Alcotest.fail "append succeeded where it should have been refused"
    | Error error -> error)
;;

let contents_name = function
  | J.Missing -> "Missing"
  | J.Empty -> "Empty"
  | J.Lines count -> Printf.sprintf "Lines %d" count
;;

(* Every constructor is named, so that a new one fails to compile until the
   cases below have decided what it means for them. *)
let numbers_append_error_name : Numbers.append_error -> string = function
  | Numbers.Writer_expired -> "Writer_expired"
  | Numbers.Stopped { path; _ } -> Printf.sprintf "Stopped path=%s" path
  | Numbers.Rejected { index; reject = Counter.Skips { expected; actual } } ->
    Printf.sprintf "Rejected index=%d expected=%d actual=%d" index expected actual
  | Numbers.Would_not_read_back { index; _ } -> Printf.sprintf "Would_not_read_back index=%d" index
  | Numbers.Write_locked { path } -> Printf.sprintf "Write_locked path=%s" path
  | Numbers.Diverged { path } -> Printf.sprintf "Diverged path=%s" path
  | Numbers.Write_failed { path; _ } -> Printf.sprintf "Write_failed path=%s" path
;;

let contains ~sub text =
  let sub_length = String.length sub
  and length = String.length text in
  let rec at index =
    index + sub_length <= length && (String.equal (String.sub text index sub_length) sub || at (index + 1))
  in
  at 0
;;

(* ---- the state that each line advances ---- *)

let lines_advance_the_state () =
  with_path (fun path ->
    let file, state, recovered = open_ok ~path in
    Alcotest.(check string) "no file" "Missing" (contents_name recovered.J.contents);
    Alcotest.(check (list int)) "nothing replayed" [] state;
    Alcotest.(check int) "the zone starts at the genesis" 0 (state_of file);
    Alcotest.(check int) "append returns the state after the last record" 3 (append_ok file [ 1; 2; 3 ]);
    Alcotest.(check int) "the next zone starts there" 3 (state_of file);
    Alcotest.(check string) "the bytes of the file" "1\n2\n3\n" (read_file path);
    let reopened, state, recovered = open_ok ~path in
    Alcotest.(check (list int)) "replayed in file order" [ 1; 2; 3 ] state;
    Alcotest.(check string) "three lines" "Lines 3" (contents_name recovered.J.contents);
    (match recovered.J.tail with
     | J.Complete -> ()
     | J.Cut _ -> Alcotest.fail "the tail of a complete file was cut");
    Alcotest.(check int) "a reopened zone starts at the state of the replay" 3 (state_of reopened))
;;

let refused_record_leaves_the_state () =
  with_path (fun path ->
    let file, _, _ = open_ok ~path in
    ignore (append_ok file [ 1; 2 ] : int);
    Alcotest.(check string)
      "the record that skips a number"
      "Rejected index=0 expected=3 actual=4"
      (numbers_append_error_name (append_error file [ 4 ]));
    Alcotest.(check int) "the state is where it was" 2 (state_of file);
    Alcotest.(check string) "the file is as it was" "1\n2\n" (read_file path);
    Alcotest.(check int) "the right record is written after the refusal" 3 (append_ok file [ 3 ]))
;;

let refusal_names_the_record_and_writes_nothing () =
  with_path (fun path ->
    let file, _, _ = open_ok ~path in
    Alcotest.(check string)
      "the third record skips"
      "Rejected index=2 expected=3 actual=4"
      (numbers_append_error_name (append_error file [ 1; 2; 4 ]));
    Alcotest.(check bool) "not even the first two records are written" false (Sys.file_exists path);
    Alcotest.(check int) "an empty list writes nothing" 0 (append_ok file []);
    Alcotest.(check bool) "no file after an empty list" false (Sys.file_exists path))
;;

(* ---- the read-back of a line ---- *)

let line_that_does_not_read_back_is_not_written () =
  with_path (fun path ->
    let file =
      match Broken_numbers.open_at_start ~path ~init:() ~step:(fun () _ -> Ok ()) with
      | Ok (file, (), _) -> file
      | Error _ -> Alcotest.fail "open refused"
    in
    let outcome =
      match
        Broken_numbers.with_writer file (fun writer _state -> Broken_numbers.append writer [ 1 ])
      with
      | Ok outcome -> outcome
      | Error _ -> Alcotest.fail "the file is stopped"
    in
    (match outcome with
     | Error (Broken_numbers.Would_not_read_back { index; error }) ->
       Alcotest.(check string)
         "the record and the reason"
         "0 \"1!\" is not a number"
         (Printf.sprintf "%d %s" index (Counter.line_error_to_string error))
     | Error
         ( Broken_numbers.Writer_expired
         | Broken_numbers.Stopped _
         | Broken_numbers.Rejected _
         | Broken_numbers.Write_locked _
         | Broken_numbers.Diverged _
         | Broken_numbers.Write_failed _ ) -> Alcotest.fail "wrong error"
     | Ok _ -> Alcotest.fail "a line that cannot be read back was written");
    Alcotest.(check bool) "nothing was written" false (Sys.file_exists path);
    Alcotest.(check bool)
      "a refusal that wrote nothing does not stop the file"
      true
      (Option.is_none (Broken_numbers.stopped file)))
;;

(* ---- what the format says about the lines of a file ---- *)

let open_error_name : _ Numbers.open_error -> string = function
  | Numbers.Locked { path } -> Printf.sprintf "Locked path=%s" path
  | Numbers.Unreadable { path; _ } -> Printf.sprintf "Unreadable path=%s" path
  | Numbers.Line_rejected { path; line_number; error = Counter.Not_a_number text } ->
    Printf.sprintf "Line_rejected path=%s line=%d not a number %S" path line_number text
  | Numbers.Line_rejected { path; line_number; error = Counter.Not_the_next { expected; actual } } ->
    Printf.sprintf "Line_rejected path=%s line=%d expected=%d actual=%d" path line_number expected actual
  | Numbers.Fold_refused { path; line_number; _ } ->
    Printf.sprintf "Fold_refused path=%s line=%d" path line_number
;;

let check_open_error label expected ~path ~step =
  match Numbers.open_at_start ~path ~init:[] ~step with
  | Ok _ -> Alcotest.failf "%s: open succeeded where it should have been refused" label
  | Error error -> Alcotest.(check string) label expected (open_error_name error)
;;

let format_decides_the_next_line () =
  with_path (fun path ->
    write_file path "1\n2\n4\n";
    check_open_error
      "a number that skips one"
      (Printf.sprintf "Line_rejected path=%s line=3 expected=3 actual=4" path)
      ~path
      ~step:collect;
    Alcotest.(check string) "a rejected file is left alone" "1\n2\n4\n" (read_file path);
    write_file path "1\nx\n";
    check_open_error
      "a line that is not a number"
      (Printf.sprintf "Line_rejected path=%s line=2 not a number \"x\"" path)
      ~path
      ~step:collect)
;;

let fold_refusal_names_the_line () =
  with_path (fun path ->
    write_file path "1\n2\n3\n";
    let refuse_two state record = if record = 2 then Error "two" else Ok (record :: state) in
    check_open_error
      "the fold refuses the second record"
      (Printf.sprintf "Fold_refused path=%s line=2" path)
      ~path
      ~step:refuse_two)
;;

(* ---- a last line that never ended ---- *)

let torn_last_line_is_cut () =
  with_path (fun path ->
    write_file path "1\n2\n3";
    let file, state, recovered = open_ok ~path in
    Alcotest.(check (list int)) "the complete lines" [ 1; 2 ] state;
    Alcotest.(check string) "two lines" "Lines 2" (contents_name recovered.J.contents);
    (match recovered.J.tail with
     | J.Cut { kept_bytes; discarded_bytes } ->
       Alcotest.(check int) "kept bytes" 4 kept_bytes;
       Alcotest.(check int) "discarded bytes" 1 discarded_bytes
     | J.Complete -> Alcotest.fail "the torn tail was not reported");
    Alcotest.(check string) "the file ends after the last complete line" "1\n2\n" (read_file path);
    Alcotest.(check int) "the zone starts after the last complete line" 2 (state_of file);
    ignore (append_ok file [ 3 ] : int);
    let _, state, _ = open_ok ~path in
    Alcotest.(check (list int)) "the third line written after the cut" [ 1; 2; 3 ] state)
;;

(* The warning is what an operator has of a cut, so it carries the facts: the
   file, how many bytes went and how many stayed, and where the state stands.
   Each number is checked next to the word that says which number it is. *)
let latest_ring_seq () =
  match Log.Ring.recent ~limit:1 () with
  | entry :: _ -> entry.Log.Ring.seq
  | [] -> 0
;;

let cut_tail_is_reported () =
  with_path (fun path ->
    write_file path "1\n2\n3\n4\n5\n6\n7\n8\n9\n10";
    let before = latest_ring_seq () in
    let _file, state, _recovered = open_ok ~path in
    Alcotest.(check int) "nine complete lines" 9 (List.length state);
    let messages =
      List.map
        (fun (entry : Log.Ring.entry) -> entry.message)
        (Log.Ring.recent ~limit:50 ~module_filter:"Auth" ~since_seq:before ())
    in
    match List.filter (contains ~sub:path) messages with
    | [ message ] ->
      Alcotest.(check bool) "it names the format of the file" true (contains ~sub:"counter file" message);
      Alcotest.(check bool) "the bytes cut" true (contains ~sub:"cut 2 bytes" message);
      Alcotest.(check bool) "the bytes kept" true (contains ~sub:"kept 18 bytes" message);
      Alcotest.(check bool)
        "where the state stands, as the format says it"
        true
        (contains ~sub:"9 lines so far" message)
    | other ->
      Alcotest.failf "expected one warning that names the file, found %d" (List.length other))
;;

(* ---- the texts of the errors ---- *)

let texts_name_the_file_the_line_and_the_format () =
  let path = "/base/numbers/counter.jsonl" in
  let open_text error = Numbers.open_error_to_string Fun.id error in
  List.iter
    (fun (label, text, needles) ->
      List.iter
        (fun needle -> Alcotest.(check bool) (label ^ " holds " ^ needle) true (contains ~sub:needle text))
        needles)
    [ "Locked", open_text (Numbers.Locked { path }), [ "counter file"; path ]
    ; "Unreadable", open_text (Numbers.Unreadable { path; detail = "boom" }), [ "counter file"; path; "boom" ]
    ; ( "Line_rejected"
      , open_text
          (Numbers.Line_rejected
             { path; line_number = 42; error = Counter.Not_the_next { expected = 7; actual = 9 } })
      , [ "counter file"; path; "42"; "holds 9 where 7 was expected" ] )
    ; ( "Fold_refused"
      , open_text (Numbers.Fold_refused { path; line_number = 42; reason = "because" })
      , [ "counter file"; path; "42"; "because" ] )
    ; ( "Rejected"
      , Numbers.append_error_to_string
          (Numbers.Rejected { index = 3; reject = Counter.Skips { expected = 5; actual = 8 } })
      , [ "3"; "8 skips 5" ] )
    ; ( "Would_not_read_back"
      , Numbers.append_error_to_string
          (Numbers.Would_not_read_back { index = 3; error = Counter.Not_a_number "1!" })
      , [ "3"; "\"1!\" is not a number" ] )
    ; "Stopped", Numbers.append_error_to_string (Numbers.Stopped { path; reason = "why" }), [ "counter file"; path; "why" ]
    ; "Diverged", Numbers.append_error_to_string (Numbers.Diverged { path }), [ "counter file"; path ]
    ]
;;

let () =
  Alcotest.run
    "authz_jsonl_file"
    [ ( "state"
      , [ Alcotest.test_case "lines advance the state" `Quick lines_advance_the_state
        ; Alcotest.test_case "refused record leaves the state" `Quick refused_record_leaves_the_state
        ; Alcotest.test_case
            "refusal names the record"
            `Quick
            refusal_names_the_record_and_writes_nothing
        ] )
    ; ( "read-back"
      , [ Alcotest.test_case
            "line that does not read back"
            `Quick
            line_that_does_not_read_back_is_not_written
        ] )
    ; ( "format of a file"
      , [ Alcotest.test_case "format decides the next line" `Quick format_decides_the_next_line
        ; Alcotest.test_case "fold refusal names the line" `Quick fold_refusal_names_the_line
        ] )
    ; ( "last line"
      , [ Alcotest.test_case "torn last line is cut" `Quick torn_last_line_is_cut
        ; Alcotest.test_case "the cut is reported" `Quick cut_tail_is_reported
        ] )
    ; ( "texts"
      , [ Alcotest.test_case
            "names file, line and format"
            `Quick
            texts_name_the_file_the_line_and_the_format
        ] )
    ]
;;
