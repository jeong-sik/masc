module Tasks = Runtime_native_tasks
open Tasks

let get = function Ok value -> value | Error detail -> Alcotest.fail detail
let expect_error label = function
  | Error _ -> ()
  | Ok _ -> Alcotest.fail (label ^ " unexpectedly admitted")

let origin =
  { keeper_name="keeper"; source=Operation {operation_id="operation"}
  ; attempt={routing_run_id="routing";runtime_id="claude";lane_attempt_index=1}
  ; invocation={receiver_generation="receiver";session_id="session";client_uuid="input"}
  ; native_call={session_id="session";call_id="call";call_envelope_uuid="assistant";call_ordinal=2}
  ; task_id="task";run_id="run" }

let make ?(origin=origin) event boundary =
  get (Tasks.make ~origin ~uuid:"event" ~event ~boundary)

let registered = Task_registered
  {subagent_type=Some "Explore";is_backgrounded=Some true;skip_transcript=None;ambient=Some false}
let usage = {total_tokens=15;tool_uses=2;duration_ms=35}
let progress = Task_progress_reported {usage;last_tool_name=Some "Read"}
let terminal = Task_terminal_reported
  {outcome=Task_stopped_notice;reason=Some Worker_restart;usage=Some usage;
   skip_transcript=Some true;ambient=None}

let same label expected actual =
  Alcotest.check bool label true (expected=actual)

let rec at path change json = match path,json with
  | [],_ -> change json
  | key::rest, `Assoc fields ->
      `Assoc (List.map (fun (name,value) -> name, if name=key then at rest change value else value) fields)
  | _ -> Alcotest.fail "fixture path does not name an object"

let replace field value = function
  | `Assoc fields -> `Assoc ((field,value)::List.remove_assoc field fields)
  | _ -> Alcotest.fail "fixture expected an object"

let test_lifecycle_roundtrip () =
  (* Terminal evidence is independent of last status and registration supplies
     no status. The codec retains patches, including metadata after sealing. *)
  let lifecycle =
    [registered,Task_terminal_unobserved;
     Task_patched {status=Some Task_running;is_backgrounded=Some true;end_time=None;total_paused_ms=None},Task_terminal_unobserved;
     progress,Task_terminal_unobserved;
     Task_progress_reported {usage={total_tokens=3;tool_uses=0;duration_ms=1};last_tool_name=None},Task_terminal_unobserved;
     terminal,Task_terminal_observed;
     Task_patched {status=None;is_backgrounded=Some false;end_time=Some (-1);total_paused_ms=Some (-2)},Task_terminal_observed] in
  List.iter (fun source ->
    List.iter (fun (event,boundary) ->
      let expected = make ~origin:{origin with source} event boundary in
      let json = Tasks.to_json expected in
      let received = Yojson.Safe.from_string (Yojson.Safe.to_string json) |> Tasks.of_json |> get in
      same "source/owner/event/boundary retained" expected received;
      same "canonical payload" json (Tasks.to_json received)) lifecycle)
    [Operation {operation_id="operation"};Autonomous_turn {turn_ref="trace#3"}];
  List.iter (fun flag ->
    let event=Task_registered {subagent_type=None;is_backgrounded=flag;skip_transcript=flag;ambient=flag} in
    let value=make event Task_terminal_unobserved in
    same "None, false and true stay distinct" value (Tasks.of_json (Tasks.to_json value) |> get))
    [None;Some false;Some true]

