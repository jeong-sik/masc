(** Tests for {!Masc.Keeper_librarian_range} (RFC librarian-lifecycle §4.4 and
    the deterministic list of §9): which atoms a Librarian round reads.

    Each case builds a history, the lines its turns would have left, and a
    read position, and states the range. The cases named "model" replay the
    shortest counterexamples an exhaustive model of these rules produced when
    one rule was switched off, so that the rule cannot be lost quietly. *)

open Alcotest

module Range = Masc.Keeper_librarian_range
module Boundaries = Masc.Keeper_turn_boundaries
module Progress = Masc.Keeper_librarian_progress
module Wire = Masc.Keeper_memory_os_types
module Window = Runtime_model_input_tail_window
module Types = Agent_core.Types

let trace = "trace"

let message ~role text : Types.message =
  { role; content = [ Types.Text text ]; name = None; tool_call_id = None; metadata = [] }
;;

let user text = message ~role:Types.User text
let assistant text = message ~role:Types.Assistant text

(* [n] atoms whose text is their index under [tag], so two histories built
   with the same tag collide atom for atom, as a digest with no index and no
   time allows. *)
let history ?(tag = "m") n =
  List.init n (fun index ->
    let text = Printf.sprintf "%s%d" tag index in
    if index mod 2 = 0 then user text else assistant text)
;;

let digest_of messages atom =
  match Window.atom_opening_digest messages atom with
  | Some digest -> digest
  | None -> failf "the fixture history has no atom %d" atom
;;

(* The line a turn leaves when it ends with [messages] saved. *)
let turn_ended ?(trace_id = trace) ?(turn = 1) ~fresh messages : Boundaries.record =
  let position =
    match Boundaries.position_of_messages messages with
    | Ok position -> position
    | Error detail -> failf "fixture position: %s" detail
  in
  { Boundaries.recorded_at = 100.0
  ; event =
      Boundaries.Turn_ended
        { turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn:turn
        ; history_at_start =
            (if fresh then Boundaries.Fresh_history else Boundaries.Continued_history)
        ; position
        }
  }
;;

let restarted ?(trace_id = trace) () : Boundaries.record =
  { Boundaries.recorded_at = 100.0; event = Boundaries.History_restarted { trace_id } }
;;

let numbered written = List.mapi (fun index line -> index + 1, Ok line) written

let position_at messages end_atom : Progress.position =
  { Progress.trace_id = trace; end_atom; last_atom_digest = digest_of messages (end_atom - 1) }
;;

let progress_at ~seen messages end_atom : Progress.t =
  { Progress.position = position_at messages end_atom; boundary_lines_seen = seen }
;;

let describe = function
  | Range.Read { range; boundary_lines_seen } ->
    Printf.sprintf
      "read [%d,%d) turns=%d seen=%d"
      range.Range.start_atom
      range.Range.end_atom
      range.Range.turns
      boundary_lines_seen
  | Range.Baseline { position; boundary_lines_seen } ->
    Printf.sprintf "baseline %d seen=%d" position.Progress.end_atom boundary_lines_seen
  | Range.Nothing_to_read -> "nothing"
  | Range.Position_in_other_trace position ->
    "position in " ^ position.Progress.trace_id
  | Range.Stop (Range.Unreadable_line { line; error = _ }) ->
    Printf.sprintf "stop: line %d unreadable" line
  | Range.Stop (Range.Position_mismatch { position; atom_count }) ->
    Printf.sprintf "stop: position %d of %d atoms" position.Progress.end_atom atom_count
;;

let select ?(extent = Range.All_unread) ?progress ~lines messages =
  describe (Range.select ~trace_id:trace ~lines ~progress ~messages extent)
;;

(* {1 Where a range starts} *)

let test_a_new_trace_is_read_from_zero () =
  let saved = history 2 in
  check string "start line, then the turn's own line"
    "read [0,2) turns=1 seen=2"
    (select ~lines:(numbered [ restarted (); turn_ended ~fresh:true saved ]) saved)
;;

let test_reading_continues_from_the_position () =
  let saved = history 4 in
  let lines =
    numbered
      [ restarted ()
      ; turn_ended ~fresh:true (history 2)
      ; turn_ended ~turn:2 ~fresh:false saved
      ]
  in
  check string "the first range was read, the second turn is next"
    "read [2,4) turns=1 seen=3"
    (select ~progress:(progress_at ~seen:2 saved 2) ~lines saved)
;;

(* Row 3c. The old position seems to match: the new history has the same text
   at the same index. The restart line came after the position last moved, so
   it wins, and the new history is read from zero. *)
