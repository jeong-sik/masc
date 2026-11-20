(* Where a Keeper's latest request starts, against the Memory writer's read
   end (RFC librarian-call-only-proposes §11.3, §12.2 W2). Both are counts of
   the checkpoint history's messages. They compare only on one trace, with no
   [Reset] line of the turn log between the two, and the lines between are
   the ones written after the older of the two. *)

open Alcotest
open Masc
module T = Agent_core.Types
module Start = Keeper_request_start
module Point = Keeper_covered_point
module Log = Keeper_turn_log
module Store = Keeper_turn_log_store

let trace_id = "request-start-trace"
let keeper_name = "request-start-keeper"
let text role body = T.make_message ~role [ T.Text body ]

let exchanges =
  [ text T.User "ask 0"; text T.Assistant "answer 0"; text T.User "ask 1"; text T.Assistant "answer 1" ]
;;

let test_it_counts_the_messages_of_the_atoms_left_out () =
  check int "a request that carries every atom sends from the first message" 0
    (Start.sends_from exchanges ~first_atom:0);
  check int "one that opens at atom 2 leaves out two messages" 2
    (Start.sends_from exchanges ~first_atom:2);
  check int "one past every atom leaves out the whole history" 4
    (Start.sends_from exchanges ~first_atom:4)
;;

