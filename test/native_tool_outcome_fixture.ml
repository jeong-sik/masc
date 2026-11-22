(* Feed real adapter callbacks through the same scoped redactor, bridge, journal codec,
   and server SSE projection used by direct and autonomous chat. *)
module E = Masc.Keeper_chat_events
module Bridge = Masc.Keeper_chat_agent_core_stream_bridge
module Accum = Masc.Keeper_stream_tool_accum
module Redactor = Masc.Keeper_stream_text_redaction.Scoped
module Secret = Masc.Keeper_secret_redaction
module Journal = Masc.Keeper_chat_event_log
module Projection = Server_keeper_chat_agui_projection

type t = {
  accum : Accum.t;
  redact_text : string -> string;
  text : Redactor.t;
  mutable bridge : Bridge.state;
  mutable reversed : E.keeper_chat_event list;
}

let create ?(redaction=Secret.empty) () =
  {redact_text=Secret.redact_text redaction; text=Redactor.create redaction; accum=Accum.create (); bridge=Bridge.empty_state ();
   reversed=[E.Text_message_start {message_id="outer"; role=E.Assistant};
             E.Run_started {run_id="native-outcome"; thread_id="keeper:fixture"}]}

let apply t (translated : Bridge.translated_event) =
  t.bridge <- translated.bridge_state;
  t.reversed <- List.rev_append translated.chat_events t.reversed

let forward t events =
  List.iter (fun (stream_scope,event) ->
    apply t (Bridge.translate ~redact_text:t.redact_text ~base_dir:"/unused-no-media"
      ~stream_scope t.bridge event)) events

(* The same pre-advance accumulator disposition and redaction flush used by
   direct/autonomous runtime-attempt observations. A MessageStart alone cannot
   resurrect a poisoned scope. *)
let start_runtime_attempt t ~runtime_id ~attempt_index =
  forward t (Redactor.flush t.text);
  let previous_scope = Accum.start_runtime_attempt t.accum in
  apply t (Bridge.start_runtime_attempt ~runtime_id ~attempt_index ~previous_scope t.bridge)

let on_event t event =
  Accum.on_event t.accum event;
  forward t (Redactor.on_event t.text ~stream_scope:(Accum.current_stream_scope t.accum) event)

let on_completion t ~block_index ~tool_call_id completion =
  apply t (Bridge.finish_native_tool ~redact_text:t.redact_text
    ~stream_scope:(Accum.current_stream_scope t.accum) ~block_index ~tool_call_id
    completion t.bridge)

let on_progress t ~block_index ~tool_call_id progress =
  apply t (Bridge.progress_native_tool ~redact_text:t.redact_text
    ~stream_scope:(Accum.current_stream_scope t.accum) ~block_index ~tool_call_id
    progress t.bridge)

let events t = List.rev t.reversed

let snapshots t =
  let events = events t in
  let open Alcotest in
  let lines = List.mapi (fun seq event ->
    let line : Journal.journaled_event = {seq; ts=1000. +. float_of_int seq; event} in
    match Journal.journaled_event_of_json (Journal.journaled_event_to_json line) with
    | Ok decoded -> decoded | Error detail -> fail (Journal.decode_failure_to_string detail)) events in
  let _, wire = List.fold_left (fun (state, wire) (line : Journal.journaled_event) ->
    let state, projected = Projection.project ~timestamp:line.ts
      ~redact_text:Fun.id state line.event in
    state, wire ^ Option.fold ~none:"" ~some:(Ag_ui.event_to_sse ~id:line.seq) projected)
    (Projection.initial, "") lines in
  let frames =
    Sse_wire.data_payloads_of_stream wire
    |> List.map Yojson.Safe.from_string
  in
  lines, frames

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
  let lines, frames = snapshots t in
  let journal_reports = List.filter_map (fun (line : Journal.journaled_event) ->
    match line.event with E.Native_tool_end (_, report) -> Some report | _ -> None) lines in
  check (list completion) "journal roundtrip retains every provider report" expected journal_reports;
  let sse_reports = List.filter_map (fun frame ->
    let open Yojson.Safe.Util in
    if frame |> member "type" |> to_string = "CUSTOM"
       && frame |> member "name" |> to_string = "KEEPER_NATIVE_TOOL_END"
    then
      match Runtime_native_tools.completion_of_json (frame |> member "value" |> member "completion") with
      | Ok report -> Some report
      | Error detail -> fail detail
    else None) frames in
  check (list completion) "SSE projection retains every provider report" expected sse_reports;
  check bool "SSE emits no MASC tool result event for native completion" false
    (List.exists (fun frame ->
      Yojson.Safe.Util.(frame |> member "type" |> to_string) = "TOOL_CALL_RESULT") frames)

let check_progress t ~expected ~expected_text ~running =
  let open Alcotest in
  let lines, frames = snapshots t in
  let text =
    lines
    |> List.filter_map (fun (line : Journal.journaled_event) ->
      match line.event with E.Text_delta { text; _ } -> Some text | _ -> None)
    |> String.concat ""
  in
  check string "progress never enters assistant text" expected_text text;
  check bool "progress never invents a receipt" false
    (List.exists (fun (line : Journal.journaled_event) ->
      match line.event with E.Tool_result_ready _ -> true | _ -> false) lines);
  let has_end = List.exists (fun (line : Journal.journaled_event) ->
    match line.event with E.Native_tool_end _ -> true | _ -> false) lines in
  check bool "progress never provides completion" (not running) has_end;
  (* Fold native progress observations by tool_call_id in first-seen order. *)
  let order = ref [] in
  let table = Hashtbl.create 8 in
  let update call_id progress =
    if not (Hashtbl.mem table call_id) then order := call_id :: !order;
    let prev_bytes, prev_msg =
      match Hashtbl.find_opt table call_id with Some v -> v | None -> None, None
    in
    let next =
      match progress with
      | Runtime_native_tools.Output_observed { byte_count } ->
        Some (Option.value prev_bytes ~default:0 + byte_count), prev_msg
      | Runtime_native_tools.Message_reported { message } ->
        prev_bytes, Some message
      | Runtime_native_tools.Heartbeat_reported _
      | Runtime_native_tools.Retry_observed _ ->
        prev_bytes, prev_msg
    in
    Hashtbl.replace table call_id next
  in
  List.iter (fun (line : Journal.journaled_event) ->
    match line.event with
    | E.Native_tool_progress (tool, progress) ->
      update (Option.value tool.tool_call_id ~default:"") progress
    | _ -> ()) lines;
  let observations =
    List.rev !order
    |> List.map (fun id ->
      let bytes, msg = Hashtbl.find table id in
      id, bytes, msg)
  in
  check (list (triple string (option int) (option string)))
    "exact native rows retain progress" expected observations;
  let sse_progress_count =
    List.fold_left (fun acc frame ->
      let open Yojson.Safe.Util in
      if frame |> member "type" |> to_string = "CUSTOM"
         && frame |> member "name" |> to_string = "KEEPER_NATIVE_TOOL_PROGRESS"
      then acc + 1 else acc) 0 frames
  in
  let journal_progress_count =
    List.fold_left (fun acc (line : Journal.journaled_event) ->
      match line.event with E.Native_tool_progress _ -> acc + 1 | _ -> acc) 0 lines
  in
  check int "SSE projection preserves every native progress event"
    journal_progress_count sse_progress_count
