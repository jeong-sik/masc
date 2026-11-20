(* Where the read end of a Keeper's Memory falls in the history a request is
   cut from (RFC librarian-call-only-proposes §11.1, §11.2): the writer's
   view, turned from a count of closed messages into an atom. No digest is
   compared, so a rewritten closed message keeps the place. *)

open Alcotest
open Masc
module T = Agent_core.Types
module Point = Keeper_covered_point
module Window = Runtime_model_input_tail_window

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
;;

let placed messages view = place_label (Point.of_view ~trace_id ~messages view).Point.place
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
    (placed history (view ~through:Librarian_log.Before_first (List.length read_turn)))
;;

let test_a_view_of_another_trace_is_unresolved () =
  check string "a cleared history is not placed by the trace it replaced"
    "unresolved: the view ends on trace another-trace"
    (placed history (view ~trace:"another-trace" (List.length read_turn)))
;;

let test_a_history_shorter_than_the_view_is_unresolved () =
  check string "a history that lost read messages names no start"
    (Printf.sprintf "unresolved: %d closed messages read, %d in hand" (List.length history + 1)
       (List.length history))
    (placed history (view (List.length history + 1)))
;;

let test_the_working_state_comes_with_every_place () =
  let working_state_of view = (Point.of_view ~trace_id ~messages:history view).Point.working_state in
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
        ] )
    ; ( "no read end"
      , [ test_case "nothing read names no place" `Quick test_nothing_read_names_no_place
        ; test_case "a view of another trace is unresolved" `Quick
            test_a_view_of_another_trace_is_unresolved
        ; test_case "a history shorter than the view is unresolved" `Quick
            test_a_history_shorter_than_the_view_is_unresolved
        ; test_case "a workspace without writers has no view" `Quick
            test_a_workspace_without_writers_has_no_view
        ] )
    ; ( "working state"
      , [ test_case "the working state comes with every place" `Quick
            test_the_working_state_comes_with_every_place
        ] )
    ]
;;
