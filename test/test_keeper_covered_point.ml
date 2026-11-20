(* Where the read end of a Keeper's Memory falls in the history a request is
   cut from (RFC librarian-call-only-proposes §11.1, §11.2): the writer's
   view, turned from a count of closed messages into an atom. No digest is
   compared, so a rewritten closed message keeps the place. A [Reset] line of
   the turn log that the writer has not read starts the count again, so the
   view names no place until it is read. *)

open Alcotest
open Masc
module T = Agent_core.Types
module Point = Keeper_covered_point
module Window = Runtime_model_input_tail_window
module Log = Keeper_turn_log
module Store = Keeper_turn_log_store

let trace_id = "covered-trace"
let text role body = T.make_message ~role [ T.Text body ]
let read_turn = [ text T.User "Build the patch."; text T.Assistant "The build passed." ]
let history = read_turn @ [ text T.User "Inspect the patch." ]

let mark ~trace closed_messages : Keeper_turn_log.mark =
  { trace
  ; closed_messages
  ; session = "covered-session"
  ; history_bytes = 0
  ; internal_bytes = 0
  ; chat_bytes = 0
  ; external_rows = 0
  }
;;

let whole_unit = Librarian_log.Through { line = 0; within = Librarian_log.Whole }

let view ?(trace = trace_id) ?working_state ?(through = whole_unit) closed_messages
  : Librarian_writer.view
  =
  { covers_through = through; covered = mark ~trace closed_messages; working_state }
;;

let place_label = function
  | Point.Covered { end_atom } -> Printf.sprintf "covered to atom %d" end_atom
  | Point.Nothing_read -> "nothing read"
  | Point.Front_unresolved (Point.Other_trace { covered }) ->
    Printf.sprintf "unresolved: the view ends on trace %s" covered
  | Point.Front_unresolved (Point.History_shorter { closed_messages; in_hand }) ->
    Printf.sprintf "unresolved: %d closed messages read, %d in hand" closed_messages in_hand
  | Point.Front_unresolved (Point.Reset_unread { offset }) ->
    Printf.sprintf "unresolved: a reset at byte %d is not read" offset
  | Point.Front_unresolved (Point.Turn_log_unread { detail }) ->
    "unresolved: the turn log is not read: " ^ detail
;;

let no_reset ~line:(_ : int) ~within:(_ : Librarian_log.within) = Point.No_reset

(* A place the cheap checks decide is decided without the turn log. *)
let not_asked ~line:(_ : int) ~within:(_ : Librarian_log.within) : Point.unread_lines =
  fail "the turn log was read for a view the trace or the count already decides"
;;

let placed ?(unread_lines = no_reset) messages view =
  place_label (Point.of_view ~trace_id ~messages ~unread_lines view).Point.place
;;
let covered_to messages = Printf.sprintf "covered to atom %d" (snd (Window.annotate messages))

let test_the_read_end_is_an_atom () =
  check string "the request may start where the read turn's atoms end" (covered_to read_turn)
    (placed history (view (List.length read_turn)))
;;

let test_everything_read_ends_after_the_history () =
  check string "a history read to its end has no atom left to send" (covered_to history)
    (placed history (view (List.length history)))
;;

let test_a_rewritten_closed_message_keeps_the_place () =
  let rewritten =
    [ text T.User "Rebuild the patch."; text T.Assistant "The rebuild passed."; text T.User "Inspect it." ]
  in
  check string "a purge that rewrites read messages keeps their number" (covered_to read_turn)
    (placed rewritten (view (List.length read_turn)))
;;

let test_a_part_of_a_unit_ends_where_its_mark_says () =
  let through = Librarian_log.Through { line = 120; within = Librarian_log.Item 0 } in
  check string "an item of a unit is placed by the mark it ends at" (covered_to read_turn)
    (placed history (view ~through (List.length read_turn)))
;;

