(** Tests for {!Masc.Keeper_turn_fragments} and the official-client rows of
    {!Masc.Keeper_librarian_range} (RFC librarian-lifecycle §10-3): what an
    official-client turn left in its trace's history files is read back by
    the turn's [turn_ref]; a line the decoder refuses is a typed stop and not
    an untagged line; and the official-turn end lines of the boundary log are
    selected by their line number, beyond a cursor. *)

open Alcotest

module Fragments = Masc.Keeper_turn_fragments
module History = Masc.Keeper_context_core_history
module Range = Masc.Keeper_librarian_range
module Boundaries = Masc.Keeper_turn_boundaries
module Official = Masc.Keeper_librarian_official_progress
module Wire = Masc.Keeper_memory_os_types
module Types = Agent_core.Types

let keeper_name = "keeper"
let trace_id = "trace"
let turn n = Ids.Turn_ref.make ~trace_id ~absolute_turn:n

let message ~role text : Types.message =
  { role; content = [ Types.Text text ]; name = None; tool_call_id = None; metadata = [] }
;;

let with_session f =
  Eio_main.run
  @@ fun env ->
  if not (Fs_compat.has_fs ()) then Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = Filename.temp_dir "turn-fragments-" "" in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree base_dir)
    (fun () ->
       let session = Masc.Keeper_context_core.create_session ~session_id:trace_id ~base_dir in
       f session)
;;

let read session file =
  match Fragments.read ~session_dir:session.Keeper_types.session_dir file with
  | Ok lines -> lines
  | Error detail -> fail detail
;;

let append_raw session file text =
  let path = Fragments.path ~session_dir:session.Keeper_types.session_dir file in
  Fs_compat.mkdir_p (Filename.dirname path);
  Out_channel.with_open_gen [ Open_wronly; Open_append; Open_creat ] 0o600 path (fun oc ->
    Out_channel.output_string oc text)
;;

let text_of (fragment : Fragments.fragment) =
  match fragment with
  | Fragments.Message { message; _ } -> Types.text_of_content message.content
  | Fragments.Tool_observation { observation; _ } -> "tool:" ^ observation.tool_name
;;

(* What the writer wrote, the reader hands back under the turn that wrote it. *)
let test_a_turns_fragments_come_back_by_its_turn_ref () =
  with_session
  @@ fun session ->
  History.persist_message ~keeper_name ~turn_ref:(turn 1) ~source:"user" session
    (message ~role:Types.User "q1");
  History.persist_message ~keeper_name ~turn_ref:(turn 1) ~source:"assistant" session
    (message ~role:Types.Assistant "a1");
  History.persist_message ~keeper_name ~turn_ref:(turn 2) ~source:"user" session
    (message ~role:Types.User "q2");
  History.persist_tool_observation ~keeper_name ~turn_ref:(turn 1) session
    ~tool_name:"masc_tasks" ~outcome:Tool_result.Error;
  let main = read session Fragments.Main in
  let internal = read session Fragments.Internal in
  check (list string) "turn 1, main file then internal, in file order"
    [ "q1"; "a1"; "tool:masc_tasks" ]
    (List.map text_of (Fragments.of_turn (turn 1) (main @ internal)));
  check (list string) "turn 2 alone" [ "q2" ]
    (List.map text_of (Fragments.of_turn (turn 2) (main @ internal)));
  (match Fragments.of_turn (turn 1) internal with
   | [ Fragments.Tool_observation { observation = { outcome = Masc.Keeper_librarian.Failed; _ }; _ } ] -> ()
   | _ -> fail "the observation's outcome is not the one written")
;;

(* A line from before lines named their turn belongs to no turn; a refused
   line among those predates turn-named history and stops nothing. A refused
   line after the first named one stops. *)
let test_untagged_lines_belong_to_no_turn_and_refusals_count_from_the_first_named () =
  with_session
  @@ fun session ->
  append_raw session Fragments.Main
    {|{"ts_unix":1.0,"role":"user","content_blocks":[{"type":"text","text":"old"}]}
not json at all
|};
  History.persist_message ~keeper_name ~turn_ref:(turn 1) session (message ~role:Types.User "new");
  let lines = read session Fragments.Main in
  (match lines with
   | [ (1, Ok Fragments.Untagged); (2, Error (Fragments.Not_json _)); (3, Ok (Fragments.Fragment _)) ] -> ()
   | _ -> failf "unexpected shape of %d lines" (List.length lines));
  check bool "a refusal before the first named line stops nothing" true
    (Option.is_none (Fragments.first_refused lines));
  append_raw session Fragments.Main "{\"turn_ref\":\"trace#9\",\"kind\":\"riddle\",\"ts_unix\":2.0}\n";
  let lines = read session Fragments.Main in
  (match Fragments.first_refused lines with
   | Some (4, Fragments.Malformed _) -> ()
   | Some (line, error) -> failf "refused at %d: %s" line (Fragments.read_error_to_string error)
   | None -> fail "a refused line after the first named one did not stop")