let test_a_tool_result_goes_with_its_atom () =
  let call = "call-0" in
  let history =
    [ text T.User "ask 0"
    ; T.make_message ~role:T.Assistant
        [ T.ToolUse { id = call; name = "fixture_tool"; input = `Assoc [] } ]
    ; T.make_message ~role:T.Tool ~tool_call_id:call
        [ T.ToolResult
            { tool_use_id = call
            ; content = "done"
            ; outcome = T.Tool_succeeded
            ; json = None
            ; content_blocks = None
            } ]
    ; text T.User "ask 1"
    ]
  in
  check int "leaving out atom 1 leaves out the result that joined it" 3
    (Start.sends_from history ~first_atom:2)
;;

let test_a_pinned_message_does_not_move_it () =
  let history =
    [ text T.User "ask 0"; text T.Assistant "answer 0"; text T.System "context"; text T.User "ask 1" ]
  in
  check int "the pinned message rides the request, so nothing after atom 1 stays home" 2
    (Start.sends_from history ~first_atom:2);
  check int "past every atom" 4 (Start.sends_from history ~first_atom:3)
;;

let mark ?(trace = trace_id) closed_messages : Log.mark =
  { trace
  ; closed_messages
  ; session = "request-start-session"
  ; history_bytes = 0
  ; internal_bytes = 0
  ; chat_bytes = 0
  ; external_rows = 0
  }
;;

let view ?trace ?(within = Librarian_log.Whole) ~line closed_messages : Librarian_writer.view =
  { covers_through = Librarian_log.Through { line; within }
  ; covered = mark ?trace closed_messages
  ; working_state = None
  }
;;

let start ?(log_end = Start.Ended_at 100) sends_from : Start.t = { trace_id; sends_from; log_end }

let standing_label = function
  | Start.Unknown_until_next_request -> "unknown until the next request"
  | Start.View_unavailable -> "no view"
  | Start.No_read_end -> "no read end"
  | Start.Not_behind { sends_from; read_end } ->
    Printf.sprintf "not behind: sends from %d, read to %d" sends_from read_end
  | Start.Behind { sends_from; read_end } ->
    Printf.sprintf "behind: sends from %d, read to %d" sends_from read_end
  | Start.Not_comparable Start.Other_trace -> "not comparable: another trace"
  | Start.Not_comparable (Start.Reset_between { offset }) ->
    Printf.sprintf "not comparable: a reset at byte %d" offset
  | Start.Not_comparable Start.Log_end_unread -> "not comparable: the log end was not read"
  | Start.Not_comparable Start.Lines_unread -> "not comparable: the lines were not read"
;;

let lines_label = function
  | Start.From_read_unit { line; within = Librarian_log.Whole } ->
    Printf.sprintf "from the read unit at %d" line
  | Start.From_read_unit { line; within = Librarian_log.Item (_ : Librarian_unit.item_name) } ->
    Printf.sprintf "from the part-read unit at %d" line
  | Start.From_request { log_end } -> Printf.sprintf "from the request at %d" log_end
;;

let no_reset (_ : Start.lines) = Point.No_reset

(* The trace, the read end and the log end decide these before any line. *)
let not_asked (lines : Start.lines) : Point.unread_lines =
  fail ("the turn log was read " ^ lines_label lines)
;;

let compared ?(lines_since = no_reset) start view =
  standing_label (Start.of_view ~lines_since start view)
;;

let test_a_start_at_the_read_end_is_not_behind () =
  check string "the request sends from where the writer read to" "not behind: sends from 6, read to 6"
    (compared (start 6) (view ~line:10 6));
  check string "or from before it" "not behind: sends from 4, read to 6"
    (compared (start 4) (view ~line:10 6))
;;

let test_a_start_past_the_read_end_is_behind () =
  check string "the messages from 6 to 8 are in neither" "behind: sends from 8, read to 6"
    (compared (start 8) (view ~line:10 6))
;;

let test_a_writer_that_read_nothing_has_no_read_end () =
  let nothing_read : Librarian_writer.view =
    { covers_through = Librarian_log.Before_first; covered = mark 0; working_state = None }
  in
  check string "no request starts past a read end that is not there" "no read end"
    (compared ~lines_since:not_asked (start 8) nothing_read)
;;

let test_another_trace_is_not_comparable () =
  check string "the counts are of two histories" "not comparable: another trace"
    (compared ~lines_since:not_asked (start 8) (view ~trace:"other-trace" ~line:10 6))
;;

let test_an_unread_log_end_is_not_comparable () =
  check string "which lines lie between is not known" "not comparable: the log end was not read"
    (compared ~lines_since:not_asked (start ~log_end:Start.Unread 8) (view ~line:10 6))
;;

let test_the_lines_between_follow_which_came_first () =
  let asked = ref [] in
  let lines_since lines =
    asked := lines_label lines :: !asked;
    Point.No_reset
  in
  let ask line within =
    let (_ : string) = compared ~lines_since (start 6) (view ~within ~line 6) in
    ()
  in
  ask 40 Librarian_log.Whole;
  ask 40 (Librarian_log.Item { store = Librarian_unit.Agent_core; at = 0 });
  ask 100 Librarian_log.Whole;
  ask 140 Librarian_log.Whole;
  check (list string) "a read unit before the request, then lines after the request"
    [ "from the read unit at 40"
    ; "from the part-read unit at 40"
    ; "from the request at 100"
    ; "from the request at 100"
    ]
    (List.rev !asked)
;;

let test_a_reset_between_is_not_comparable () =
  check string "the count started again between them" "not comparable: a reset at byte 70"
    (compared
       ~lines_since:(fun (_ : Start.lines) -> Point.Reset_at { offset = 70 })
       (start 8) (view ~line:10 6));
  check string "lines that cannot be read decide nothing" "not comparable: the lines were not read"
    (compared
       ~lines_since:(fun (_ : Start.lines) -> Point.Not_scanned { detail = "fixture" })
       (start 8) (view ~line:10 6))
;;

let log_mark closed_messages = mark closed_messages
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

let reset ~before ~after =
  Log.Reset
    { at = 103.0
    ; cause = Log.Announced Log.Cleared
    ; before = log_mark before
    ; after = log_mark after
    ; closed_before = []
    }
;;

(* A turn log of [lines] after its first line, the byte each starts at, and
   where the log ends. *)
let turn_log lines =
  let path =
    Store.path_for_keepers_dir ~keepers_dir:(Filename.temp_dir "request-start" "") ~keeper_id:keeper_name
  in
  let append at_end line =
    match Store.append ~path ~at_end (line, []) with
    | Ok (appended : Store.appended) -> appended
    | Error (_ : Store.append_error) -> fail "the fixture turn log was not written"
  in
  let first = append 0 started in
  let log_end, offsets =
    List.fold_left
      (fun (at_end, offsets) line ->
         let appended = append at_end line in
         appended.Store.new_end, appended.Store.last_at :: offsets)
      (first.Store.new_end, [])
      lines
  in
  path, List.rev offsets, log_end
;;

let unread_label = function
  | Point.No_reset -> "no reset"
  | Point.Reset_at { offset } -> Printf.sprintf "reset at %d" offset
  | Point.Not_scanned { detail = (_ : string) } -> "not scanned"
;;

let test_resets_are_found_from_the_given_line () =
  let turns_path, offsets, log_end =
    turn_log [ opened 0; closed ~turn:0 2; reset ~before:2 ~after:0; opened 0 ]
  in
  let from offset = unread_label (Start.resets_from ~turns_path ~from:offset) in
  check string "a reset after the line" (Printf.sprintf "reset at %d" (List.nth offsets 2))
    (from (List.nth offsets 0));
  check string "the reset's own line" (Printf.sprintf "reset at %d" (List.nth offsets 2))
    (from (List.nth offsets 2));
  check string "past it" "no reset" (from (List.nth offsets 3));
  check string "at the end of the log" "no reset" (from log_end);
  check string "a byte inside a line starts none" "not scanned" (from (List.nth offsets 1 + 1))
;;

let with_workspace body =
  let base = Filename.temp_dir "request-start-workspace" "" in
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Fun.protect ~finally:Fs_compat.clear_fs
  @@ fun () ->
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base)
  @@ fun () -> body (Workspace.default_config base)
;;

let test_the_log_end_is_where_the_turn_log_ends () =
  with_workspace
  @@ fun config ->
  (match Start.of_request ~config ~keeper_name ~trace_id ~sends_from:3 with
   | { log_end = Start.Ended_at 0; sends_from = 3; trace_id = start_trace } ->
     check string "the start names its trace" trace_id start_trace
   | { log_end = Start.Ended_at (_ : int) | Start.Unread; _ } ->
     fail "a Keeper with no turn log ends its log at byte 0");
  Masc_test_deps.start_turn_log
    ~keepers_dir:(Workspace.keepers_runtime_dir config)
    ~keeper_name ~trace_id ~closed_messages:0;
  let rows_end =
    match
      Store.read_tail
        (Store.path_for_keepers_dir
           ~keepers_dir:(Workspace.keepers_runtime_dir config)
           ~keeper_id:keeper_name)
    with
    | Ok (Store.Written { rows_end; _ }) -> rows_end
    | Ok Store.Nothing_written | Error (_ : Store.read_error) -> fail "the fixture log has no line"
  in
  match Start.of_request ~config ~keeper_name ~trace_id ~sends_from:3 with
  | { log_end = Start.Ended_at log_end; _ } -> check int "past its last line" rows_end log_end
  | { log_end = Start.Unread; _ } -> fail "a readable turn log was not read"
;;

let test_the_latest_start_is_kept_until_the_next () =
  with_workspace
  @@ fun config ->
  check string "before any request" "unknown until the next request"
    (standing_label (Start.standing ~config ~keeper_name));
  Start.record ~config ~keeper_name (start 4);
  Start.record ~config ~keeper_name (start 6);
  (match Start.latest ~config ~keeper_name with
   | Some { sends_from; _ } -> check int "the next request overwrites the start" 6 sends_from
   | None -> fail "the recorded start is gone");
  check string "a workspace that started no writer has no view" "no view"
    (standing_label (Start.standing ~config ~keeper_name));
  Start.forget ~config ~keeper_name;
  check string "a forgotten Keeper has no start" "unknown until the next request"
    (standing_label (Start.standing ~config ~keeper_name))
;;

let () =
  run "keeper_request_start"
    [ ( "where a request starts"
      , [ test_case "it counts the messages of the atoms left out" `Quick
            test_it_counts_the_messages_of_the_atoms_left_out
        ; test_case "a tool result goes with its atom" `Quick test_a_tool_result_goes_with_its_atom
        ; test_case "a pinned message does not move it" `Quick test_a_pinned_message_does_not_move_it
        ] )
    ; ( "against the read end"
      , [ test_case "a start at the read end is not behind" `Quick
            test_a_start_at_the_read_end_is_not_behind
        ; test_case "a start past the read end is behind" `Quick
            test_a_start_past_the_read_end_is_behind
        ; test_case "a writer that read nothing has no read end" `Quick
            test_a_writer_that_read_nothing_has_no_read_end
        ; test_case "another trace is not comparable" `Quick test_another_trace_is_not_comparable
        ; test_case "an unread log end is not comparable" `Quick
            test_an_unread_log_end_is_not_comparable
        ; test_case "the lines between follow which came first" `Quick
            test_the_lines_between_follow_which_came_first
        ; test_case "a reset between is not comparable" `Quick test_a_reset_between_is_not_comparable
        ] )
    ; ( "turn log"
      , [ test_case "resets are found from the given line" `Quick
            test_resets_are_found_from_the_given_line
        ; test_case "the log end is where the turn log ends" `Quick
            test_the_log_end_is_where_the_turn_log_ends
        ] )
    ; ( "kept in memory"
      , [ test_case "the latest start is kept until the next" `Quick
            test_the_latest_start_is_kept_until_the_next
        ] )
    ]
;;