let test_numeric_contract () =
  let base=Tasks.to_json (make progress Task_terminal_unobserved) in
  List.iter (fun number ->
    let json=base |> at ["event";"usage"] (replace "total_tokens" number)
      |> at ["origin";"attempt"] (replace "lane_attempt_index" (`Float 1.0))
      |> at ["origin";"native_call"] (replace "call_ordinal" (`Float 2.0)) in
    let value=Tasks.of_json json |> get in
    match value.event with
    | Task_progress_reported {usage;_} -> Alcotest.check int "integer value" 1 usage.total_tokens
    | _ -> Alcotest.fail "progress changed kind") [`Int 1;`Float 1.0;Yojson.Safe.from_string "1e0"];
  List.iter (fun value ->
    let event=Task_progress_reported {usage={total_tokens=value;tool_uses=value;duration_ms=value};last_tool_name=None} in
    let dto=make event Task_terminal_unobserved in
    same "signed provider safe integer" dto (Tasks.of_json (Tasks.to_json dto) |> get))
    [-9_007_199_254_740_991; -1; 0; 9_007_199_254_740_991];
  List.iter (fun bad ->
    expect_error "unsafe provider number" (Tasks.of_json (at ["event";"usage"] (replace "duration_ms" bad) base)))
    [`Int 9_007_199_254_740_992;`Int (-9_007_199_254_740_992);`Float 0.5;`Float infinity;`String "1";`Null];
  expect_error "negative host ordinal"
    (Tasks.of_json (at ["origin";"native_call"] (replace "call_ordinal" (`Int (-1))) base));
  expect_error "make also checks unsafe numbers"
    (Tasks.make ~origin ~uuid:"event" ~event:(Task_progress_reported
      {usage={usage with total_tokens=9_007_199_254_740_992};last_tool_name=None})
      ~boundary:Task_terminal_unobserved)

let test_closed_objects () =
  let base=Tasks.to_json (make progress Task_terminal_unobserved) in
  let objects=[[];["origin"];["origin";"source"];["origin";"attempt"];
    ["origin";"invocation"];["origin";"native_call"];["event"];["event";"usage"]] in
  List.iter (fun path ->
    let duplicate=function `Assoc ((key,value)::rest) -> `Assoc ((key,value)::(key,value)::rest)
      | _ -> Alcotest.fail "nonempty object required" in
    expect_error "duplicate object key" (Tasks.of_json (at path duplicate base));
    expect_error "unknown object key" (Tasks.of_json (at path (replace "unexpected" (`Bool true)) base))) objects;
  List.iter (fun field ->
    expect_error "unowned raw content field" (Tasks.of_json (at ["event"] (replace field (`String "private body")) base)))
    ["prompt";"description";"summary";"error";"output_file"];
  List.iter (fun field ->
    let json=match base with `Assoc fields -> `Assoc (List.remove_assoc field fields) | _ -> assert false in
    expect_error "missing required field" (Tasks.of_json json)) ["schema";"origin";"uuid";"event";"boundary"];
  expect_error "mixed source kinds" (Tasks.of_json (at ["origin";"source"] (replace "turn_ref" (`String "trace#3")) base));
  expect_error "null optional flag" (Tasks.of_json
    (Tasks.to_json (make registered Task_terminal_unobserved) |> at ["event"] (replace "ambient" `Null)));
  expect_error "unknown event kind" (Tasks.of_json (at ["event"] (replace "kind" (`String "heartbeat")) base));
  expect_error "foreign original native session" (Tasks.of_json
    (at ["origin";"native_call"] (replace "session_id" (`String "other-session")) base))

let test_boundaries () =
  List.iter (fun (event,boundary) ->
    expect_error "contradictory event boundary" (Tasks.make ~origin ~uuid:"event" ~event ~boundary))
    [registered,Task_terminal_observed;progress,Task_terminal_observed;terminal,Task_terminal_unobserved;
     Task_patched {status=Some Task_running;is_backgrounded=None;end_time=None;total_paused_ms=None},Task_terminal_observed;
     Task_patched {status=Some Task_failed;is_backgrounded=None;end_time=None;total_paused_ms=None},Task_terminal_unobserved;
     Task_terminal_reported {outcome=Task_completed_notice;reason=Some Worker_restart;usage=None;skip_transcript=None;ambient=None},Task_terminal_observed];
  List.iter (fun status ->
    let boundary=match status with
      | Task_pending | Task_running | Task_paused -> Task_terminal_unobserved
      | Task_completed | Task_failed | Task_killed -> Task_terminal_observed in
    let event=Task_patched {status=Some status;is_backgrounded=None;end_time=None;total_paused_ms=None} in
    let value=make event boundary in
    same "declared status roundtrip" value (Tasks.of_json (Tasks.to_json value) |> get))
    [Task_pending;Task_running;Task_paused;Task_completed;Task_failed;Task_killed];
  List.iter (fun outcome ->
    let event=Task_terminal_reported {outcome;reason=None;usage=None;skip_transcript=None;ambient=None} in
    let value=make event Task_terminal_observed in
    same "terminal report roundtrip" value (Tasks.of_json (Tasks.to_json value) |> get))
    [Task_completed_notice;Task_failed_notice;Task_stopped_notice]

let test_redaction_and_identity () =
  let opaque=" \194\160identity # / " in
  let origin={keeper_name=opaque;source=Autonomous_turn {turn_ref=opaque};
    attempt={routing_run_id=opaque;runtime_id=opaque;lane_attempt_index=0};
    invocation={receiver_generation=opaque;session_id=opaque;client_uuid=opaque};
    native_call={session_id=opaque;call_id=opaque;call_envelope_uuid=opaque;call_ordinal=0};task_id=opaque;run_id=opaque} in
  let value=make ~origin registered Task_terminal_unobserved in
  let redacted=Tasks.redact (fun _ -> "") value in
  same "opaque owner unchanged" value.origin redacted.origin;
  same "observation UUID unchanged" value.uuid redacted.uuid;
  same "metadata can redact to empty" (Task_registered
    {subagent_type=Some "";is_backgrounded=Some true;skip_transcript=None;ambient=Some false}) redacted.event;
  same "redacted DTO remains decodable" redacted (Tasks.of_json (Tasks.to_json redacted) |> get);
  let value=make ~origin progress Task_terminal_unobserved in
  let redacted=Tasks.redact (fun _ -> "[redacted]") value in
  same "only supplied tool label changes" (Task_progress_reported {usage;last_tool_name=Some "[redacted]"}) redacted.event;
  let value=make ~origin terminal Task_terminal_observed in
  same "terminal contains no arbitrary body" value (Tasks.redact (fun _ -> Alcotest.fail "identity redacted") value)

let test_shared_runtime_vocabulary () =
  (* Compile-time equality at the real public boundary, not a copied fixture
     vocabulary. Decoding Tasks.t still cannot construct Claude's private owner. *)
  let event : Runtime_claude_code.native_task_event = registered in
  let boundary : Runtime_claude_code.native_task_boundary = Task_terminal_unobserved in
  same "runtime shares task vocabulary" registered (make event boundary).event

let () = Alcotest.run "native task transport"
  ["codec", [Alcotest.test_case "lifecycle and flags" `Quick test_lifecycle_roundtrip;
    Alcotest.test_case "numeric protocol" `Quick test_numeric_contract;
    Alcotest.test_case "closed objects" `Quick test_closed_objects;
    Alcotest.test_case "terminal boundaries" `Quick test_boundaries;
    Alcotest.test_case "redaction and opaque identity" `Quick test_redaction_and_identity;
    Alcotest.test_case "runtime type identity" `Quick test_shared_runtime_vocabulary]]
