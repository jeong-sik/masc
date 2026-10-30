open Alcotest
open Masc
module L = Keeper_librarian
module C = Keeper_librarian_context
module T = Agent_core.Types
module Capture = Keeper_librarian_input_capture

(* History in these fixtures holds media by reference; every agent, runtime
   config and projector here reads the bytes back from this store. *)
let test_media_store = Agent_core.History.Memory_store.create ()

let stored_source ~media_type raw =
  match test_media_store.put ~media_type ~raw with
  | Ok stored -> Agent_core.Types.Stored stored
  | Error error -> failwith (Agent_core.Error.to_string (Agent_core.Error.Media error))

let get = function Ok value -> value | Error detail -> fail detail
let reference = Ids.Turn_ref.make ~trace_id:"original-input" ~absolute_turn:7
let criterion = Goal_store.Criterion {revision="original-criterion";title="Retain every input";
  metric=Some "original fields";target_value=Some "all"}
let fact claim = Keeper_memory_os_types.observed ~claim ~category:Keeper_memory_os_types.Fact
  ~now:100. ~origin:{kind=Keeper_memory_os_types.Authored;trace_id="original-input"}
let source reference : C.source = {reference;content=`Assoc ["z",`Int 2;"a",`String "original"]}
let input () : L.input =
  let pockets : C.pocket list = [{id="original-pocket";merge_contexts=["earlier-b";"earlier-a"];
    sources=["source-b";"source-a"];context="Preserve this source order";
    next_steps=["Read the complete response";"Check its receipt"];completeness=C.Needs_reconsideration}] in
  let prior : C.snapshot = {generation="original-generation";revision=9;
    execution_basis=Some "original-progress";sources=[source "source-b";source "source-a"];pockets} in
  let nested : T.content_block = T.ToolResult {tool_use_id="nested-tool";content="null";
    outcome=T.Tool_succeeded;json=Some `Null;content_blocks=Some []} in
  let blocks : T.content_block list = [
    T.Text "Original \255 bytes";
    T.Thinking {content="unsigned \255 reasoning";signature=None};
    T.Thinking {content="signed reasoning";signature=Some "exact-signature"};
    T.ReasoningDetails {reasoning_content=Some "original reasoning";
      details=[{raw=`Assoc ["text",`String "raw text";"other",`Bool true];text=Some "typed text differs"}]};
    T.RedactedThinking "opaque-redaction";
    T.ToolUse {id="original-tool";name="browser_read";input=`Assoc ["z",`Int 2;"a",`Int 1]};
    T.ToolResult {tool_use_id="original-tool";content="Original failed tool response";
      outcome=T.Tool_failed {failure_kind=T.Recoverable_tool_error;error_class=Some T.Transient};
      json=Some (`Assoc ["z",`String "structured";"a",`List [`Int 1;`Null]]);
      content_blocks=Some [nested;T.ToolResult {tool_use_id="without-json";content="null";
        outcome=T.Tool_succeeded;json=None;content_blocks=None}]};
    T.Image {media_type="image/png";source=(stored_source ~media_type:"image/png" "original-image")};
    T.Document {media_type="application/pdf";source=T.File_id "original-file"};
    T.Audio {media_type="audio/wav";source=T.Url "https://example.test/audio"}] in
  let metadata = [T.Input_speaker.key,`Assoc ["actor",`String "first"];
    "other",`Assoc ["z",`Int 1;"a",`Int 2];
    T.Input_speaker.key,`Assoc ["actor",`String "second"]] in
  {L.turn_ref=reference;keeper_id=Masc_test_deps.keeper_id_fixture "capture-owner";
    keeper_instructions="Original Keeper instructions";
    goal_context=L.Task_goals {task_id="task-original";
      criteria=Ok ["goal-original",Goal_phase.Paused Goal_phase.Resume_verifying,criterion]};
    historical_task_contexts=[
      {Keeper_librarian_task_context.scope={source=Atom_span {trace_id="original-input";start_atom=2;end_atom=5};
        attribution=Observed {turn_ref=reference;task_context=Keeper_turn_task_context.Task_source_unavailable "original read failure"}};
        first_message=0;after_message=1;first_tool_observation=0;after_tool_observation=1};
      {scope={source=Official_turn;attribution=Unattributed};first_message=1;after_message=2;
        first_tool_observation=1;after_tool_observation=2};
      {scope={source=Boundary_only;attribution=Observed {turn_ref=reference;
        task_context=Keeper_turn_task_context.Admission_not_recorded}};
        first_message=2;after_message=2;first_tool_observation=2;after_tool_observation=2}];
    current=Some {L.facts=[fact "Second in lexical order";fact "First in lexical order"]};
    working_context={C.sources=[source "current-b";source "current-a"];previous=Some prior;
      unavailable=["source unavailable";"another source unavailable"];execution_basis=Some "current-progress"};
    messages=List.map (fun role -> { origin = Llm_provider.Types.Conversation; T.role;content=blocks;name=Some "original-name";
      tool_call_id=Some "original-call";metadata}) [T.User;T.Assistant;T.Tool;T.System];
    tool_observations=[{L.tool_name="browser_read";outcome=L.Succeeded};
      {tool_name="browser_click";outcome=L.Failed};{tool_name="browser_drag";outcome=L.Unknown}];
    counterpart_observations=[{Keeper_counterpart_observation.origin=Connector_attention;
      channel="original-channel";workspace_id=Some "original-workspace";user_id=Some "original-user";
      user_name=Some "Original speaker";authority=External;content="Untrusted original content"};
      {origin=Durable_chat;channel="direct";workspace_id=None;user_id=None;user_name=None;
       authority=Owner;content="Original owner content"};
      {origin=Durable_chat;channel="agent";workspace_id=None;user_id=Some "other-keeper";
       user_name=None;authority=Keeper;content="Original Keeper content"}]}

let reread original =
  let path=Filename.temp_file "librarian-complete-input-" ".json" in
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () ->
    let bytes=Yojson.Safe.to_string (Capture.to_json original) in
    Out_channel.with_open_bin path (fun channel -> output_string channel bytes);
    Capture.of_json (Yojson.Safe.from_file path) |> get)

let test_complete_original () =
  let original=input () in
  let restored=reread original in
  check bool "every original typed field survives disk and decode" true (original=restored);
  let first=List.hd restored.messages in
  check bool "duplicate host attribution stays duplicate" true
    (match T.Input_speaker.classify first.metadata with T.Input_speaker.Duplicate -> true
     | Absent | Present _ -> false);
  check bool "raw metadata order is preserved" true (first.metadata=(List.hd original.messages).metadata);
  check bool "original context and absorption projections stay unchanged" true
    (L.observations_for_absorption original=L.observations_for_absorption restored
     && C.prompt_json original.working_context=C.prompt_json restored.working_context)

let test_typed_origin_roundtrip () =
  let original = input () in
  let origins = T.[Conversation;System_context;Historical_system_context;
    Recovery_instruction;Tool_result_followup;Agent_instruction] in
  let messages = List.map (fun origin ->
    { (List.hd original.messages) with T.origin;
      metadata=["agent_core.extra_system_context.v1",`String "historical";
        "masc.librarian_working_state.v1",`Bool true] }) origins in
  let restored = reread {original with messages} in
  check bool "current explicit origins survive disk despite conflicting metadata" true
    (List.map (fun (message:T.message) -> message.origin) restored.messages = origins)

let test_origin_is_required_and_closed () =
  let original = input () in
  let first = List.hd original.messages in
  let base = match Capture.message_json first with
    | `Assoc fields -> List.remove_assoc "origin" fields
    | _ -> fail "message must be an object" in
  let malformed = [ `Assoc base;
    `Assoc (("origin",`Null)::base);
    `Assoc (("origin",`String "invented-origin")::base);
    `Assoc (("origin",`String "conversation")::("origin",`String "system_context")::base) ] in
  List.iter (fun message ->
    check bool "message decoder refuses absent duplicate null or unknown origin" true
      (Result.is_error (Capture.message_of_json message));
    let retained = match Capture.to_json original with
      | `Assoc fields -> `Assoc (("messages",`List [message])::List.remove_assoc "messages" fields)
      | _ -> fail "input must be an object" in
    check bool "complete input decoder cannot rescue origin with metadata" true
      (Result.is_error (Capture.of_json retained))) malformed

