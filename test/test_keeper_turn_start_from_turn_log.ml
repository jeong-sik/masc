(* Where a request with no seed starts, read from the Keeper's turn log
   (RFC librarian-call-only-proposes §11.2): the end of the last unit, turned
   from a count of closed messages into an atom of the history in hand. No
   digest is compared, so a rewritten closed message keeps the start. *)

open Alcotest
open Masc
module T = Agent_core.Types
module Front = Keeper_carried_front
module Driver = Keeper_turn_driver_try_provider
module Window = Runtime_model_input_tail_window

let keeper_name = "turn-start"
let trace_id = "turn-start-trace"
let text role body = T.make_message ~role [ T.Text body ]
let completed = [ text T.User "Build the patch."; text T.Assistant "The build passed." ]
let history = completed @ [ text T.User "Inspect the patch." ]

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_workspace f () =
  let base = Filename.temp_file "turn-start-from-log" "" in
  Sys.remove base;
  Unix.mkdir base 0o700;
  Fun.protect ~finally:(fun () -> rm_rf base)
  @@ fun () ->
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Fun.protect ~finally:Fs_compat.clear_fs (fun () -> f ~config:(Workspace.default_config base))
;;

let keepers_dir config = Workspace.keepers_runtime_dir config

let log_path config =
  Keeper_turn_log_store.path_for_keepers_dir ~keepers_dir:(keepers_dir config) ~keeper_id:keeper_name
;;

let start config ~trace_id ~closed_messages =
  Masc_test_deps.start_turn_log ~keepers_dir:(keepers_dir config) ~keeper_name ~trace_id
    ~closed_messages
;;

let turn_start config messages = Driver.turn_start ~config ~keeper_name ~trace_id ~messages

let check_boundary label expected = function
  | Front.Turn_boundary { end_atom } -> check int label expected end_atom
  | Front.Turn_boundary_unknown { reason } -> fail (label ^ ", but it was unknown: " ^ reason)
;;

let check_unknown label = function
  | Front.Turn_boundary_unknown _ -> ()
  | Front.Turn_boundary { end_atom } -> fail (Printf.sprintf "%s, but it answered atom %d" label end_atom)
;;

let test_a_log_with_no_line_starts_at_zero =
  with_workspace
  @@ fun ~config ->
  check_boundary "a Keeper with no recorded turn sends its whole history" 0 (turn_start config history)
;;

let test_the_last_unit_end_is_the_start =
  with_workspace
  @@ fun ~config ->
  start config ~trace_id ~closed_messages:(List.length completed);
  check_boundary "the start is where the completed turn's atoms end"
    (snd (Window.annotate completed))
    (turn_start config history)
;;

let test_a_rewritten_closed_message_keeps_the_start =
  with_workspace
  @@ fun ~config ->
  start config ~trace_id ~closed_messages:(List.length completed);
  let rewritten =
    [ text T.User "Rebuild the patch."; text T.Assistant "The rebuild passed."; text T.User "Inspect it." ]
  in
  check_boundary "a purge that rewrites closed messages keeps their number"
    (snd (Window.annotate completed))
    (turn_start config rewritten)
;;

let test_a_mark_of_another_trace_is_unknown =
  with_workspace
  @@ fun ~config ->
  start config ~trace_id:"another-trace" ~closed_messages:(List.length completed);
  check_unknown "a unit that ended on another trace names no start here" (turn_start config history)
;;

let test_a_history_shorter_than_the_mark_is_unknown =
  with_workspace
  @@ fun ~config ->
  start config ~trace_id ~closed_messages:(List.length history + 1);
  check_unknown "a history that lost closed messages names no start" (turn_start config history)
;;

(* Reading decides nothing: the request whose range it opens reports it. *)
let test_an_unreadable_log_is_unknown_and_logs_nothing =
  with_workspace
  @@ fun ~config ->
  Fs_compat.mkdir_p (Filename.dirname (log_path config));
  Fs_compat.save_file (log_path config) "not a line\n";
  let before =
    match Log.Ring.recent ~limit:1 () with
    | [] -> -1
    | entry :: _ -> entry.Log.Ring.seq
  in
  check_unknown "a log whose tail does not decode names no start" (turn_start config history);
  check int "reading the unknown start logs no warning" 0
    (Log.Ring.recent ~since_seq:before ~min_level:(Log.level_to_int Log.Warn) ()
     |> List.filter (fun (entry : Log.Ring.entry) ->
       Option.equal String.equal entry.keeper_name (Some keeper_name))
     |> List.length)
;;

let () =
  run "keeper_turn_start_from_turn_log"
    [ ( "turn start"
      , [ test_case "a log with no line starts at zero" `Quick test_a_log_with_no_line_starts_at_zero
        ; test_case "the last unit's end is the start" `Quick test_the_last_unit_end_is_the_start
        ; test_case "a rewritten closed message keeps the start" `Quick
            test_a_rewritten_closed_message_keeps_the_start
        ; test_case "a mark of another trace is unknown" `Quick test_a_mark_of_another_trace_is_unknown
        ; test_case "a history shorter than the mark is unknown" `Quick
            test_a_history_shorter_than_the_mark_is_unknown
        ; test_case "an unreadable log is unknown and logs nothing" `Quick
            test_an_unreadable_log_is_unknown_and_logs_nothing
        ] )
    ]
;;