let test_nothing_read_names_no_place () =
  check string "a writer that read no unit gives no read end, whatever its mark counts"
    "nothing read"
    (placed ~unread_lines:not_asked history
       (view ~through:Librarian_log.Before_first (List.length read_turn)))
;;

let test_a_view_of_another_trace_is_unresolved () =
  check string "a view that ends on another trace names no place in this one"
    "unresolved: the view ends on trace another-trace"
    (placed ~unread_lines:not_asked history (view ~trace:"another-trace" (List.length read_turn)))
;;

let test_a_history_shorter_than_the_view_is_unresolved () =
  check string "a history that lost read messages names no start"
    (Printf.sprintf "unresolved: %d closed messages read, %d in hand" (List.length history + 1)
       (List.length history))
    (placed ~unread_lines:not_asked history (view (List.length history + 1)))
;;

(* A tool result belongs to the atom of the call. A count that ends on it
   gives that atom, so the request repeats the call and leaves nothing out. *)
let test_a_count_that_ends_on_a_tool_result_gives_its_atom () =
  let call : T.message =
    { (text T.Assistant "Reading the file.") with
      content = [ T.ToolUse { id = "call-1"; name = "read_file"; input = `Assoc [] } ]
    }
  in
  let result : T.message =
    { (text T.Tool "") with
      content =
        [ T.ToolResult
            { tool_use_id = "call-1"
            ; content = "the file"
            ; outcome = T.Tool_succeeded
            ; json = None
            ; content_blocks = None
            }
        ]
    ; tool_call_id = Some "call-1"
    }
  in
  let messages = [ text T.User "Read the file."; call; result; text T.Assistant "It is short." ] in
  let atom_of_the_call =
    match List.nth (fst (Window.annotate messages)) 1 with
    | (_ : T.message), Window.Atom atom -> atom
    | (_ : T.message), Window.Pinned -> fail "the call is pinned"
  in
  check string "the read end is the atom the call opens"
    (Printf.sprintf "covered to atom %d" atom_of_the_call)
    (placed messages (view 2))
;;

(* The head went back to 80 closed messages after the writer read 100, and
   this turn added 25 open ones. The list holds 105, so the count alone would
   open the request at message 100 and leave out 20 of this turn's. *)
let test_a_reset_the_writer_has_not_read_names_no_place () =
  let messages = List.init 105 (fun index -> text T.User (Printf.sprintf "message %d" index)) in
  check string "the view's count was taken before the reset"
    "unresolved: a reset at byte 512 is not read"
    (placed
       ~unread_lines:(fun ~line:(_ : int) ~within:(_ : Librarian_log.within) ->
         Point.Reset_at { offset = 512 })
       messages (view 100))
;;

let test_an_unreadable_turn_log_names_no_place () =
  check string "a reset that may follow is not ruled out"
    "unresolved: the turn log is not read: the turn log line at byte 64 does not decode"
    (placed
       ~unread_lines:(fun ~line:(_ : int) ~within:(_ : Librarian_log.within) ->
         Point.Not_scanned { detail = "the turn log line at byte 64 does not decode" })
       history (view (List.length read_turn)))
;;

let test_the_turn_log_is_asked_at_the_views_position () =
  let asked = ref [] in
  let unread_lines ~line ~within =
    asked := (line, within) :: !asked;
    Point.No_reset
  in
  let through = Librarian_log.Through { line = 120; within = Librarian_log.Item 2 } in
  ignore (placed ~unread_lines history (view ~through (List.length read_turn)) : string);
  check (list (pair int int)) "once, at the unit line and the item the view names"
    [ 120, 2 ]
    (List.map
       (fun (line, within) ->
          ( line
          , match within with
            | Librarian_log.Whole -> -1
            | Librarian_log.Item item -> item ))
       !asked)
;;

(* The lines of a turn log after a position, on a file. *)
let log_mark closed_messages : Log.mark =
  { trace = trace_id
  ; closed_messages
  ; session = "covered-session"
  ; history_bytes = 0
  ; internal_bytes = 0
  ; chat_bytes = 0
  ; external_rows = 0
  }
;;

let started = Log.Log_started { id = Log.Log_id.fresh (); at = 100.0; mark = log_mark 0 }

let opened baseline =
  Log.Opened
    { at = 101.0
    ; turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn:1
    ; runtime = "fixture"
    ; task = Log.No_task
    ; stimuli = []
    ; baseline = log_mark baseline
    }
;;

let closed ~turn after =
  Log.Closed
    { turn; at = 102.0; outcome = Log.Completed; after = log_mark after; unattributed = []; own = [] }
;;

let reset cause ~before ~after =
  Log.Reset { at = 103.0; cause; before = log_mark before; after = log_mark after; closed_before = [] }
;;

(* A turn log of [lines] after its first line, and the byte each starts at. *)
let turn_log lines =
  let path =
    Store.path_for_keepers_dir ~keepers_dir:(Filename.temp_dir "covered-point" "") ~keeper_id:"covered-keeper"
  in
  let append at_end line =
    match Store.append ~path ~at_end (line, []) with
    | Ok (appended : Store.appended) -> appended
    | Error (_ : Store.append_error) -> fail "the fixture turn log was not written"
  in
  let first = append 0 started in
  let (_ : int), offsets =
    List.fold_left
      (fun (at_end, offsets) line ->
         let appended = append at_end line in
         appended.Store.new_end, appended.Store.last_at :: offsets)
      (first.Store.new_end, [])
      lines
  in
  path, List.rev offsets
;;

let unread_label = function
  | Point.No_reset -> "no reset"
  | Point.Reset_at { offset } -> Printf.sprintf "reset at %d" offset
  | Point.Not_scanned { detail = (_ : string) } -> "not scanned"
;;

let scanned ?(within = Librarian_log.Whole) turns_path line =
  unread_label (Point.read_unread_lines ~turns_path ~line ~within)
;;

let nth offsets index = List.nth offsets index

let test_turns_after_the_read_unit_are_no_reset () =
  let turns_path, offsets = turn_log [ opened 0; closed ~turn:0 2; opened 2; closed ~turn:0 4; opened 4 ] in
  check string "closed turns and an open one leave the count standing" "no reset"
    (scanned turns_path (nth offsets 1));
  check string "an open turn after the last unit is no reset" "no reset"
    (scanned turns_path (nth offsets 3))
;;

let test_each_kind_of_reset_after_the_read_unit_counts () =
  List.iter
    (fun (name, cause) ->
       let turns_path, offsets =
         turn_log [ opened 0; closed ~turn:0 4; reset cause ~before:4 ~after:1; opened 1; closed ~turn:0 6 ]
       in
       check string name
         (Printf.sprintf "reset at %d" (nth offsets 2))
         (scanned turns_path (nth offsets 1)))
    [ "a clear", Log.Announced Log.Cleared
    ; "a purge that dropped messages", Log.Announced Log.Recovered
    ; "a head found below the last mark", Log.Unannounced
    ]
;;

let test_a_reset_that_was_read_is_behind_the_position () =
  let turns_path, offsets =
    turn_log [ opened 0; closed ~turn:0 4; reset Log.Unannounced ~before:4 ~after:0; opened 0; closed ~turn:0 3 ]
  in
  check string "read to its end, the reset is where the count starts" "no reset"
    (scanned turns_path (nth offsets 2));
  check string "read in part, it is not behind yet"
    (Printf.sprintf "reset at %d" (nth offsets 2))
    (scanned ~within:(Librarian_log.Item 0) turns_path (nth offsets 2))
;;

let test_a_position_that_is_no_unit_line_is_not_scanned () =
  let turns_path, offsets = turn_log [ opened 0; closed ~turn:0 2 ] in
  check string "an admission line ends no unit" "not scanned" (scanned turns_path (nth offsets 0));
  check string "a byte inside a line starts none" "not scanned"
    (scanned turns_path (nth offsets 1 + 1));
  check string "the first line starts the log" "not scanned" (scanned turns_path 0);
  check string "a negative byte is no position" "not scanned" (scanned turns_path (-1))
;;

let test_the_working_state_comes_with_every_place () =
  let working_state_of view =
    (Point.of_view ~trace_id ~messages:history ~unread_lines:no_reset view).Point.working_state
  in
  let working_state = "shipping the patch" in
  check (option string) "with a read end" (Some working_state)
    (working_state_of (view ~working_state (List.length read_turn)));
  check (option string) "with a view that does not resolve" (Some working_state)
    (working_state_of (view ~trace:"another-trace" ~working_state (List.length read_turn)));
  check (option string) "and none when the writer committed none" None
    (working_state_of (view (List.length read_turn)))
;;

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

(* This process started no Memory writers, so the workspace has no table.
   That is not a writer that has read nothing. *)
let test_a_workspace_without_writers_has_no_view () =
  let base = Filename.temp_file "covered-point" "" in
  Sys.remove base;
  Unix.mkdir base 0o700;
  Fun.protect ~finally:(fun () -> rm_rf base)
  @@ fun () ->
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Fun.protect ~finally:Fs_compat.clear_fs
  @@ fun () ->
  let config = Workspace.default_config base in
  match Point.read ~config ~keeper_name:"covered-keeper" ~trace_id ~messages:history with
  | Error `Writers_not_started -> ()
  | Error (`Booting | `Stopped (_ : Librarian_store.stop) | `No_writer) ->
    fail "a workspace with no writers answered as if it had a writer"
  | Ok point -> fail ("a workspace with no writers gave a view: " ^ place_label point.Point.place)
;;

let () =
  run "keeper_covered_point"
    [ ( "read end"
      , [ test_case "the read end is an atom of the history" `Quick test_the_read_end_is_an_atom
        ; test_case "a history read to its end" `Quick test_everything_read_ends_after_the_history
        ; test_case "a rewritten closed message keeps the place" `Quick
            test_a_rewritten_closed_message_keeps_the_place
        ; test_case "a part of a unit ends where its mark says" `Quick
            test_a_part_of_a_unit_ends_where_its_mark_says
        ; test_case "a count that ends on a tool result gives its atom" `Quick
            test_a_count_that_ends_on_a_tool_result_gives_its_atom
        ; test_case "the turn log is asked at the view's position" `Quick
            test_the_turn_log_is_asked_at_the_views_position
        ] )
    ; ( "turn log after the position"
      , [ test_case "turns after the read unit are no reset" `Quick
            test_turns_after_the_read_unit_are_no_reset
        ; test_case "each kind of reset after the read unit counts" `Quick
            test_each_kind_of_reset_after_the_read_unit_counts
        ; test_case "a reset that was read is behind the position" `Quick
            test_a_reset_that_was_read_is_behind_the_position
        ; test_case "a position that is no unit line is not scanned" `Quick
            test_a_position_that_is_no_unit_line_is_not_scanned
        ] )
    ; ( "no read end"
      , [ test_case "nothing read names no place" `Quick test_nothing_read_names_no_place
        ; test_case "a view of another trace is unresolved" `Quick
            test_a_view_of_another_trace_is_unresolved
        ; test_case "a history shorter than the view is unresolved" `Quick
            test_a_history_shorter_than_the_view_is_unresolved
        ; test_case "a reset the writer has not read names no place" `Quick
            test_a_reset_the_writer_has_not_read_names_no_place
        ; test_case "an unreadable turn log names no place" `Quick
            test_an_unreadable_turn_log_names_no_place
        ; test_case "a workspace without writers has no view" `Quick
            test_a_workspace_without_writers_has_no_view
        ] )
    ; ( "working state"
      , [ test_case "the working state comes with every place" `Quick
            test_the_working_state_comes_with_every_place
        ] )
    ]
;;
