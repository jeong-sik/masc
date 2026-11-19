(* A Keeper's commit log on disk (RFC librarian-call-only-proposes §8.2
   step 4, §8.6): what the tail says, what is not a line, and what an append
   does when the end it names is not the end. *)

open Alcotest
module Log = Masc.Librarian_log
module Codec = Masc.Librarian_log_codec
module Store = Masc.Librarian_log_store
module Effects = Masc.Librarian_effects
module Turn_log = Masc.Keeper_turn_log

let turn_log =
  match Turn_log.Log_id.of_string (String.make 32 'a') with
  | Some id -> id
  | None -> fail "the test log id is not 32 hexadecimal characters"
;;

let digest fill =
  match Agent_core.Checkpoint_objects.digest_of_hex (String.make 64 fill) with
  | Ok digest -> digest
  | Error detail -> fail detail
;;

let covered : Turn_log.mark =
  { trace = "trace-1"
  ; closed_messages = 4
  ; session = ""
  ; history_bytes = 0
  ; internal_bytes = 0
  ; chat_bytes = 0
  ; external_rows = 0
  }
;;

let started =
  Log.Started
    { at = 100.0
    ; turn_log
    ; snapshot = digest 'a'
    ; revision = 0
    ; turn_log_offset = 0
    ; covered
    }
;;

let committed seq =
  Log.Committed
    { seq
    ; at = 200.0
    ; basis = digest 'a'
    ; after = digest 'b'
    ; revision = seq
    ; cause = Adopt { by = "operator-1"; observed = digest 'b' }
    ; effects = Effects.empty
    ; turn_log
    ; turn_log_offset = 0
    ; covers_through = Before_first
    ; covered
    ; working_state = None
    }
;;

let new_path () =
  Store.path_for_keepers_dir ~keepers_dir:(Filename.temp_dir "commit-log" "") ~keeper_id:"keeper-a"
;;

let read_error_text : Store.read_error -> string = function
  | Read_failed { detail; _ } -> "read failed: " ^ detail
  | Tail_undecodable { offset; rows_end; reason = Not_json } ->
    Printf.sprintf "tail at %d to %d is not JSON" offset rows_end
  | Tail_undecodable { offset; rows_end = (_ : int); reason = Malformed error } ->
    Printf.sprintf "tail at %d: %s" offset
      (Masc.Keeper_memory_os_types.wire_error_to_string error)
  | Moved_while_reading -> "moved while reading"
;;

let append_error_text : Store.append_error -> string = function
  | End_moved { expected; actual } -> Printf.sprintf "end moved from %d to %d" expected actual
  | Directory_unavailable { detail; _ } -> "directory unavailable: " ^ detail
  | Write_failed { detail; _ } -> "write failed: " ^ detail
;;

(* The tail as text: where to append, where the tail line starts, and which
   line it is. *)
let tail_text path =
  match Store.read_tail path with
  | Error error -> read_error_text error
  | Ok Nothing_written -> "nothing written"
  | Ok (Written { rows_end; last_at; last }) ->
    Printf.sprintf "end %d, tail at %d, %s" rows_end last_at
      (match last with
       | Started _ -> "started"
       | Committed { seq; _ } -> Printf.sprintf "commit %d" seq)
;;

let appended path ~at_end line =
  match Store.append ~path ~at_end line with
  | Ok appended -> appended
  | Error error -> fail (append_error_text error)
;;

let length_of line = String.length (Yojson.Safe.to_string (Codec.to_json line)) + 1

let write_raw path text =
  Out_channel.with_open_gen [ Open_wronly; Open_append; Open_creat; Open_binary ] 0o600 path
    (fun channel -> Out_channel.output_string channel text)
;;

let file_bytes path = In_channel.with_open_bin path In_channel.input_all

