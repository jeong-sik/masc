(* Feed real adapter callbacks through the same bridge, journal codec, server
   SSE projection and TUI decoder used by direct and autonomous chat. *)
module E = Masc.Keeper_chat_events
module Bridge = Masc.Keeper_chat_agent_core_stream_bridge
module Accum = Masc.Keeper_stream_tool_accum
module Journal = Masc.Keeper_chat_event_log
module Projection = Server_keeper_chat_agui_projection
module Live = Masc_tui_keeper_chat_live
module Log = Masc_tui_keeper_chat_log
module Transcript = Masc_tui_keeper_chat_transcript

type t = {
  accum : Accum.t;
  mutable bridge : Bridge.state;
  mutable reversed : E.keeper_chat_event list;
}

let create () =
  {accum=Accum.create (); bridge=Bridge.empty_state ();
   reversed=[E.Text_message_start {message_id="outer"; role=E.Assistant};
             E.Run_started {run_id="native-outcome"; thread_id="keeper:fixture"}]}

let apply t (translated : Bridge.translated_event) =
  t.bridge <- translated.bridge_state;
  t.reversed <- List.rev_append translated.chat_events t.reversed

let on_event t event =
  Accum.on_event t.accum event;
  apply t (Bridge.translate ~redact_text:Fun.id ~base_dir:"/unused-no-media"
    ~stream_scope:(Accum.current_stream_scope t.accum) t.bridge event)

let on_completion t ~block_index ~tool_call_id completion =
  apply t (Bridge.finish_native_tool ~redact_text:Fun.id
    ~stream_scope:(Accum.current_stream_scope t.accum) ~block_index ~tool_call_id
    completion t.bridge)

let events t = List.rev t.reversed

let check t ~expected =
  let open Alcotest in
  let events = events t in
  let reports = List.filter_map (function E.Native_tool_end (_, report) -> Some report | _ -> None) events in
  let completion = testable
    (fun formatter value -> Format.pp_print_string formatter
      (Yojson.Safe.to_string (Runtime_native_tools.completion_to_json value))) (=) in
  check (list completion) "one ordered native report per occurrence" expected reports;
  check bool "native completion is not a MASC execution receipt" false
    (List.exists (function E.Tool_result_ready _ -> true | _ -> false) events);
  check bool "valid provider observation has no bridge error" false
    (List.exists (function E.Agent_core_stream_protocol_error _ -> true | _ -> false) events);
  let lines = List.mapi (fun seq event ->
    let line : Journal.journaled_event = {seq; ts=1000. +. float_of_int seq; event} in
    match Journal.journaled_event_of_json (Journal.journaled_event_to_json line) with
    | Ok decoded -> decoded | Error detail -> fail detail) events in
  let _, wire = List.fold_left (fun (state, wire) (line : Journal.journaled_event) ->
    let state, projected = Projection.project ~timestamp:line.ts
      ~redact_text:Fun.id ~redact_json:Fun.id state line.event in
    state, wire ^ Option.fold ~none:"" ~some:(Ag_ui.event_to_sse ~id:line.seq) projected)
    (Projection.initial, "") lines in
  let live = Log.create ~keeper_name:"fixture" ~request_id:"native-outcome" ~started_at:1000.
  and replay = Log.create ~keeper_name:"fixture" ~request_id:"native-outcome" ~started_at:1000. in
  Live.feed (Live.create ()) wire |> List.iter (fun (item : Live.observed_delta) ->
    ignore (Log.add ?at:item.at live ~seq:item.seq item.delta));
  ignore (Log.add_journaled replay lines);
  let calls log =
    let transcript = Transcript.of_log ~now:2000. log in
    check bool "wire/replay decodes without unreadable data" true (Option.is_none (Transcript.unreadable transcript));
    Transcript.tool_calls transcript in
  let live_calls = calls live and replay_calls = calls replay in
  check bool "live and journal preserve the same native activity" true (live_calls=replay_calls);
  check (list (option completion)) "TUI retains every provider report" (List.map Option.some expected)
    (List.map (fun (call : Transcript.tool_activity) -> call.native_completion) live_calls);
  List.iter (fun (call : Transcript.tool_activity) ->
    (* A report that says the step failed reads as Native_failed and every
       other as Native_ended. Neither becomes a MASC result or failure. *)
    check bool "provider report stays a native observation" true
      (match call.outcome with
       | Transcript.Native_ended | Transcript.Native_failed -> true
       | Transcript.Started | Transcript.Awaiting_result | Transcript.Returned
       | Transcript.Native_running | Transcript.Failed | Transcript.Never_returned
       | Transcript.Outcome_unrecorded -> false);
    check (option string) "no invented execution identity" None call.execution_id) live_calls;
  List.iter (fun mode ->
    let projection = Transcript.project_tool_block mode (Transcript.tool_block live_calls) in
    let displayed = String.concat "\n" (Option.to_list projection.header @ projection.details) in
    List.iter (fun report ->
      check bool "provider outcome and exit code remain visible" true
        (Astring.String.is_infix ~affix:(Transcript.native_completion_summary report) displayed)) expected)
    [Transcript.Compact; Transcript.Full]
