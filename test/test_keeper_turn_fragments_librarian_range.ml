(** Tests for {!Masc.Keeper_turn_fragments} and the official-client rows of
    {!Masc.Keeper_librarian_range} (RFC librarian-lifecycle §10-3): what an
    official-client turn left in its trace's history files is read back by
    the turn's [turn_ref]; a line the decoder refuses is a typed stop and not
    an untagged line; and the official-turn end lines of the boundary log are
    selected by their line number, beyond a cursor. *)

open Alcotest

module Range = Masc.Keeper_librarian_range
module Boundaries = Masc.Keeper_turn_boundaries
module Official = Masc.Keeper_librarian_official_progress
module Types = Agent_core.Types

let trace_id = "trace"

let message ~role text : Types.message =
  { origin = Llm_provider.Types.Conversation;  role; content = [ Types.Text text ]; name = None; tool_call_id = None; metadata = [] }
;;

(* {1 Official-turn end lines of the boundary log} *)

let ended ?(trace = trace_id) ~line ~turn position : int * (Boundaries.record, Boundaries.read_error) result =
  ( line
  , Ok
      { Boundaries.recorded_at = Float.of_int line
      ; event =
          Boundaries.Turn_ended
            { task_context = Masc.Keeper_turn_task_context.No_task; turn_ref = Ids.Turn_ref.make ~trace_id:trace ~absolute_turn:turn
            ; history_at_start = Boundaries.Continued_history
            ; position
            }
      } )
;;

let official = Boundaries.No_atom_history
let atoms n = Boundaries.Atom_history { end_atom = n; last_atom_digest = "d" }
let refused line = line, Error (Boundaries.Not_json "junk")
let torn line = line, Error Boundaries.Incomplete_line

let lines_of selection =
  match selection with
  | Range.Official_read lines -> List.map (fun { Range.line; _ } -> line) lines
  | Range.Nothing_official -> []
  | Range.Official_stop { line; _ } -> [ -line ]
;;

(* Only [No_atom_history] end lines are official turns; the cursor is a line
   number and lines at or before it are passed; a narrowed round takes the
   oldest; a trace that ended still counts. *)
let test_official_lines_are_selected_beyond_the_cursor () =
  let log =
    [ ended ~line:1 ~turn:1 official
    ; ended ~line:2 ~turn:2 (atoms 1)
    ; ended ~line:3 ~turn:3 official
    ; ended ~trace:"older" ~line:4 ~turn:9 official
    ; ended ~line:5 ~turn:4 Boundaries.Stale_noop
    ; torn 6
    ]
  in
  check (list int) "no cursor: every official line" [ 1; 3; 4 ]
    (lines_of (Range.select_official ~lines:log ~cursor:None Range.All_unread));
  check (list int) "a cursor passes lines at or before it" [ 3; 4 ]
    (lines_of
       (Range.select_official ~lines:log ~cursor:(Some { Official.boundary_line = 1 })
          Range.All_unread));
  check (list int) "a narrowed round takes the oldest" [ 1 ]
    (lines_of (Range.select_official ~lines:log ~cursor:None Range.To_first_cut_point));
  check (list int) "past the last one there is nothing" []
    (lines_of
       (Range.select_official ~lines:log ~cursor:(Some { Official.boundary_line = 4 })
          Range.All_unread));
  check bool "the cheap check agrees" false
    (Range.may_have_unread_official ~lines:log ~cursor:(Some { Official.boundary_line = 4 }))
;;

(* A refused line beyond the cursor stops at that line: it may be an official
   turn's end line. The readable official turns before it are read first; one
   at or before the cursor was already passed and stops nothing. *)
let test_a_refused_line_beyond_the_cursor_stops () =
  let log = [ ended ~line:1 ~turn:1 official; refused 2; ended ~line:3 ~turn:3 official ] in
  check (list int) "no cursor: the turn before the refused line is read" [ 1 ]
    (lines_of (Range.select_official ~lines:log ~cursor:None Range.All_unread));
  check (list int) "a narrowed round takes the same turn" [ 1 ]
    (lines_of (Range.select_official ~lines:log ~cursor:None Range.To_first_cut_point));
  check (list int) "at the turn before it: stop at the refused line" [ -2 ]
    (lines_of
       (Range.select_official ~lines:log ~cursor:(Some { Official.boundary_line = 1 })
          Range.All_unread));
  check (list int) "at or before the cursor: read on" [ 3 ]
    (lines_of
       (Range.select_official ~lines:log ~cursor:(Some { Official.boundary_line = 2 })
          Range.All_unread));
  check (list int) "a refused first line leaves nothing to read before it" [ -1 ]
    (lines_of
       (Range.select_official
          ~lines:[ refused 1; ended ~line:2 ~turn:2 official ]
          ~cursor:None
          Range.All_unread));
  check (list int) "lines that read as another kind of turn do not count" [ -3 ]
    (lines_of
       (Range.select_official
          ~lines:[ ended ~line:1 ~turn:1 (atoms 1); ended ~line:2 ~turn:2 Boundaries.Stale_noop; refused 3 ]
          ~cursor:None
          Range.All_unread));
  check bool "the cheap check reports the stop" true
    (Range.may_have_unread_official ~lines:log ~cursor:None)
;;

(* The cut points inside a selected range, with the line each one sits on. *)
let test_cut_lines_name_every_turn_inside_the_range () =
  let messages =
    [ message ~role:Types.User "one"; message ~role:Types.User "two"; message ~role:Types.User "three" ]
  in
  let digest_at = Runtime_model_input_tail_window.atom_opening_digest messages in
  let digest n = Option.get (digest_at (n - 1)) in
  let at n = Boundaries.Atom_history { end_atom = n; last_atom_digest = digest n } in
  let log =
    [ ended ~line:1 ~turn:1 (at 1)
    ; ended ~line:2 ~turn:2 official
    ; ended ~line:3 ~turn:3 (at 2)
    ; ended ~line:4 ~turn:4 (at 3)
    ]
  in
  let range =
    { Range.history_start_boundary_line = 1
    ; start_atom = 1
    ; end_atom = 3
    ; last_atom_digest = digest 3
    }
  in
  check (list (pair int int)) "lines 3 and 4 cut the range at atoms 2 and 3"
    [ 3, 2; 4, 3 ]
    (List.map
       (fun { Range.cut_line; cut_end_atom; _ } -> cut_line, cut_end_atom)
       (Range.cut_lines ~trace_id ~lines:log ~messages range))
;;

let () =
  run
    "keeper_turn_fragments_librarian_range"
    [ ( "official lines"
      , [ test_case "official lines are selected beyond the cursor" `Quick
            test_official_lines_are_selected_beyond_the_cursor
        ; test_case "a refused line beyond the cursor stops" `Quick
            test_a_refused_line_beyond_the_cursor_stops
        ; test_case "cut lines name every turn inside the range" `Quick
            test_cut_lines_name_every_turn_inside_the_range
        ] )
    ]
;;