let test_tail_is_the_last_line () =
  let path = new_path () in
  check string "no file" "nothing written" (tail_text path);
  let first = appended path ~at_end:0 started in
  check (pair int int) "the append says where the line is and where it ends"
    (0, length_of started)
    (first.at, first.new_end);
  check string "a started log"
    (Printf.sprintf "end %d, tail at 0, started" first.new_end)
    (tail_text path);
  let second = appended path ~at_end:first.new_end (committed 1) in
  check int "the second line starts where the first ended" first.new_end second.at;
  check string "a commit"
    (Printf.sprintf "end %d, tail at %d, commit 1" second.new_end second.at)
    (tail_text path);
  let third = appended path ~at_end:second.new_end (committed 2) in
  check string "the tail is the last commit"
    (Printf.sprintf "end %d, tail at %d, commit 2" third.new_end second.new_end)
    (tail_text path);
  check string "the file is the three lines"
    (String.concat ""
       (List.map
          (fun line -> Yojson.Safe.to_string (Codec.to_json line) ^ "\n")
          [ started; committed 1; committed 2 ]))
    (file_bytes path)
;;

(* A line before the tail is not read, so one that does not decode there does
   not stop the store. *)
let test_reads_the_tail_line_only () =
  let path = new_path () in
  write_raw path "not json\n";
  let garbage = String.length "not json\n" in
  let landed = appended path ~at_end:garbage (committed 1) in
  check string "the tail is read past the line before it"
    (Printf.sprintf "end %d, tail at %d, commit 1" landed.new_end garbage)
    (tail_text path)
;;

(* A crash can leave the start of a line with no line break. It was never a
   line: the tail stops before it and the next append cuts it. *)
