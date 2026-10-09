open Alcotest
module F = Native_tool_outcome_fixture
module E = Masc.Keeper_chat_events
module Native = Runtime_native_tools
module Journal = Masc.Keeper_chat_event_log
module Bridge = Masc.Keeper_chat_agent_core_stream_bridge
module Live = Masc_tui_keeper_chat_live
module Transcript = Masc_tui_keeper_chat_transcript

let start f ~native ~index ~id =
  F.on_event f (Agent_core.Types.ContentBlockStart
    {index; content_type=(if native then Native.stream_content_type else "tool_use");
     tool_id=id; tool_name=Some "Read"})

let open_message f =
  F.on_event f (Agent_core.Types.MessageStart {id="provider-response"; model="fixture"; usage=None})

let test_unknown_end_and_duplicate_stop () =
  let f = F.create () in
  open_message f;
  start f ~native:true ~index:1 ~id:None;
  F.on_event f (Agent_core.Types.ContentBlockStop {index=1});
  F.on_event f (Agent_core.Types.ContentBlockStop {index=1});
  start f ~native:true ~index:2 ~id:(Some "native-2");
  let report = {Native.outcome=Error_reported; exit_code=Some 9} in
  F.on_completion f ~block_index:2 ~tool_call_id:(Some "native-2") report;
  F.on_completion f ~block_index:2 ~tool_call_id:(Some "native-2") report;
  F.on_event f (Agent_core.Types.ContentBlockStop {index=2});
  F.check f ~expected:[Native.end_observed; report]

let test_compact_keeps_reported_error_visible () =
  let f = F.create () in
  open_message f;
  let reports = [Native.end_observed; Native.end_observed;
    {Native.outcome=Completion_reported; exit_code=Some 3}] in
  List.iteri (fun index report ->
    let id = Some (string_of_int index) in
    start f ~native:true ~index ~id;
    F.on_completion f ~block_index:index ~tool_call_id:id report;
    F.on_event f (Agent_core.Types.ContentBlockStop {index})) reports;
  F.check f ~expected:reports

(* A provider status word containing "failed" must not reach the dresser,
   which would paint a neutral ended call red in the block header. *)
let test_unrecognized_status_word_stays_out_of_dressed_rows () =
  let f = F.create () in
  open_message f;
  let reports = [Native.end_observed;
    {Native.outcome=Unrecognized_status "not_failed"; exit_code=Some 0}; Native.end_observed] in
  List.iteri (fun index report ->
    let id = Some (string_of_int index) in
    start f ~native:true ~index ~id;
    F.on_completion f ~block_index:index ~tool_call_id:id report;
    F.on_event f (Agent_core.Types.ContentBlockStop {index})) reports;
  F.check f ~expected:reports

let test_wrong_identity_cannot_close_or_commit_tool () =
  let f = F.create () in
  open_message f;
  start f ~native:true ~index:1 ~id:(Some "right");
  start f ~native:false ~index:2 ~id:(Some "masc");
  let report = {Native.outcome=Completion_reported; exit_code=Some 0} in
  F.on_completion f ~block_index:1 ~tool_call_id:(Some "wrong") report;
  F.on_completion f ~block_index:2 ~tool_call_id:(Some "masc") report;
  let invalid = F.events f in
  check int "both exact mapping failures observable" 2
    (List.length (List.filter (function E.Agent_core_stream_protocol_error _ -> true | _ -> false) invalid));
  check bool "neither mismatch ended or committed a native/MASC tool" false
    (List.exists (function E.Native_tool_end _ | E.Tool_call_end _ | E.Tool_result_ready _ -> true | _ -> false) invalid);
  F.on_completion f ~block_index:1 ~tool_call_id:(Some "right") report;
  check int "original occurrence still closes" 1
    (List.length (List.filter (function E.Native_tool_end _ -> true | _ -> false) (F.events f)))

let test_old_scope_cannot_close_reused_index () =
  let start scope state id =
    let translated = Bridge.translate ~redact_text:Fun.id ~base_dir:"/unused"
      ~stream_scope:scope state (Agent_core.Types.MessageStart {id; model="fixture"; usage=None}) in
    Bridge.translate ~redact_text:Fun.id ~base_dir:"/unused" ~stream_scope:scope translated.bridge_state
      (Agent_core.Types.ContentBlockStart {index=1; content_type=Native.stream_content_type;
        tool_id=Some "reused"; tool_name=Some "Read"}) in
  let first = start 0 (Bridge.empty_state ()) "first" in
  let second = start 1 first.bridge_state "second" in
  let stale = Bridge.finish_native_tool ~redact_text:Fun.id ~stream_scope:0
    ~block_index:1 ~tool_call_id:(Some "reused") Native.end_observed second.bridge_state in
  check bool "old scope produces no end" false
    (List.exists (function E.Native_tool_end _ -> true | _ -> false) stale.chat_events);
  let current = Bridge.finish_native_tool ~redact_text:Fun.id ~stream_scope:1
    ~block_index:1 ~tool_call_id:(Some "reused") Native.end_observed stale.bridge_state in
  check bool "new exact scope still closes" true
    (List.exists (function E.Native_tool_end (tool, _) -> tool.occurrence.stream_scope=1 | _ -> false)
      current.chat_events)

