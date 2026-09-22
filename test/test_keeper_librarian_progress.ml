(** Tests for {!Masc.Keeper_librarian_progress} (RFC librarian-lifecycle §4.6):
    the file that says how far a keeper's Librarian has read. *)

open Alcotest

module Progress = Masc.Keeper_librarian_progress
module Wire = Masc.Keeper_memory_os_types

let keeper_id = "keeper"

let with_temp_keepers f =
  let path = Filename.temp_dir "librarian-progress-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree path) (fun () -> f path)
;;

let progress
      ?(trace_id = "trace")
      ?(end_atom = 120)
      ?(last_atom_digest = "digest")
      ?(boundary_lines_seen = 7)
      ()
  : Progress.t
  =
  { Progress.position = { Progress.trace_id; end_atom; last_atom_digest }
  ; boundary_lines_seen
  }
;;

(* {1 Codec} *)

let test_round_trip () =
  let written = progress () in
  match Progress.of_json (Progress.to_json written) with
  | Ok read_back -> check bool "reads back what was written" true (read_back = written)
  | Error error -> failf "refused its own value: %s" (Wire.wire_error_to_string error)
;;

(* The text is what a rolled-back or rolled-forward build has to read, so it is
   pinned as text and not only through the round trip. *)
let test_the_text_on_disk () =
  check string "wire text"
    {|{"trace_id":"trace","end_atom":120,"last_atom_digest":"digest","boundary_lines_seen":7}|}
    (Yojson.Safe.to_string (Progress.to_json (progress ())))
;;

let fields_of written =
  match Progress.to_json written with
  | `Assoc fields -> fields
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    fail "the progress value is not an object"
;;

let without name fields = List.filter (fun (key, _) -> not (String.equal key name)) fields

let replacing name value fields =
  List.map (fun (key, old) -> if String.equal key name then key, value else key, old) fields
;;

(* A rejection is compared by where and why, so a value refused for another
   defect than the one the case plants does not pass. *)
let check_rejection label ~path ~reason json =
  match Progress.of_json json with
  | Ok _ -> failf "%s: accepted" label
  | Error error ->
    check string label
      (Wire.wire_error_to_string { Wire.path; reason })
      (Wire.wire_error_to_string error)
;;

let test_decode_refuses_another_field_set () =
  check_rejection "a position without its digest"
    ~path:[]
    ~reason:
      (Wire.Field_set_mismatch { missing = [ "last_atom_digest" ]; unexpected = [] })
    (`Assoc (without "last_atom_digest" (fields_of (progress ()))));
  check_rejection "a field this build does not know"
    ~path:[]
    ~reason:(Wire.Field_set_mismatch { missing = []; unexpected = [ "read_at" ] })
    (`Assoc (fields_of (progress ()) @ [ "read_at", `Float 200.0 ]));
  check_rejection "not an object" ~path:[] ~reason:Wire.Expected_object (`List [])
;;

let test_decode_refuses_values_no_round_writes () =
  check_rejection "a blank trace"
    ~path:[ Wire.Wire_field "trace_id" ]
    ~reason:Wire.Blank_string
    (Progress.to_json (progress ~trace_id:" " ()));
  check_rejection "a position before the first atom"
    ~path:[ Wire.Wire_field "end_atom" ]
    ~reason:Wire.Not_positive
    (Progress.to_json (progress ~end_atom:0 ()));
  check_rejection "a blank digest"
    ~path:[ Wire.Wire_field "last_atom_digest" ]
    ~reason:Wire.Blank_string
    (Progress.to_json (progress ~last_atom_digest:"" ()));
  check_rejection "a negative line count"
    ~path:[ Wire.Wire_field "boundary_lines_seen" ]
    ~reason:Wire.Negative
    (Progress.to_json (progress ~boundary_lines_seen:(-1) ()));
  check_rejection "an atom count that is not a number"
    ~path:[ Wire.Wire_field "end_atom" ]
    ~reason:Wire.Expected_int
    (`Assoc (replacing "end_atom" (`String "120") (fields_of (progress ()))))
;;

(* {1 Store} *)

let read ~keepers_dir = Progress.read ~keepers_dir ~keeper_id

let write ~keepers_dir value =
  match Progress.write ~keepers_dir ~keeper_id value with
  | Ok () -> ()
  | Error error -> failf "write: %s" (Progress.write_error_to_string error)
;;

let plant ~keepers_dir content =
  Fs_compat.mkdir_p (Filename.dirname
    (Progress.path_for_keepers_dir ~keepers_dir ~keeper_id));
  Out_channel.with_open_bin
    (Progress.path_for_keepers_dir ~keepers_dir ~keeper_id)
    (fun channel -> Out_channel.output_string channel content)
;;

(* No file is the one state that means "not read yet". *)
let test_no_file_is_not_read_yet () =
  with_temp_keepers
  @@ fun keepers_dir ->
  match read ~keepers_dir with
  | Ok None -> ()
  | Ok (Some _) -> fail "read a position from a directory with no file"
  | Error error -> failf "no file is not an error: %s" (Progress.read_error_to_string error)
;;

let test_a_written_position_reads_back_and_is_replaced () =
  with_temp_keepers
  @@ fun keepers_dir ->
  write ~keepers_dir (progress ());
  (match read ~keepers_dir with
   | Ok (Some read_back) -> check bool "first value" true (read_back = progress ())
   | Ok None -> fail "the written file was not found"
   | Error error -> fail (Progress.read_error_to_string error));
  let moved = progress ~end_atom:128 ~last_atom_digest:"later" ~boundary_lines_seen:9 () in
  write ~keepers_dir moved;
  (match read ~keepers_dir with
   | Ok (Some read_back) -> check bool "replaced value" true (read_back = moved)
   | Ok None -> fail "the replaced file was not found"
   | Error error -> fail (Progress.read_error_to_string error));
  check string "file name"
    "librarian-progress.json"
    (Filename.basename (Progress.path_for_keepers_dir ~keepers_dir ~keeper_id))
;;

let test_a_value_no_reader_decodes_is_not_written () =
  with_temp_keepers
  @@ fun keepers_dir ->
  (match Progress.write ~keepers_dir ~keeper_id (progress ~end_atom:0 ()) with
   | Error (Progress.Invalid_progress _) -> ()
   | Error (Progress.Write_failed _ as error) ->
     failf "refused for another reason: %s" (Progress.write_error_to_string error)
   | Ok () -> fail "wrote a position no reader decodes");
  match read ~keepers_dir with
  | Ok None -> ()
  | Ok (Some _) | Error _ -> fail "the refused value left a file"
;;

(* A file that cannot be decoded must not read as "not read yet": that would
   make the whole history look unread. *)
let test_an_undecodable_file_is_an_error_not_an_empty_state () =
  with_temp_keepers
  @@ fun keepers_dir ->
  plant ~keepers_dir "{";
  (match read ~keepers_dir with
   | Error (Progress.Not_json _) -> ()
   | Error ((Progress.Unreadable _ | Progress.Malformed _) as error) ->
     failf "refused for another reason: %s" (Progress.read_error_to_string error)
   | Ok _ -> fail "read a file that is not JSON");
  plant ~keepers_dir {|{"trace_id":"trace"}|};
  match read ~keepers_dir with
  | Error (Progress.Malformed _) -> ()
  | Error ((Progress.Unreadable _ | Progress.Not_json _) as error) ->
    failf "refused for another reason: %s" (Progress.read_error_to_string error)
  | Ok _ -> fail "read a file without its fields"
;;

(* A purge has to take the position together with the turn boundary log it is
   a position in. *)
let test_purge_plan_removes_the_progress_file () =
  let module Shutdown = Masc.Keeper_shutdown_types in
  let context = { Shutdown.requested_name = keeper_id } in
  let plan = Shutdown.dashboard_purge_artifact_plan ~keeper_name:keeper_id context in
  let has artifact = List.exists (fun entry -> entry = artifact) plan in
  check bool "plan removes the progress file" true
    (has Shutdown.Keeper_librarian_progress_artifact);
  check bool "plan removes the committed-range receipt" true
    (has Shutdown.Keeper_librarian_range_receipt_artifact);
  check bool "plan removes an interrupted retraction plan" true
    (has Shutdown.Keeper_memory_retraction_plan_artifact);
  check bool "plan removes the official-turn position" true
    (has Shutdown.Keeper_librarian_official_progress_artifact);
  check bool "and the log it is a position in" true
    (has Shutdown.Keeper_turn_boundaries_artifact)
;;

let () =
  run
    "keeper_librarian_progress"
    [ ( "codec"
      , [ test_case "round trip" `Quick test_round_trip
        ; test_case "the text on disk" `Quick test_the_text_on_disk
        ; test_case "refuses another field set" `Quick
            test_decode_refuses_another_field_set
        ; test_case "refuses values no round writes" `Quick
            test_decode_refuses_values_no_round_writes
        ] )
    ; ( "store"
      , [ test_case "no file is not read yet" `Quick test_no_file_is_not_read_yet
        ; test_case "a written position reads back and is replaced" `Quick
            test_a_written_position_reads_back_and_is_replaced
        ; test_case "a value no reader decodes is not written" `Quick
            test_a_value_no_reader_decodes_is_not_written
        ; test_case "an undecodable file is an error, not an empty state" `Quick
            test_an_undecodable_file_is_an_error_not_an_empty_state
        ; test_case "the purge plan removes the progress file" `Quick
            test_purge_plan_removes_the_progress_file
        ] )
    ]
;;