let test_a_restart_line_wins_over_a_position_that_seems_to_match () =
  let saved = history 2 in
  let lines =
    numbered
      [ restarted ()
      ; turn_ended ~fresh:true (history 2)
      ; restarted ()
      ; turn_ended ~turn:2 ~fresh:true saved
      ]
  in
  check string "read again from zero"
    "read [0,2) turns=2 seen=4"
    (select ~progress:(progress_at ~seen:2 saved 2) ~lines saved)
;;

let test_a_restart_line_already_passed_is_not_used_again () =
  let saved = history 4 in
  let lines =
    numbered
      [ restarted ()
      ; turn_ended ~fresh:true (history 2)
      ; turn_ended ~turn:2 ~fresh:false saved
      ]
  in
  check string "the restart lines lie before the count the progress file holds"
    "read [2,4) turns=1 seen=3"
    (select ~progress:(progress_at ~seen:2 saved 2) ~lines saved);
  check string "and once everything is read there is nothing"
    "nothing"
    (select ~progress:(progress_at ~seen:3 saved 4) ~lines saved)
;;

(* Row 3, third case: a history that predates the log. *)
let test_without_position_or_restart_the_smallest_line_is_a_baseline () =
  let saved = history 6 in
  let lines =
    numbered
      [ turn_ended ~turn:7 ~fresh:false (history 4); turn_ended ~turn:8 ~fresh:false saved ]
  in
  check string "nothing before the baseline is read" "baseline 4 seen=2" (select ~lines saved)
;;

(* Row 5. *)
let test_a_position_nothing_explains_stops () =
  let saved = history ~tag:"other" 3 in
  let lines = numbered [ turn_ended ~turn:9 ~fresh:false saved ] in
  check string "the position is beyond the history"
    "stop: position 5 of 3 atoms"
    (select ~progress:(progress_at ~seen:1 (history 6) 5) ~lines saved);
  check string "the position is inside the history but the text differs"
    "stop: position 2 of 3 atoms"
    (select ~progress:(progress_at ~seen:1 (history 6) 2) ~lines saved)
;;

(* {1 Which lines are cut points} *)

(* Row 2a. The log is append-only, so the lines of an earlier history of the
   trace stay in it. They are not cut points of this history, and not errors. *)
let test_a_line_of_an_earlier_history_is_not_a_cut_point () =
  let saved = history ~tag:"new" 2 in
  let lines =
    numbered
      [ restarted ()
      ; turn_ended ~fresh:true (history ~tag:"old" 5)
      ; restarted ()
      ; turn_ended ~turn:2 ~fresh:true saved
      ]
  in
  check string "only the line of the current history cuts"
    "read [0,2) turns=1 seen=4"
    (select ~lines saved)
;;

let test_lines_of_another_trace_take_no_part () =
  let saved = history 2 in
  let lines =
    numbered
      [ restarted ~trace_id:"elsewhere" ()
      ; turn_ended ~trace_id:"elsewhere" ~fresh:true (history 2)
      ]
  in
  check string "no line of this trace" "nothing" (select ~lines saved)
;;

(* Row 1b. *)
let test_a_position_of_another_trace_is_reported () =
  let saved = history 2 in
  let elsewhere : Progress.t =
    { Progress.position =
        { Progress.trace_id = "elsewhere"; end_atom = 9; last_atom_digest = "digest" }
    ; boundary_lines_seen = 4
    }
  in
  check string "the caller decides which trace to read"
    "position in elsewhere"
    (select ~progress:elsewhere ~lines:(numbered [ restarted () ]) saved)
;;

(* Row 2c. *)
let test_an_unreadable_line_stops_and_a_torn_tail_does_not () =
  let saved = history 2 in
  let readable = [ 1, Ok (restarted ()); 2, Ok (turn_ended ~fresh:true saved) ] in
  check string "a line the decoder refused may have been a restart line"
    "stop: line 3 unreadable"
    (select ~lines:(readable @ [ 3, Error (Boundaries.Not_json "{") ]) saved);
  check string "a turn that continued a history is no reason to go on"
    "stop: line 2 unreadable"
    (select
       ~lines:
         [ 1, Ok (restarted ())
         ; 2, Error (Boundaries.Not_json "{")
         ; 3, Ok (turn_ended ~turn:2 ~fresh:false saved)
         ]
       saved);
  check string "a fragment with no newline is not a line, and is not counted"
    "read [0,2) turns=1 seen=2"
    (select ~lines:(readable @ [ 3, Error Boundaries.Incomplete_line ]) saved)
