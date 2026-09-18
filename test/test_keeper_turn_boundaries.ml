(** Tests for {!Masc.Keeper_turn_boundaries} (RFC librarian-is-the-brain
    §4.3): the line a finished keeper turn leaves to say where its saved atom
    history ended. *)

open Alcotest

module Boundaries = Masc.Keeper_turn_boundaries
module Wire = Masc.Keeper_memory_os_types
module Window = Runtime_model_input_tail_window
module Types = Agent_core.Types

let keeper_id = "keeper"

let with_temp_keepers f =
  let path = Filename.temp_file "turn-boundaries-" ".dir" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree path)
    (fun () -> f path)
;;

let message ~role text : Types.message =
  { role
  ; content = [ Types.Text text ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }
;;

let record ?(turn = 1) position : Boundaries.record =
  { Boundaries.recorded_at = 200.0
  ; session_id = "trace"
  ; turn_ref = Ids.Turn_ref.make ~trace_id:"trace" ~absolute_turn:turn
  ; position
  }
;;

let atom_history = Boundaries.Atom_history { end_atom = 2; last_atom_digest = "digest" }

let every_position =
  [ atom_history; Boundaries.Empty_atom_history; Boundaries.No_atom_history ]
;;

let print_record fmt written =
  Format.pp_print_string fmt (Yojson.Safe.to_string (Boundaries.record_to_json written))
;;

let record_equal (left : Boundaries.record) (right : Boundaries.record) =
  Float.equal left.recorded_at right.recorded_at
  && String.equal left.session_id right.session_id
  && Ids.Turn_ref.equal left.turn_ref right.turn_ref
  && left.position = right.position
;;

let record_t : Boundaries.record testable = testable print_record record_equal

let position_t : Boundaries.position testable =
  testable (fun fmt position -> print_record fmt (record position)) ( = )
;;

let test_every_position_kind_round_trips () =
  List.iter
    (fun position ->
       let written = record position in
       match Boundaries.record_of_json (Boundaries.record_to_json written) with
       | Ok decoded -> check record_t "round trip" written decoded
       | Error error -> failf "round trip rejected: %s" (Wire.wire_error_to_string error))
    every_position
;;

let fields_of label (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields -> fields
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    failf "%s is not an object" label
;;

let without name fields = List.filter (fun (key, _) -> not (String.equal key name)) fields

let replacing name value fields =
  List.map (fun (key, old) -> if String.equal key name then key, value else key, old) fields
;;

(* The line for [written] with its fields passed through [edit]. *)
let with_fields edit written : Yojson.Safe.t =
  `Assoc (edit (fields_of "record" (Boundaries.record_to_json written)))
;;

(* The line for [written] with the fields of its position passed through
   [edit]. *)
let with_position edit written : Yojson.Safe.t =
  with_fields
    (List.map (fun (key, value) ->
       if String.equal key "position"
       then key, `Assoc (edit (fields_of "position" value))
       else key, value))
    written
;;

(* A rejection is compared by where and why, so a line refused for another
   defect than the one the case plants does not pass. *)
let check_rejection label ~path ~reason json =
  match Boundaries.record_of_json json with
  | Ok _ -> failf "%s: accepted" label
  | Error error ->
    check string label
      (Wire.wire_error_to_string { Wire.path; reason })
      (Wire.wire_error_to_string error)
;;

let test_decode_refuses_what_its_kind_does_not_carry () =
  check_rejection "a kind this build does not know"
    ~path:[ Wire.Wire_field "position"; Wire.Wire_field "kind" ]
    ~reason:(Wire.Unknown_token "somewhere_else")
    (with_position
       (replacing "kind" (`String "somewhere_else"))
       (record Boundaries.No_atom_history));
  check_rejection "an atom history without its digest"
    ~path:[ Wire.Wire_field "position" ]
    ~reason:
      (Wire.Field_set_mismatch { missing = [ "last_atom_digest" ]; unexpected = [] })
    (with_position (without "last_atom_digest") (record atom_history));
  check_rejection "an empty history that names an end"
    ~path:[ Wire.Wire_field "position" ]
    ~reason:(Wire.Field_set_mismatch { missing = []; unexpected = [ "end_atom" ] })
    (with_position
       (fun fields -> fields @ [ "end_atom", `Int 2 ])
       (record Boundaries.Empty_atom_history));
  check_rejection "a line without its session"
    ~path:[]
    ~reason:(Wire.Field_set_mismatch { missing = [ "session_id" ]; unexpected = [] })
    (with_fields (without "session_id") (record atom_history));
  check_rejection "a line with a field no reader knows"
    ~path:[]
    ~reason:(Wire.Field_set_mismatch { missing = []; unexpected = [ "extra" ] })
    (with_fields (fun fields -> fields @ [ "extra", `Null ]) (record atom_history))
;;

let test_decode_refuses_values_no_turn_writes () =
  check_rejection "an atom history that ends before its first atom"
    ~path:[ Wire.Wire_field "position"; Wire.Wire_field "end_atom" ]
    ~reason:Wire.Not_positive
    (with_position (replacing "end_atom" (`Int 0)) (record atom_history));
  check_rejection "a blank digest"
    ~path:[ Wire.Wire_field "position"; Wire.Wire_field "last_atom_digest" ]
    ~reason:Wire.Blank_string
    (with_position (replacing "last_atom_digest" (`String " ")) (record atom_history));
  check_rejection "a blank session"
    ~path:[ Wire.Wire_field "session_id" ]
    ~reason:Wire.Blank_string
    (with_fields (replacing "session_id" (`String " ")) (record atom_history));
  check_rejection "a turn reference with no turn number"
    ~path:[ Wire.Wire_field "turn_ref" ]
    ~reason:(Wire.Not_a_turn_ref "no-turn-number")
    (with_fields (replacing "turn_ref" (`String "no-turn-number")) (record atom_history));
  check_rejection "a time that is not finite"
    ~path:[ Wire.Wire_field "recorded_at" ]
    ~reason:Wire.Not_finite
    (with_fields (replacing "recorded_at" (`Float Float.infinity)) (record atom_history))
