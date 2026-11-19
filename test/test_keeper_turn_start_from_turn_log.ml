(* Where a request with no seed starts and where this turn began, read from
   the Keeper's turn log (RFC librarian-call-only-proposes §11.2): the end of
   the last unit and the open turn's baseline, each turned from a count of
   closed messages into an atom of the history in hand. No digest is
   compared, so a rewritten closed message keeps both. *)

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

(* A turn that saved its messages and failed, so no unit ended it, then this
   turn's input. *)
let failed = [ text T.User "Ship the patch."; text T.Assistant "The upload stopped." ]
let resumed = completed @ failed @ [ text T.User "Ship it again." ]

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

let open_turn config ~trace_id ~closed_messages =
  Masc_test_deps.open_turn_log ~keepers_dir:(keepers_dir config) ~keeper_name ~trace_id
    ~closed_messages
;;

(* A history clear after this turn's [Opened]: the baseline then counts the
   history it replaced. *)
let reset_after_open config =
  let mark = Masc_test_deps.turn_log_mark ~trace_id ~closed_messages:0 in
  let rows_end =
    match Keeper_turn_log_store.read_tail (log_path config) with
    | Ok (Keeper_turn_log_store.Written { rows_end; _ }) -> rows_end
    | Ok Keeper_turn_log_store.Nothing_written -> fail "the turn log has no line to reset after"
    | Error error ->
      fail
        (Keeper_turn_log_recorder.not_recorded_to_string
           (Keeper_turn_log_recorder.Tail_unread error))
  in
  match
    Keeper_turn_log_store.append ~path:(log_path config) ~at_end:rows_end
      ( Keeper_turn_log.Reset
          { at = 3.0
          ; cause = Keeper_turn_log.Unannounced
          ; before = mark
          ; after = mark
          ; closed_before = []
          }
      , [] )
  with
  | Ok (_ : Keeper_turn_log_store.appended) -> ()
  | Error error ->
    fail
      (Keeper_turn_log_recorder.not_recorded_to_string
         (Keeper_turn_log_recorder.Not_appended error))
;;

let starts config messages = Driver.turn_starts ~config ~keeper_name ~trace_id ~messages
let turn_start config messages = (starts config messages).Driver.boundary
let this_turn config messages = (starts config messages).Driver.this_turn

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

let test_the_open_turn_baseline_is_where_this_turn_began =
  with_workspace
  @@ fun ~config ->
  start config ~trace_id ~closed_messages:(List.length completed);
  open_turn config ~trace_id ~closed_messages:(List.length (completed @ failed));
  check_boundary "the boundary stays at the last unit's end"
    (snd (Window.annotate completed))
    (turn_start config resumed);
  check (option int) "this turn began after the failed turn's messages"
    (Some (snd (Window.annotate (completed @ failed))))
    (this_turn config resumed)
;;

let test_a_rewritten_closed_message_keeps_where_this_turn_began =
  with_workspace
  @@ fun ~config ->
  start config ~trace_id ~closed_messages:(List.length completed);
  open_turn config ~trace_id ~closed_messages:(List.length (completed @ failed));
  let rewritten =
    [ text T.User "Rebuild the patch."; text T.Assistant "The rebuild passed." ]
    @ failed
    @ [ text T.User "Ship it again." ]
  in
  check (option int) "a purge that rewrites closed messages keeps their number"
    (Some (snd (Window.annotate (completed @ failed))))
    (this_turn config rewritten)
;;

let test_no_open_turn_names_no_start =
  with_workspace
  @@ fun ~config ->
  check (option int) "a log with no line names where no turn began" None (this_turn config history);
  start config ~trace_id ~closed_messages:(List.length completed);
  check (option int) "a log with no open turn names where no turn began" None
    (this_turn config history)
;;

let test_an_open_turn_of_another_trace_names_no_start =
  with_workspace
  @@ fun ~config ->
  start config ~trace_id ~closed_messages:(List.length completed);
  open_turn config ~trace_id:"another-trace" ~closed_messages:(List.length completed);
  check (option int) "a baseline of another trace names no start here" None
    (this_turn config resumed)
;;

let test_a_history_shorter_than_the_baseline_names_no_start =
  with_workspace
  @@ fun ~config ->
  start config ~trace_id ~closed_messages:(List.length completed);
  open_turn config ~trace_id ~closed_messages:(List.length resumed + 1);
  check (option int) "a history that lost closed messages names no start" None
    (this_turn config resumed)
;;

let test_a_reset_after_the_open_turn_names_no_start =
  with_workspace
  @@ fun ~config ->
  start config ~trace_id ~closed_messages:(List.length completed);
  open_turn config ~trace_id ~closed_messages:(List.length (completed @ failed));
  reset_after_open config;
  check (option int) "a baseline of the history a reset replaced names no start" None
    (this_turn config resumed)
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
    ; ( "where this turn began"
      , [ test_case "the open turn's baseline is where this turn began" `Quick
            test_the_open_turn_baseline_is_where_this_turn_began
        ; test_case "a rewritten closed message keeps where this turn began" `Quick
            test_a_rewritten_closed_message_keeps_where_this_turn_began
        ; test_case "no open turn names no start" `Quick test_no_open_turn_names_no_start
        ; test_case "an open turn of another trace names no start" `Quick
            test_an_open_turn_of_another_trace_names_no_start
        ; test_case "a history shorter than the baseline names no start" `Quick
            test_a_history_shorter_than_the_baseline_names_no_start
        ; test_case "a reset after the open turn names no start" `Quick
            test_a_reset_after_the_open_turn_names_no_start
        ] )
    ]
;;