;;

(* Row 2c, second half: the file is never rewritten, so a refused line would
   stop every later round as well. A restart line after it ends that: the round
   starts at atom zero whatever the refused line said. *)
let test_a_restart_after_an_unreadable_line_lets_the_rounds_go_on () =
  let saved = history 2 in
  check string "the restart decides the start, so the refused line cannot"
    "read [0,2) turns=1 seen=3"
    (select
       ~lines:
         [ 1, Ok (restarted ())
         ; 2, Error (Boundaries.Not_json "{")
         ; 3, Ok (turn_ended ~fresh:true saved)
         ]
       saved);
  check string "and the round after it resumes from the position, not from zero"
    "nothing"
    (select
       ~progress:(progress_at ~seen:3 saved 2)
       ~lines:
         [ 1, Ok (restarted ())
         ; 2, Error (Boundaries.Not_json "{")
         ; 3, Ok (turn_ended ~fresh:true saved)
         ]
       saved);
  (* A restart settles the refused lines before it and no others. Asking only
     of the first one lets a later one through unread. *)
  check string "a second refused line with no restart after it still stops"
    "stop: line 4 unreadable"
    (select
       ~progress:(progress_at ~seen:3 saved 2)
       ~lines:
         [ 1, Ok (restarted ())
         ; 2, Error (Boundaries.Not_json "{")
         ; 3, Ok (turn_ended ~fresh:true saved)
         ; 4, Error (Boundaries.Not_json "{")
         ]
       saved);
  (* The same shape with the two refusals of different kinds and no read
     position, as the review of this file put it: the decoder refuses on its
     own terms and both terms have to be asked. *)
  let malformed =
    Boundaries.Malformed
      { Wire.path = []; reason = Wire.Expected_object }
  in
  check string "the kind of refusal does not change which line stops the round"
    "stop: line 5 unreadable"
    (select
       ~lines:
         [ 1, Ok (turn_ended ~fresh:true (history 1))
         ; 2, Error (Boundaries.Not_json "x")
         ; 3, Ok (restarted ())
         ; 4, Ok (turn_ended ~turn:2 ~fresh:true saved)
         ; 5, Error malformed
         ]
       saved)
;;

(* {1 How much is read} *)

(* Row 3a. *)
let test_after_a_failed_round_only_the_oldest_turn_is_read () =
  let saved = history 6 in
  let lines =
    numbered
      [ restarted ()
      ; turn_ended ~fresh:true (history 2)
      ; turn_ended ~turn:2 ~fresh:false (history 4)
      ; turn_ended ~turn:3 ~fresh:false saved
      ]
  in
  check string "everything unread" "read [0,6) turns=3 seen=4" (select ~lines saved);
  check string "the oldest turn only"
    "read [0,2) turns=1 seen=4"
    (select ~extent:Range.Oldest_turn_only ~lines saved)
;;

(* {1 The shortest counterexamples of the model} *)

(* With no restart line at the start of a fresh turn: the turn saves and dies,
   the next turn continues and ends. No position, no restart line, so the
   baseline rule would step over atoms 0 and 1. The start line is what makes
   them read. *)
let test_model_a_fresh_turn_that_saves_and_dies () =
  let saved = history 2 in
  check string "without the start line the first span is lost"
    "baseline 2 seen=1"
    (select ~lines:(numbered [ turn_ended ~turn:2 ~fresh:false saved ]) saved);
  check string "with it the first span is read"
    "read [0,2) turns=1 seen=2"
    (select ~lines:(numbered [ restarted (); turn_ended ~turn:2 ~fresh:false saved ]) saved)
;;

(* A turn that could not load its checkpoint replaces the history and dies.
   The reader had read the old history up to its first atom. Where the new
   first atom has the same text, the old position seems to match: a digest
   carries no index and no time. *)
let test_model_an_unread_turn_that_replaces_the_history_and_dies () =
  let passed = progress_at ~seen:2 (history 1) 1 in
  let before_the_turn = numbered [ restarted (); turn_ended ~fresh:true (history 1) ] in
  let after_its_save = before_the_turn @ [ 3, Ok (restarted ()) ] in
  let same_text = history 1 in
  check string "with no line after the replacing save the new atom is never read"
    "nothing"
    (select ~progress:passed ~lines:before_the_turn same_text);
  check string "with the line the new history is read from zero"
    "read [0,1) turns=1 seen=3"
    (select ~progress:passed ~lines:after_its_save same_text);
  let other_text = history ~tag:"new" 1 in
  check string "where the text differs the missing line is at least a visible stop"
    "stop: position 1 of 1 atoms"
    (select ~progress:passed ~lines:before_the_turn other_text);
  check string "with the line nothing is read until a turn ends: the dead turn left no cut point"
    "nothing"
    (select ~progress:passed ~lines:after_its_save other_text);
  let continued = history ~tag:"new" 2 in
  check string "and then what the dead turn saved is read with the turn that ended"
    "read [0,2) turns=1 seen=4"
    (select
       ~progress:passed
       ~lines:(after_its_save @ [ 4, Ok (turn_ended ~turn:3 ~fresh:false continued) ])
       continued)