let test_torn_fragment () =
  let path = new_path () in
  let first = appended path ~at_end:0 started in
  write_raw path {|{"line":"committed","seq":1|};
  check string "the tail stops before the fragment"
    (Printf.sprintf "end %d, tail at 0, started" first.new_end)
    (tail_text path);
  let second = appended path ~at_end:first.new_end (committed 1) in
  check int "the append wrote from the last line break" (first.new_end + length_of (committed 1))
    second.new_end;
  check int "and the fragment is gone" second.new_end (String.length (file_bytes path));
  let only_fragment = new_path () in
  write_raw only_fragment {|{"line":"sta|};
  check string "a file that holds only a fragment" "nothing written" (tail_text only_fragment);
  let landed = appended only_fragment ~at_end:0 started in
  check int "an append at 0 cuts it" (length_of started) landed.new_end
;;

let test_tail_that_cannot_be_read () =
  let path = new_path () in
  let first = appended path ~at_end:0 started in
  write_raw path "not json\n";
  check string "a line that is not JSON"
    (Printf.sprintf "tail at %d to %d is not JSON" first.new_end
       (first.new_end + String.length "not json\n"))
    (tail_text path);
  let other = new_path () in
  let first = appended other ~at_end:0 started in
  write_raw other "{\"line\":\"finished\"}\n";
  check string "a line of an unknown kind"
    (Printf.sprintf "tail at %d: %s" first.new_end
       (Masc.Keeper_memory_os_types.wire_error_to_string
          { path = [ Wire_field "line" ]; reason = Unknown_token "finished" }))
    (tail_text other)
;;

let test_stale_end_writes_nothing () =
  let path = new_path () in
  let first = appended path ~at_end:0 started in
  let second = appended path ~at_end:first.new_end (committed 1) in
  let before = file_bytes path in
  (match Store.append ~path ~at_end:first.new_end (committed 2) with
   | Error (End_moved { expected; actual }) ->
     check (pair int int) "the append names both ends" (first.new_end, second.new_end)
       (expected, actual)
   | Error other -> failf "expected End_moved, got %s" (append_error_text other)
   | Ok (_ : Store.appended) -> fail "an append at a stale end was written");
  check string "the file is as it was" before (file_bytes path)
;;

(* The file was replaced by one of the same length that ends in a fragment.
   The end that was read is its length, yet no line ends there. *)
let test_replaced_by_a_file_that_ends_in_a_fragment () =
  let path = new_path () in
  let first = appended path ~at_end:0 started in
  let replacement = String.make first.new_end 'x' in
  Out_channel.with_open_bin path (fun channel -> Out_channel.output_string channel replacement);
  (match Store.append ~path ~at_end:first.new_end (committed 1) with
   | Error (End_moved { expected; actual }) ->
     check (pair int int) "the caller is told the end is not the end" (first.new_end, first.new_end)
       (expected, actual)
   | Error other -> failf "expected End_moved, got %s" (append_error_text other)
   | Ok (_ : Store.appended) -> fail "an append after a fragment that was counted as lines");
  check string "the file is as it was" replacement (file_bytes path)
;;

(* Every line of the file as text: where it starts and which line it is. *)
let scan_text path =
  match
    Store.fold path ~init:[] ~f:(fun seen ({ at; line } : Store.scanned) ->
      Printf.sprintf "%d: %s" at
        (match line with
         | Ok (Started _) -> "started"
         | Ok (Committed { seq; _ }) -> Printf.sprintf "commit %d" seq
         | Error Not_json -> "not JSON"
         | Error (Malformed (_ : Masc.Keeper_memory_os_types.wire_error)) -> "malformed")
      :: seen)
  with
  | Ok seen -> List.rev seen
  | Error error -> [ Masc.Private_jsonl_scan.error_to_string error ]
;;

let test_every_line_from_the_first () =
  let path = new_path () in
  check (list string) "no file is no line" [] (scan_text path);
  let first = appended path ~at_end:0 started in
  let second = appended path ~at_end:first.new_end (committed 1) in
  write_raw path "not json\n";
  let after_garbage = second.new_end + String.length "not json\n" in
  let (_ : Store.appended) = appended path ~at_end:after_garbage (committed 2) in
  write_raw path {|{"line":"committed","seq":3|};
  check (list string)
    "each line with where it starts; one that does not decode is given as such; a fragment is \
     not a line"
    [ "0: started"
    ; Printf.sprintf "%d: commit 1" first.new_end
    ; Printf.sprintf "%d: not JSON" second.new_end
    ; Printf.sprintf "%d: commit 2" after_garbage
    ]
    (scan_text path)
;;

(* More lines than one locked read takes. *)
let test_scan_goes_on_past_one_read () =
  let path = new_path () in
  let lines = 70 in
  let rec append_from seq at_end =
    if seq <= lines then append_from (seq + 1) (appended path ~at_end (committed seq)).new_end
  in
  append_from 1 (appended path ~at_end:0 started).new_end;
  let seen = scan_text path in
  check int "every line is seen once" (lines + 1) (List.length seen);
  check string "the first" "0: started" (List.hd seen);
  let last_at =
    List.fold_left
      (fun total seq -> total + length_of (committed seq))
      (length_of started)
      (List.init (lines - 1) (fun before -> before + 1))
  in
  check string "the last" (Printf.sprintf "%d: commit %d" last_at lines) (List.nth seen lines)
;;

let test_path () =
  check string "beside the snapshot" "/keepers/keeper-a.memory-log.jsonl"
    (Store.path_for_keepers_dir ~keepers_dir:"/keepers" ~keeper_id:"keeper-a")
;;

let () =
  run "librarian_log_store"
    [ ( "tail"
      , [ test_case "the last line" `Quick test_tail_is_the_last_line
        ; test_case "reads the tail line only" `Quick test_reads_the_tail_line_only
        ; test_case "a torn fragment" `Quick test_torn_fragment
        ; test_case "a tail that cannot be read" `Quick test_tail_that_cannot_be_read
        ] )
    ; ( "append"
      , [ test_case "a stale end writes nothing" `Quick test_stale_end_writes_nothing
        ; test_case "a file replaced by one that ends in a fragment" `Quick
            test_replaced_by_a_file_that_ends_in_a_fragment
        ] )
    ; ( "scan"
      , [ test_case "every line from the first" `Quick test_every_line_from_the_first
        ; test_case "goes on past one read" `Quick test_scan_goes_on_past_one_read
        ] )
    ; "path", [ test_case "beside the snapshot" `Quick test_path ]
    ]
;;
