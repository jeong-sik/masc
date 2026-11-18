(* A Keeper's turn log on disk (RFC librarian-call-only-proposes §5.2): what
   the tail says after each kind of line, and what an append does when the
   end it names is not the end. *)

open Alcotest
module Log = Masc.Keeper_turn_log
module Codec = Masc.Keeper_turn_log_codec
module Store = Masc.Keeper_turn_log_store

let log_id =
  match Log.Log_id.of_string (String.make 32 'a') with
  | Some id -> id
  | None -> fail "the test log id is not 32 hexadecimal characters"
;;

let turn_ref = Ids.Turn_ref.make ~trace_id:"trace-1" ~absolute_turn:7

let mark closed_messages : Log.mark =
  { trace = "trace-1"
  ; closed_messages
  ; session = ""
  ; history_bytes = 0
  ; internal_bytes = 0
  ; chat_bytes = 0
  ; external_rows = 0
  }
;;

let started = Log.Log_started { id = log_id; at = 100.0; mark = mark 4 }

let opened baseline =
  Log.Opened { at = 101.0; turn_ref; runtime = "glm-main"; task = No_task; baseline = mark baseline }
;;

let closed ?(outcome = Log.Completed) turn after =
  Log.Closed { turn; at = 102.0; outcome; after = mark after; unattributed = []; own = [] }
;;

let reset before after =
  Log.Reset
    { at = 103.0; cause = Unannounced; before = mark before; after = mark after; closed_before = [] }
;;

let new_path () =
  Store.path_for_keepers_dir ~keepers_dir:(Filename.temp_dir "turn-log" "") ~keeper_id:"keeper-a"
;;

let read_error_text : Store.read_error -> string = function
  | Read_failed { detail; _ } -> "read failed: " ^ detail
  | Row_undecodable { offset; reason = Not_json } -> Printf.sprintf "row at %d is not JSON" offset
  | Row_undecodable { offset; reason = Malformed error } ->
    Printf.sprintf "row at %d: %s" offset (Masc.Keeper_memory_os_types.wire_error_to_string error)
  | Log_start_missing -> "log start missing"
  | Moved_while_reading -> "moved while reading"
;;

let append_error_text : Store.append_error -> string = function
  | End_moved { expected; actual } -> Printf.sprintf "end moved from %d to %d" expected actual
  | Directory_unavailable { detail; _ } -> "directory unavailable: " ^ detail
  | Write_failed { detail; _ } -> "write failed: " ^ detail
;;

(* The tail as text: where to append, where the next unit starts, the open
   turn, and the kind of the last line. *)
let tail_text path =
  match Store.read_tail path with
  | Error error -> read_error_text error
  | Ok Nothing_written -> "nothing written"
  | Ok (Written { rows_end; point; open_turn; last }) ->
    Printf.sprintf "end %d, next unit from %d, %s, last %s" rows_end point.closed_messages
      (match open_turn with
       | None -> "no open turn"
       | Some { opened; baseline; reset_since } ->
         Printf.sprintf "turn open at %d from %d%s" opened baseline.closed_messages
           (if reset_since then " and reset since" else ""))
      (match last with
       | Log_started _ -> "log_started"
       | Opened _ -> "opened"
       | Closed _ -> "closed"
       | Reset _ -> "reset")
;;

let appended_at path ~at_end lines =
  match Store.append ~path ~at_end lines with
  | Ok appended -> appended
  | Error error -> failf "append at %d: %s" at_end (append_error_text error)
;;

let appended path ~at_end lines = (appended_at path ~at_end lines).new_end

let length_of line = String.length (Yojson.Safe.to_string (Codec.to_json line)) + 1

let write_raw path text =
  Out_channel.with_open_gen [ Open_wronly; Open_append; Open_creat; Open_binary ] 0o600 path
    (fun channel -> Out_channel.output_string channel text)
;;

let file_bytes path = In_channel.with_open_bin path In_channel.input_all

let test_tail_after_each_line () =
  let path = new_path () in
  check string "no file" "nothing written" (tail_text path);
  let after_start = appended path ~at_end:0 (started, []) in
  check int "the append returns the new end" (length_of started) after_start;
  check string "a started log"
    (Printf.sprintf "end %d, next unit from 4, no open turn, last log_started" after_start)
    (tail_text path);
  let after_opened = appended path ~at_end:after_start (opened 5, []) in
  check string "an admitted turn: the point has not moved"
    (Printf.sprintf "end %d, next unit from 4, turn open at %d from 5, last opened" after_opened
       after_start)
    (tail_text path);
  let after_resets = appended path ~at_end:after_opened (reset 6 0, [ reset 0 2 ]) in
  check string "resets inside the turn move the point and leave the turn open"
    (Printf.sprintf "end %d, next unit from 2, turn open at %d from 5 and reset since, last reset"
       after_resets
       after_start)
    (tail_text path);
  let after_closed = appended path ~at_end:after_resets (closed after_start 9, []) in
  check string "a closed turn"
    (Printf.sprintf "end %d, next unit from 9, no open turn, last closed" after_closed)
    (tail_text path);
  let after_reset = appended path ~at_end:after_closed (reset 9 0, []) in
  check string "a reset between turns"
    (Printf.sprintf "end %d, next unit from 0, no open turn, last reset" after_reset)
    (tail_text path)
;;

(* An admission that finds the last turn unclosed closes it and opens its own
   in one append. *)