let test_absence_and_failure () =
  let original=input () in
  List.iter (fun goal_context ->
    let original={original with L.goal_context;current=None;messages=[];tool_observations=[];
      historical_task_contexts=[];working_context=C.empty;counterpart_observations=[]} in
    check bool "absence and failed authority reads remain distinct" true (reread original=original))
    [L.No_task;L.Task_goals {task_id="task-original";criteria=Ok []};
     L.Task_goals {task_id="task-original";criteria=Error "original Goal store unavailable"}]

let test_refused_envelope () =
  let json=Capture.to_json (input ()) in
  let fields=match json with `Assoc fields -> fields | _ -> fail "input must be an object" in
  List.iter (fun malformed -> check bool "malformed typed envelopes never default" true
    (Result.is_error (Capture.of_json malformed)))
    [`Assoc (("keeper_id",`String "different")::fields);
     `Assoc (List.remove_assoc "messages" fields);
     `Assoc (("unexpected",`Bool true)::fields);
     `Assoc (("tool_observations",`List [`Assoc ["tool_name",`String "browser_read";
       "outcome",`String "invented"]])::List.remove_assoc "tool_observations" fields)]

let () = run "Original Librarian input retention" ["retention",[
  test_case "complete original survives restart with nested tool payloads and provenance" `Quick test_complete_original;
  test_case "all typed origins survive disk without metadata inference" `Quick test_typed_origin_roundtrip;
  test_case "origin is required and closed in retained messages and complete inputs" `Quick test_origin_is_required_and_closed;
  test_case "unavailable authority is distinct from no Task or empty goals" `Quick test_absence_and_failure;
  test_case "malformed retained envelopes refuse without defaults" `Quick test_refused_envelope]]