;;

(* A tagged line the decoder cannot name is refused, never untagged: a wrong
   kind, an outcome this build does not know, a key the writer never
   writes, and a message the message decoder rejects. *)
let test_a_tagged_line_that_cannot_be_named_is_refused () =
  with_session
  @@ fun session ->
  append_raw session Fragments.Internal
    (String.concat "\n"
       [ {|{"ts_unix":1.0,"turn_ref":"trace#1","kind":"tool_observation","tool_name":"t","outcome":"maybe"}|}
       ; {|{"ts_unix":1.0,"turn_ref":"trace#1","kind":"message","role":"user","content_blocks":[],"extra":1}|}
       ; {|{"ts_unix":1.0,"turn_ref":"trace#1","kind":"message","role":"user"}|}
       ; {|{"ts_unix":1.0,"turn_ref":"not a ref","kind":"message"}|}
       ; {|{"ts_unix":1.0,"turn_ref":"trace#1","kind":"message","role":"oracle","content_blocks":[]}|}
       ; {|{"ts_unix":1.0,"turn_ref":"trace#1","kind":"tool_observation","tool_name":"t","outcome":"ok"}|}
       ]
     ^ "\n");
  let lines = read session Fragments.Internal in
  let kinds =
    List.map
      (fun (_, read) ->
         match read with
         | Ok (Fragments.Fragment _) -> "fragment"
         | Ok Fragments.Untagged -> "untagged"
         | Error (Fragments.Malformed _) -> "malformed"
         | Error (Fragments.Message_rejected _) -> "message_rejected"
         | Error (Fragments.Not_json _) -> "not_json"
         | Error Fragments.Incomplete_line -> "incomplete")
      lines
  in
  check (list string) "each line is named for what is wrong with it"
    [ "malformed"; "malformed"; "malformed"; "malformed"; "message_rejected"; "fragment" ]
    kinds
;;

(* An append that died mid-line is not a line: it is neither a fragment nor
   a refusal. *)
let test_a_torn_tail_is_not_a_line () =
  with_session
  @@ fun session ->
  History.persist_message ~keeper_name ~turn_ref:(turn 1) session (message ~role:Types.User "whole");
  append_raw session Fragments.Main {|{"ts_unix":2.0,"turn_ref":"trace#2","ki|};
  let lines = read session Fragments.Main in
  (match lines with
   | [ (1, Ok (Fragments.Fragment _)); (2, Error Fragments.Incomplete_line) ] -> ()
   | _ -> failf "unexpected shape of %d lines" (List.length lines));
  check bool "the torn tail stops nothing" true (Option.is_none (Fragments.first_refused lines))
;;

(* {1 Official-turn end lines of the boundary log} *)

let ended ?(trace = trace_id) ~line ~turn position : int * (Boundaries.record, Boundaries.read_error) result =
  ( line
  , Ok
      { Boundaries.recorded_at = Float.of_int line
      ; event =
          Boundaries.Turn_ended
            { turn_ref = Ids.Turn_ref.make ~trace_id:trace ~absolute_turn:turn
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

(* A refused line beyond the cursor stops: it may be an official turn's end
   line. One at or before the cursor was already passed and stops nothing. *)
let test_a_refused_line_beyond_the_cursor_stops () =
  let log = [ ended ~line:1 ~turn:1 official; refused 2; ended ~line:3 ~turn:3 official ] in
  check (list int) "beyond the cursor: stop at the refused line" [ -2 ]
    (lines_of (Range.select_official ~lines:log ~cursor:None Range.All_unread));
  check (list int) "at or before the cursor: read on" [ 3 ]
    (lines_of
       (Range.select_official ~lines:log ~cursor:(Some { Official.boundary_line = 2 })
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
    "keeper_turn_fragments"
    [ ( "fragments"
      , [ test_case "a turn's fragments come back by its turn_ref" `Quick
            test_a_turns_fragments_come_back_by_its_turn_ref
        ; test_case "untagged lines belong to no turn; refusals count from the first named" `Quick
            test_untagged_lines_belong_to_no_turn_and_refusals_count_from_the_first_named
        ; test_case "a tagged line that cannot be named is refused" `Quick
            test_a_tagged_line_that_cannot_be_named_is_refused
        ; test_case "a torn tail is not a line" `Quick test_a_torn_tail_is_not_a_line
        ] )
    ; ( "official lines"
      , [ test_case "official lines are selected beyond the cursor" `Quick
            test_official_lines_are_selected_beyond_the_cursor
        ; test_case "a refused line beyond the cursor stops" `Quick
            test_a_refused_line_beyond_the_cursor_stops
        ; test_case "cut lines name every turn inside the range" `Quick
            test_cut_lines_name_every_turn_inside_the_range
        ] )
    ]
;;