let test_absent_and_malformed_metadata () =
  let occurrence : E.tool_stream_occurrence = {stream_scope=0; block_index=1; provider_message_id=None} in
  let native : E.native_tool = {occurrence; tool_call_id=None; tool_call_name=None} in
  let ended = E.Native_tool_end (native, Native.end_observed) in
  let json = Journal.keeper_chat_event_to_json ended in
  let fields = match json with `Assoc fields -> fields | _ -> fail "expected object" in
  let replace_completion replacement = function
    | `Assoc fields -> `Assoc (List.remove_assoc "completion" fields
        @ Option.to_list (Option.map (fun value -> "completion",value) replacement))
    | _ -> fail "native event value must be an object" in
  let decode_wire replacement =
    let module Projection = Server_keeper_chat_agui_projection in
    let _, event = Projection.project ~timestamp:1000. ~redact_text:Fun.id
      ~redact_json:(replace_completion replacement) Projection.initial ended in
    match event with
    | None -> fail "native end was not projected"
    | Some event -> Live.feed (Live.create ()) (Ag_ui.event_to_sse ~id:1 event)
        |> List.map (fun (observed : Live.observed_delta) -> observed.delta) in
  let old = `Assoc (List.remove_assoc "completion" fields) in
  check bool "end without result metadata remains unknown" true
    (Journal.keeper_chat_event_of_json old = Ok ended);
  check bool "older SSE end remains unknown" true
    (match decode_wire None with
     | [Live.Native_tool_ended {completion; _}] -> completion=Native.end_observed
     | _ -> false);
  List.iter (fun malformed ->
    check bool "present malformed journal metadata is not unknown/success" true
      (Result.is_error (Journal.keeper_chat_event_of_json
        (replace_completion (Some malformed) json)));
    check bool "malformed SSE metadata is unreadable, never an ended tool" true
      (match decode_wire (Some malformed) with [Live.Undecodable _] -> true | _ -> false))
    [`Null; `Assoc ["kind",`String "success"; "exit_code",`Null];
     `Assoc ["kind",`String "completion_reported"; "exit_code",`String "0"];
     `Assoc ["kind",`String "completion_reported"; "kind",`String "error_reported";
       "exit_code",`Int 0; "exit_code",`Int 17];
     `Assoc ["kind",`String "completion_reported"; "exit_code",`Int 0; "exit_code",`Int 17];
     `Assoc ["kind",`String "result_received"; "exit_code",`Null;
       "is_error",`Bool false; "is_error",`Bool true];
     `Assoc ["kind",`String "end_observed"; "exit_code",`Null; "is_error",`Bool true];
     `Assoc ["kind",`String "result_received"; "exit_code",`Null;
       "is_error",`Null; "status",`String "failed"];
     `Assoc ["kind",`String "unrecognized_status"; "exit_code",`Null;
       "status",`String "future-status"; "is_error",`Bool false]]

let test_http_execution_receipt_is_unchanged () =
  let transcript = Transcript.create ~keeper_name:"fixture" ~request_id:"http" ~started_at:0. in
  let occurrence : Live.tool_occurrence =
    {stream_scope=0; block_index=1; provider_message_id=Some "http-response"; tool_call_id=Some "glm-call"} in
  let feed delta = Transcript.apply ~now:1. transcript delta in
  let call () = match Transcript.tool_calls transcript with [call] -> call | _ -> fail "missing HTTP tool" in
  feed (Live.Tool_started {occurrence;tool_name="Read"});
  feed (Live.Tool_ended {occurrence});
  check bool "HTTP argument stop still awaits execution" true ((call ()).outcome=Transcript.Awaiting_result);
  feed (Live.Tool_result {occurrence;execution_id="execution-1"});
  check bool "durable HTTP receipt still returns" true ((call ()).outcome=Transcript.Returned);
  check (option string) "canonical execution identity retained" (Some "execution-1") (call ()).execution_id;
  check bool "native report is absent" true ((call ()).native_completion=None)

let () = run "native tool outcomes" ["contract", [
  test_case "compact retains reported nonzero exit" `Quick test_compact_keeps_reported_error_visible;
  test_case "unknown end and duplicate stop" `Quick test_unknown_end_and_duplicate_stop;
  test_case "unrecognized status word stays out of dressed rows" `Quick
    test_unrecognized_status_word_stays_out_of_dressed_rows;
  test_case "wrong identities cannot close native/MASC tool" `Quick test_wrong_identity_cannot_close_or_commit_tool;
  test_case "old scope cannot close reused index" `Quick test_old_scope_cannot_close_reused_index;
  test_case "absent and malformed metadata differ" `Quick test_absent_and_malformed_metadata;
  test_case "HTTP execution receipt stays authoritative" `Quick test_http_execution_receipt_is_unchanged]]