;;

let position_of label messages =
  match Boundaries.position_of_messages messages with
  | Ok position -> position
  | Error detail -> failf "%s: %s" label detail
;;

(* The position speaks the window's atom vocabulary, so the expected end is what
   the window itself reports for the same messages: its atom count and its
   opening digest of the last atom. *)
let test_position_agrees_with_the_window () =
  check position_t "no message is no atom" Boundaries.Empty_atom_history
    (position_of "empty history" []);
  check position_t "a pinned message is not an atom" Boundaries.Empty_atom_history
    (position_of "system only" [ message ~role:Types.System "system" ]);
  let history =
    [ message ~role:Types.User "question"
    ; message ~role:Types.Assistant "calling a tool"
    ; message ~role:Types.Tool "tool result"
    ]
  in
  let _labelled, atom_count = Window.annotate history in
  check int "the tool result joins the atom its assistant opened" 2 atom_count;
  match Window.atom_opening_digest history (atom_count - 1) with
  | None -> fail "the window has no opening digest for the last atom"
  | Some last_atom_digest ->
    check position_t "the end is the window's atom count and last opening digest"
      (Boundaries.Atom_history { end_atom = atom_count; last_atom_digest })
      (position_of "user, assistant and tool" history)
;;

let read_lines ~keepers_dir =
  match Boundaries.read ~keepers_dir ~keeper_id with
  | Error message -> failf "turn boundary store: %s" message
  | Ok lines ->
    List.map
      (fun (line, result) ->
         match result with
         | Ok written -> line, written
         | Error error ->
           failf "turn boundary line %d: %s" line (Boundaries.read_error_to_string error))
      lines
;;

let test_appended_lines_read_back_in_order () =
  with_temp_keepers @@ fun keepers_dir ->
  check int "a keeper with no finished turn has no line" 0
    (List.length (read_lines ~keepers_dir));
  let written =
    List.mapi (fun index position -> record ~turn:(index + 1) position) every_position
  in
  List.iter
    (fun finished ->
       match Boundaries.append ~keepers_dir ~keeper_id finished with
       | Ok () -> ()
       | Error error -> failf "append: %s" (Boundaries.append_error_to_string error))
    written;
  check (list (pair int record_t)) "one numbered line per turn, in the order they finished"
    (List.mapi (fun index finished -> index + 1, finished) written)
    (read_lines ~keepers_dir);
  check string "the file the RFC names" "keeper.turn-boundaries.jsonl"
    (Filename.basename (Boundaries.path_for_keepers_dir ~keepers_dir ~keeper_id))
;;

(* [Ids.Turn_ref.make] takes an empty trace id and [Ids.Turn_ref.of_string]
   refuses it, so writing such a line would leave a row no reader decodes. *)
let test_a_line_no_reader_decodes_is_not_written () =
  with_temp_keepers @@ fun keepers_dir ->
  let unreadable =
    { (record Boundaries.No_atom_history) with
      Boundaries.turn_ref = Ids.Turn_ref.make ~trace_id:"" ~absolute_turn:1
    }
  in
  (match Boundaries.append ~keepers_dir ~keeper_id unreadable with
   | Error (Boundaries.Invalid_record _) -> ()
   | Error (Boundaries.Write_failed _ as error) ->
     failf "refused for the wrong reason: %s" (Boundaries.append_error_to_string error)
   | Ok () -> fail "a turn reference no reader can parse was written");
  check int "nothing was written" 0 (List.length (read_lines ~keepers_dir))
;;

(* The log lives in the config keepers directory, outside the runtime
   directory the purge removes: without a plan entry a purged keeper leaves it
   to a later keeper with the same name. *)
let test_purge_plan_removes_the_turn_boundary_log () =
  let module Shutdown = Masc.Keeper_shutdown_types in
  let context = { Shutdown.requested_name = keeper_id } in
  let plan = Shutdown.dashboard_purge_artifact_plan ~keeper_name:keeper_id context in
  check bool "plan removes the turn boundary log" true
    (List.exists (fun entry -> entry = Shutdown.Keeper_turn_boundaries_artifact) plan)
;;

let () =
  run
    "keeper_turn_boundaries"
    [ ( "codec"
      , [ test_case "every position kind round trips" `Quick
            test_every_position_kind_round_trips
        ; test_case "refuses what its kind does not carry" `Quick
            test_decode_refuses_what_its_kind_does_not_carry
        ; test_case "refuses values no turn writes" `Quick
            test_decode_refuses_values_no_turn_writes
        ] )
    ; ( "position"
      , [ test_case "agrees with the window" `Quick test_position_agrees_with_the_window ] )
    ; ( "store"
      , [ test_case "appended lines read back in order" `Quick
            test_appended_lines_read_back_in_order
        ; test_case "a line no reader decodes is not written" `Quick
            test_a_line_no_reader_decodes_is_not_written
        ; test_case "the purge plan removes the log" `Quick
            test_purge_plan_removes_the_turn_boundary_log
        ] )
    ]
;;