;;

(* {1 What is written and what is read} *)

let test_progress_moves_only_when_something_was_read () =
  let saved = history 2 in
  let lines = numbered [ restarted (); turn_ended ~fresh:true saved ] in
  (match
     Range.progress_after
       ~trace_id:trace
       (Range.select ~trace_id:trace ~lines ~progress:None ~messages:saved Range.All_unread)
   with
   | Some written ->
     check int "the end of the range" 2 written.Progress.position.Progress.end_atom;
     check string "its digest" (digest_of saved 1)
       written.Progress.position.Progress.last_atom_digest;
     check int "the count taken from the lines that were handed in" 2
       written.Progress.boundary_lines_seen
   | None -> fail "a range was read and no progress follows");
  match Range.progress_after ~trace_id:trace Range.Nothing_to_read with
  | None -> ()
  | Some _ -> fail "nothing was read and the progress moved"
;;

let test_slice_returns_the_atoms_of_the_range () =
  let tool : Types.message = message ~role:Types.Tool "result" in
  let saved =
    [ message ~role:Types.System "pinned"; user "u0"; assistant "a1"; tool; user "u2" ]
  in
  let range : Range.range =
    { Range.start_atom = 1; end_atom = 3; last_atom_digest = digest_of saved 2; turns = 1 }
  in
  check int "the assistant, its tool result, and the next user message" 3
    (List.length (Range.slice saved range));
  check bool "the system message belongs to no atom" true
    (List.for_all
       (fun (sliced : Types.message) ->
          match sliced.role with
          | Types.System -> false
          | Types.User | Types.Assistant | Types.Tool -> true)
       (Range.slice saved range))
;;

let () =
  run
    "keeper_librarian_range"
    [ ( "start"
      , [ test_case "a new trace is read from zero" `Quick test_a_new_trace_is_read_from_zero
        ; test_case "reading continues from the position" `Quick
            test_reading_continues_from_the_position
        ; test_case "a restart line wins over a position that seems to match" `Quick
            test_a_restart_line_wins_over_a_position_that_seems_to_match
        ; test_case "a restart line already passed is not used again" `Quick
            test_a_restart_line_already_passed_is_not_used_again
        ; test_case "without position or restart the smallest line is a baseline" `Quick
            test_without_position_or_restart_the_smallest_line_is_a_baseline
        ; test_case "a position nothing explains stops" `Quick
            test_a_position_nothing_explains_stops
        ] )
    ; ( "cut points"
      , [ test_case "a line of an earlier history is not a cut point" `Quick
            test_a_line_of_an_earlier_history_is_not_a_cut_point
        ; test_case "lines of another trace take no part" `Quick
            test_lines_of_another_trace_take_no_part
        ; test_case "a position of another trace is reported" `Quick
            test_a_position_of_another_trace_is_reported
        ; test_case "an unreadable line stops and a torn tail does not" `Quick
            test_an_unreadable_line_stops_and_a_torn_tail_does_not
        ; test_case "a restart after an unreadable line lets the rounds go on" `Quick
            test_a_restart_after_an_unreadable_line_lets_the_rounds_go_on
        ] )
    ; ( "extent"
      , [ test_case "after a failed round only the oldest turn is read" `Quick
            test_after_a_failed_round_only_the_oldest_turn_is_read
        ] )
    ; ( "model"
      , [ test_case "a fresh turn that saves and dies" `Quick
            test_model_a_fresh_turn_that_saves_and_dies
        ; test_case "an unread turn that replaces the history and dies" `Quick
            test_model_an_unread_turn_that_replaces_the_history_and_dies
        ] )
    ; ( "progress and slice"
      , [ test_case "progress moves only when something was read" `Quick
            test_progress_moves_only_when_something_was_read
        ; test_case "slice returns the atoms of the range" `Quick
            test_slice_returns_the_atoms_of_the_range
        ] )
    ]
;;
