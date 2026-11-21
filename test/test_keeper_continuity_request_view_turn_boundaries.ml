open Alcotest

module Snapshot = Masc.Librarian_continuity_snapshot
module Boundary = Masc.Keeper_turn_boundaries
module Window = Runtime_model_input_tail_window
module T = Agent_core.Types

let trace_id = "continuity-request"
let message role content = T.make_message ~role content
let text role body = message role [T.Text body]
let pinned = text T.System "Do not publish without approval."
let source = [pinned; text T.User "Build the patch."; text T.Assistant "The build passed."]

(* The boundary log's one completed turn over [source]. *)
let boundary_lines source =
  let position = match Boundary.position_of_messages source with
    | Ok position -> position | Error detail -> fail detail in
  [1, Ok { Boundary.recorded_at = 1.; event = Boundary.Turn_ended
    { task_context = Masc.Keeper_turn_task_context.No_task; turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn:1;
      history_at_start = Boundary.Fresh_history; position } }]
;;

let exchange id body =
  [message T.Assistant [T.ToolUse {id; name = "read_file"; input = `Assoc []}];
   { (message T.Tool [T.ToolResult {tool_use_id = id; content = body;
       outcome = T.Tool_succeeded; json = None; content_blocks = None}]) with tool_call_id = Some id }]
;;

let test_completed_boundary_protects_resumed_work () =
  let completed = source @ exchange "completed" (String.make 8000 'd') in
  let lines = boundary_lines completed in
  let resumed = completed @ [text T.User "Still awaiting approval"]
    @ exchange "resumed-unfinished" (String.make 8000 'u') in
  let endpoint = snd (Window.annotate completed) in
  let completed_end lines messages =
    Snapshot.checkpoint_prefix_range ~trace_id ~lines ~messages
    |> Result.map (fun (range : Masc.Keeper_librarian_range.range) -> range.end_atom) in
  check bool "seed can contain resumed work beyond completed boundary" true
    (snd (Window.annotate resumed) > endpoint);
  check bool "typed completed endpoint excludes all resumed work" true
    (completed_end lines resumed = Ok endpoint);
  check bool "absence of source evidence never guesses seed length" true
    (completed_end [] resumed = Error Snapshot.Uncovered_history);
  let restarted = lines @ [2, Ok { Boundary.recorded_at = 2.;
    event = Boundary.History_restarted {trace_id} }] in
  check bool "restart invalidates older completed endpoint" true
    (completed_end restarted resumed = Error Snapshot.Uncovered_history);
  let mismatched = List.map (fun (m : T.message) ->
    match m.content with
    | [T.ToolUse fields] when fields.id = "completed" ->
      {m with content = [T.ToolUse {fields with id = "changed"}]}
    | _ -> m) resumed in
  check bool "mismatching completed atom is an unmatched history, not the start" true
    (completed_end lines mismatched = Error Snapshot.Unmatched_history);
  let baseline = List.map (fun (line, record) -> line,
    Result.map (fun (record : Boundary.record) ->
      match record.event with
      | Boundary.Turn_ended fields ->
        {record with event = Boundary.Turn_ended {fields with history_at_start = Boundary.Continued_history}}
      | _ -> record) record) lines in
  check bool "verified baseline endpoint can externalize exact older bodies" true
    (completed_end baseline resumed = Ok endpoint)
;;

let () = run "keeper_continuity_request_view_turn_boundaries"
  ["request", [test_case "completed boundary protects resumed work" `Quick test_completed_boundary_protects_resumed_work]]