let test_two_lines_in_one_append () =
  let path = new_path () in
  let after_start = appended path ~at_end:0 (started, []) in
  let after_opened = appended path ~at_end:after_start (opened 5, []) in
  let missing = closed ~outcome:Close_missing after_start 8 in
  let both = appended_at path ~at_end:after_opened (missing, [ opened 8 ]) in
  let after_both = both.new_end in
  check int "both lines landed" (after_opened + length_of missing + length_of (opened 8)) after_both;
  check int "the append says where its last line starts" (after_opened + length_of missing)
    both.last_at;
  check string "the second line is the open turn"
    (Printf.sprintf "end %d, next unit from 8, turn open at %d from 8, last opened" after_both
       (after_opened + length_of missing))
    (tail_text path)
;;

let test_stale_end_writes_nothing () =
  let path = new_path () in
  let after_start = appended path ~at_end:0 (started, []) in
  let after_opened = appended path ~at_end:after_start (opened 5, []) in
  let before = file_bytes path in
  (match Store.append ~path ~at_end:after_start (opened 5, []) with
   | Error (End_moved { expected; actual }) ->
     check (pair int int) "the append names both ends" (after_start, after_opened)
       (expected, actual)
   | Error other -> failf "expected End_moved, got %s" (append_error_text other)
   | Ok (_ : Store.appended) -> fail "an append at a stale end was written");
  check string "the file is as it was" before (file_bytes path)
;;

(* The file was replaced by one of the same length that ends in a fragment.
   The end that was read is its length, yet no row ends there. *)
let test_replaced_by_a_file_that_ends_in_a_fragment () =
  let path = new_path () in
  let after_start = appended path ~at_end:0 (started, []) in
  let replacement = String.make after_start 'x' in
  Out_channel.with_open_bin path (fun channel -> Out_channel.output_string channel replacement);
  (match Store.append ~path ~at_end:after_start (opened 5, []) with
   | Error (End_moved { expected; actual }) ->
     check (pair int int) "the caller is told to read the tail again" (after_start, after_start)
       (expected, actual)
   | Error other -> failf "expected End_moved, got %s" (append_error_text other)
   | Ok (_ : Store.appended) -> fail "an append after a fragment that was counted as rows");
  check string "the file is as it was" replacement (file_bytes path)
;;

(* A crash can leave the start of a line with no line break. It was never a
   line: the tail stops before it and the next append cuts it. *)
let test_torn_fragment () =
  let path = new_path () in
  let after_start = appended path ~at_end:0 (started, []) in
  write_raw path {|{"line":"opened","at":10|};
  check string "the tail stops before the fragment"
    (Printf.sprintf "end %d, next unit from 4, no open turn, last log_started" after_start)
    (tail_text path);
  let after_opened = appended path ~at_end:after_start (opened 5, []) in
  check int "the append wrote from the last line break" (after_start + length_of (opened 5))
    after_opened;
  check int "and the fragment is gone" after_opened (String.length (file_bytes path));
  let only_fragment = new_path () in
  Unix.mkdir (Filename.dirname only_fragment) 0o700;
  write_raw only_fragment {|{"line":"log_st|};
  check string "a file that holds only a fragment" "nothing written" (tail_text only_fragment);
  let landed = appended only_fragment ~at_end:0 (started, []) in
  check int "an append at 0 cuts it" (length_of started) landed
;;

let test_tail_that_cannot_be_read () =
  let path = new_path () in
  let after_start = appended path ~at_end:0 (started, []) in
  write_raw path "not json\n";
  check string "a line that is not JSON"
    (Printf.sprintf "row at %d is not JSON" after_start)
    (tail_text path);
  let other = new_path () in
  let after_start = appended other ~at_end:0 (started, []) in
  write_raw other "{\"line\":\"finished\"}\n";
  check string "a line of an unknown kind"
    (Printf.sprintf "row at %d: %s" after_start
       (Masc.Keeper_memory_os_types.wire_error_to_string
          { path = [ Wire_field "line" ]; reason = Unknown_token "finished" }))
    (tail_text other);
  let headless = new_path () in
  let (_ : int) = appended headless ~at_end:0 (reset 3 0, []) in
  check string "lines with no start" "log start missing" (tail_text headless)
;;

(* An undecodable line farther back than the tail needs is not read. *)
let test_reads_only_as_far_as_it_must () =
  let path = new_path () in
  Unix.mkdir (Filename.dirname path) 0o700;
  write_raw path "not json\n";
  let garbage = String.length "not json\n" in
  let after_closed = appended path ~at_end:garbage (closed 0 9, []) in
  check string "the walk stops at the closed line"
    (Printf.sprintf "end %d, next unit from 9, no open turn, last closed" after_closed)
    (tail_text path)
;;

let () =
  run "keeper_turn_log_store"
    [ ( "tail"
      , [ test_case "after each kind of line" `Quick test_tail_after_each_line
        ; test_case "a torn fragment" `Quick test_torn_fragment
        ; test_case "a tail that cannot be read" `Quick test_tail_that_cannot_be_read
        ; test_case "reads only as far as it must" `Quick test_reads_only_as_far_as_it_must
        ] )
    ; ( "append"
      , [ test_case "two lines in one append" `Quick test_two_lines_in_one_append
        ; test_case "a stale end writes nothing" `Quick test_stale_end_writes_nothing
        ; test_case "a file replaced by one that ends in a fragment" `Quick
            test_replaced_by_a_file_that_ends_in_a_fragment
        ] )
    ]
;;
