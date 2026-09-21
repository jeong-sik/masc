(** Tests for {!Masc.Keeper_window_position} (RFC
    keeper-context-window-in-tokens §7 (라)): the file that says where a
    keeper's next request starts and what it was in the middle of. *)

open Alcotest

module Window = Masc.Keeper_window_position
module Progress = Masc.Keeper_librarian_progress
module Wire = Masc.Keeper_memory_os_types

let keeper_id = "keeper"

let with_temp_keepers f =
  let path = Filename.temp_dir "window-position-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree path) (fun () -> f path)
;;

let window
      ?(trace_id = "trace")
      ?(end_atom = 120)
      ?(last_atom_digest = "digest-119")
      ?(in_progress = Window.Stated "reading the release notes")
      ?(recorded_at = 1_700_000_000.0)
      ()
  : Window.t
  =
  { Window.position = { Progress.trace_id; end_atom; last_atom_digest }
  ; in_progress
  ; recorded_at
  }
;;

(* {1 Codec} *)

let test_round_trip () =
  List.iter
    (fun in_progress ->
       let written = window ~in_progress () in
       match Window.of_json (Window.to_json written) with
       | Ok read_back -> check bool "reads back what was written" true (read_back = written)
       | Error error -> failf "refused its own value: %s" (Wire.wire_error_to_string error))
    [ Window.Absent_at_baseline; Window.Nothing_in_progress; Window.Stated "still writing" ]
;;

(* The text is what a rolled-back or rolled-forward build reads, so it is
   pinned as text and not only through the round trip. *)
let test_the_text_on_disk () =
  check string "the shape on disk"
    {|{"trace_id":"trace","end_atom":120,"last_atom_digest":"digest-119","in_progress":{"kind":"stated","text":"reading the release notes"},"recorded_at":1700000000.0}|}
    (Yojson.Safe.to_string (Window.to_json (window ())))
;;

let refused label json =
  match Window.of_json json with
  | Error _ -> ()
  | Ok _ -> failf "accepted %s" label
;;

let field name value json =
  match json with
  | `Assoc assoc ->
    `Assoc
      (List.map (fun (key, current) -> key, if String.equal key name then value else current) assoc)
  | json -> json
;;

let test_rejections () =
  let valid = Window.to_json (window ()) in
  refused "an unknown field" (match valid with
    | `Assoc assoc -> `Assoc (("carried_atoms", `Int 3) :: assoc)
    | json -> json);
  refused "a missing field" (match valid with
    | `Assoc assoc -> `Assoc (List.remove_assoc "recorded_at" assoc)
    | json -> json);
  refused "a blank trace" (field "trace_id" (`String "  ") valid);
  refused "a position before the first atom" (field "end_atom" (`Int 0) valid);
  refused "a blank digest" (field "last_atom_digest" (`String "") valid);
  refused "a time that is not a number" (field "recorded_at" (`String "now") valid);
  refused "a time before zero" (field "recorded_at" (`Float (-1.)) valid);
  refused "an in-progress kind this build does not know"
    (field "in_progress" (`Assoc [ "kind", `String "resting" ]) valid);
  refused "a stated text that says nothing"
    (field "in_progress" (`Assoc [ "kind", `String "stated"; "text", `String " " ]) valid);
  refused "a stated entry with no text"
    (field "in_progress" (`Assoc [ "kind", `String "stated" ]) valid);
  refused "a bare kind carrying a text"
    (field
       "in_progress"
       (`Assoc [ "kind", `String "nothing_in_progress"; "text", `String "x" ])
       valid)
;;

(* {1 The file} *)

let test_write_then_read () =
  with_temp_keepers
  @@ fun keepers_dir ->
  check bool "nothing absorbed yet" true
    (match Window.read ~keepers_dir ~keeper_id with
     | Ok None -> true
     | Ok (Some _) | Error _ -> false);
  let written = window () in
  (match Window.write ~keepers_dir ~keeper_id written with
   | Ok () -> ()
   | Error error -> fail (Window.write_error_to_string error));
  match Window.read ~keepers_dir ~keeper_id with
  | Ok (Some read_back) -> check bool "the same value" true (read_back = written)
  | Ok None -> fail "the file that was just written is absent"
  | Error error -> fail (Window.read_error_to_string error)
;;

(* A file that exists and cannot be read is an error, never "nothing
   absorbed": that reading would send the whole history without saying so. *)
let test_a_file_that_cannot_be_read_is_an_error () =
  with_temp_keepers
  @@ fun keepers_dir ->
  let path = Window.path_for_keepers_dir ~keepers_dir ~keeper_id in
  Fs_compat.mkdir_p (Filename.dirname path);
  Fs_compat.save_file path "{ not json";
  check bool "not json" true
    (match Window.read ~keepers_dir ~keeper_id with
     | Error (Window.Not_json _) -> true
     | Error _ | Ok _ -> false);
  Fs_compat.save_file path {|{"trace_id":"trace"}|};
  check bool "decoded and refused" true
    (match Window.read ~keepers_dir ~keeper_id with
     | Error (Window.Malformed _) -> true
     | Error _ | Ok _ -> false)
;;

let test_write_refuses_what_read_would_refuse () =
  with_temp_keepers
  @@ fun keepers_dir ->
  match Window.write ~keepers_dir ~keeper_id (window ~in_progress:(Window.Stated " ") ()) with
  | Error (Window.Invalid_position _) ->
    check bool "and wrote no file" false
      (Sys.file_exists (Window.path_for_keepers_dir ~keepers_dir ~keeper_id))
  | Error error -> failf "refused for the wrong reason: %s" (Window.write_error_to_string error)
  | Ok () -> fail "wrote a value it would not read back"
;;

(* {1 What it says about the history a turn is about to send} *)

let digests = [ 0, "digest-0"; 118, "digest-118"; 119, "digest-119" ]
let digest_at atom = List.assoc_opt atom digests

let view ?(trace_id = "trace") ?(atom_count = 130) stored =
  Window.view_of_history stored ~trace_id ~digest_at ~atom_count
;;

let test_a_position_in_this_history_is_absorbed () =
  match view (Some (window ())) with
  | Window.Absorbed recorded ->
    check int "the first atom a request carries" 120 recorded.Window.position.Progress.end_atom
  | Window.Empty_history | Window.Absent | Window.Outlived _ ->
    fail "a position of this history was not taken"
;;

let test_no_file_is_absent () =
  check bool "absent" true
    (match view None with
     | Window.Absent -> true
     | _ -> false)
;;

(* A history with no atom has nothing to leave out, whatever the file says. *)
let test_an_empty_history_needs_no_position () =
  check bool "empty" true
    (match view ~atom_count:0 (Some (window ())) with
     | Window.Empty_history -> true
     | _ -> false)
;;

let test_a_position_of_another_trace_is_outlived () =
  match view ~trace_id:"other" (Some (window ())) with
  | Window.Outlived { reason = Window.Other_trace stored; _ } ->
    check string "names the stored trace" "trace" stored
  | _ -> fail "a position of another trace was taken"
;;

let test_a_position_past_the_end_is_outlived () =
  match view ~atom_count:119 (Some (window ())) with
  | Window.Outlived { reason = Window.Atom_missing { end_atom; atom_count }; _ } ->
    check int "the position" 120 end_atom;
    check int "against the history" 119 atom_count
  | _ -> fail "a position past the history was taken"
;;

(* The atom is there and the message that opens the one before it is not the
   message the Librarian read: the history was rewritten under the position. *)
let test_a_rewritten_message_is_outlived () =
  match view (Some (window ~last_atom_digest:"digest-of-a-message-since-replaced" ())) with
  | Window.Outlived { reason = Window.Message_differs { end_atom; stored_digest; history_digest }; _ }
    ->
    check int "at the position" 120 end_atom;
    check string "what was read" "digest-of-a-message-since-replaced" stored_digest;
    check (option string) "what is there now" (Some "digest-119") history_digest
  | _ -> fail "a rewritten history was taken as absorbed"
;;

(* A position whose preceding atom has no opening message at all is not a
   place either; the history cannot say it is the one that was read. *)
let test_a_position_with_no_opening_message_is_outlived () =
  match view (Some (window ~end_atom:100 ~last_atom_digest:"digest-99" ())) with
  | Window.Outlived { reason = Window.Message_differs { history_digest = None; _ }; _ } -> ()
  | _ -> fail "a position with no opening message was taken"
;;

(* {1 The purge} *)

let test_purge_plan_removes_the_window_file () =
  let module Shutdown = Masc.Keeper_shutdown_types in
  let context = { Shutdown.requested_name = keeper_id } in
  let plan = Shutdown.dashboard_purge_artifact_plan ~keeper_name:keeper_id context in
  check bool "plan removes the window position" true
    (List.exists (fun entry -> entry = Shutdown.Keeper_window_position_artifact) plan)
;;

let () =
  run
    "keeper_window_position"
    [ ( "codec"
      , [ test_case "round trip" `Quick test_round_trip
        ; test_case "the text on disk" `Quick test_the_text_on_disk
        ; test_case "rejections" `Quick test_rejections
        ] )
    ; ( "file"
      , [ test_case "write then read" `Quick test_write_then_read
        ; test_case "a file that cannot be read is an error" `Quick
            test_a_file_that_cannot_be_read_is_an_error
        ; test_case "write refuses what read would refuse" `Quick
            test_write_refuses_what_read_would_refuse
        ] )
    ; ( "view"
      , [ test_case "a position in this history is absorbed" `Quick
            test_a_position_in_this_history_is_absorbed
        ; test_case "no file is absent" `Quick test_no_file_is_absent
        ; test_case "an empty history needs no position" `Quick
            test_an_empty_history_needs_no_position
        ; test_case "a position of another trace is outlived" `Quick
            test_a_position_of_another_trace_is_outlived
        ; test_case "a position past the end is outlived" `Quick
            test_a_position_past_the_end_is_outlived
        ; test_case "a rewritten message is outlived" `Quick
            test_a_rewritten_message_is_outlived
        ; test_case "a position with no opening message is outlived" `Quick
            test_a_position_with_no_opening_message_is_outlived
        ] )
    ; ( "purge"
      , [ test_case "the plan removes the window position" `Quick
            test_purge_plan_removes_the_window_file
        ] )
    ]
;;
