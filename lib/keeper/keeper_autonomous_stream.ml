module Events = Keeper_chat_events
module Journal = Keeper_chat_event_log
module Bridge = Keeper_chat_agent_core_stream_bridge
module Accum = Keeper_stream_tool_accum

type t =
  { base_path : string
  ; keeper_name : string
  ; turn_ref : Ids.Turn_ref.t
  ; events : Events.t option
  ; accum : Accum.t
  ; text : Keeper_stream_text_redaction.Scoped.t
  ; redact_text : string -> string
  ; mutex : Eio.Mutex.t
  ; mutable bridge : Bridge.state
  ; mutable closed : bool
  }

let current_turns : ((string * string), Ids.Turn_ref.t) Hashtbl.t = Hashtbl.create 16
let current_mutex = Mutex.create ()

let with_current f =
  Mutex.lock current_mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock current_mutex) f

let current ~base_path ~keeper_name =
  with_current (fun () -> Hashtbl.find_opt current_turns (base_path, keeper_name))

let create ~base_path ~keeper_name ~turn_ref = Eio.Cancel.protect (fun () ->
  let journal = Journal.open_turn_journal ~base_dir:base_path ~keeper_name ~turn_ref () in
  let redaction = Keeper_secret_redaction.snapshot ~base_path ~keeper_name in
  let events = match Journal.next_sequence journal with
    | Error failure ->
      let detail = match failure with
        | Journal.Journal_missing -> "journal disappeared"
        | Journal.Journal_unreadable detail | Journal.Journal_corrupt detail -> detail in
      Log.Keeper.error ~keeper_name "autonomous stream journal unavailable: %s" detail;
      None
    | Ok first_seq -> Some (Events.create ~first_seq ~on_publish:(fun ~seq ~ts event ->
    Journal.append journal ~seq ~ts event;
    (* A notification names the canonical journal cursor. Readers fetch the
       journal rather than racing live frames against replay or exposing
       reasoning on a general observer connection. *)
    (try Sse.broadcast_to
       (Sse.Runtime_observers (Sse.runtime_authority_exn ~base_path))
       (`Assoc [ "type", `String "keeper_turn_stream_event";
         "name", `String keeper_name;
         "turn_ref", `String (Ids.Turn_ref.to_string turn_ref);
         "seq", `Int seq; "ts_unix", `Float ts ])
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn -> Log.Keeper.warn ~keeper_name "autonomous stream notification failed: %s" (Printexc.to_string exn))) ()) in
  (* This producer has no channel adapter: its only reader is the authenticated
     journal endpoint. Disable queue backpressure while retaining the hook. *)
  Option.iter Events.reader_gone events;
  let run_id = Ids.Turn_ref.to_string turn_ref in
  let content_generation = match events with
    | Some events -> Events.publish_with_sequence events
        (Events.Run_started {run_id; thread_id="keeper:" ^ keeper_name})
    | None -> 0 (* No journal or publication exists in this branch. *) in
  let t =
    { base_path; keeper_name; turn_ref; events; accum = Accum.create ();
      text = Keeper_stream_text_redaction.Scoped.create redaction;
      redact_text = Keeper_secret_redaction.redact_text redaction;
      mutex = Eio.Mutex.create (); bridge = Bridge.empty_state
        ~generation:content_generation (); closed = false }
  in
  Option.iter (fun _ -> with_current (fun () ->
    Hashtbl.replace current_turns (base_path, keeper_name) turn_ref)) events;
  Option.iter (fun events ->
    Events.publish events (Events.Text_message_start { message_id = run_id ^ ":assistant"; role = Events.Assistant })) events;
  t)

let publish t event = Option.iter (fun events -> Events.publish events event) t.events

(* Parallel tool hooks can commit on different fibers. Serialize the bridge
   state and complete journal append together, so sequence numbers remain in
   file order. Unlock is synchronous; cancellation cannot leave half a publish.
   Low-level locking lets the terminal error path close after a failed callback. *)
let with_stream t f =
  Eio.Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Eio.Mutex.unlock t.mutex)
    (fun () -> Eio.Cancel.protect f)

let apply t (translated : Bridge.translated_event) =
  t.bridge <- translated.bridge_state;
  List.iter (publish t) translated.chat_events

let forward t scoped =
  List.iter (fun (stream_scope, event) ->
    apply t (Bridge.translate ~redact_text:t.redact_text ~base_dir:t.base_path
      ~stream_scope t.bridge event)) scoped

let flush t = forward t (Keeper_stream_text_redaction.Scoped.flush t.text)

let mapping_failed t detail =
  publish t (Events.Agent_core_stream_protocol_error
    { kind = Events.Tool_occurrence_mapping_invalid; quarantined_occurrence = None;
      index = None; tool_call_id = None; event_type = None;
      reason = Some (t.redact_text detail); raw_bytes = None })

let result_ready t ~tool_call_id ~execution_id = function
  | Error detail -> mapping_failed t detail
  | Ok occurrence ->
      t.bridge <- Bridge.record_tool_result t.bridge occurrence;
      publish t (Events.Tool_result_ready {occurrence; tool_call_id; execution_id})

let on_event t event = with_stream t (fun () ->
  Accum.on_event t.accum event;
  let stream_scope = Accum.current_stream_scope t.accum in
  forward t (Keeper_stream_text_redaction.Scoped.on_event t.text ~stream_scope event);
  ignore (Accum.take_protocol_errors t.accum))

let on_tool_stream_observation t observation = with_stream t (fun () -> match observation with
  | Keeper_hooks_agent_core.Runtime_attempt_started {runtime_id; lane_attempt_index; _} ->
      flush t;
      let previous_scope = Accum.start_runtime_attempt t.accum in
      apply t (Bridge.start_runtime_attempt ~runtime_id ~attempt_index:lane_attempt_index
        ~previous_scope t.bridge)
  | Keeper_hooks_agent_core.Turn_collected {turn; tool_source_map} ->
      (match Accum.seal_turn t.accum ~turn ~tool_source_map with
       | Ok () -> () | Error detail -> mapping_failed t detail)
  | Keeper_hooks_agent_core.Turn_closed_without_sources {turn} ->
      (match Accum.close_turn_without_sources t.accum ~turn with
       | Ok () -> () | Error detail -> mapping_failed t detail)
  | Keeper_hooks_agent_core.Native_tool_progress {block_index; tool_call_id; progress} ->
      (* This observation updates an existing native row. It is not a model
         content boundary: keep any partial secret held across later deltas. *)
      if not t.closed then begin
        apply t (Bridge.progress_native_tool ~redact_text:t.redact_text
          ~stream_scope:(Accum.current_stream_scope t.accum) ~block_index ~tool_call_id progress t.bridge)
      end
  | Keeper_hooks_agent_core.Native_tool_completion {block_index; tool_call_id; completion} ->
      if not t.closed then
        apply t (Bridge.finish_native_tool ~redact_text:t.redact_text
          ~stream_scope:(Accum.current_stream_scope t.accum) ~block_index ~tool_call_id completion t.bridge)
  | Keeper_hooks_agent_core.Official_tool_result {block_index; tool_call_id; execution_id} ->
      result_ready t ~tool_call_id:(Some tool_call_id) ~execution_id
        (Accum.record_official_execution_id t.accum ~block_index ~tool_call_id ~execution_id))

let on_tool_result_ready t ~tool_call_id ~turn ~planned_index ~execution_id = with_stream t (fun () ->
  result_ready t ~tool_call_id:(if String.equal tool_call_id "" then None else Some tool_call_id) ~execution_id
    (Accum.record_execution_id t.accum ~tool_call_id ~turn ~planned_index ~execution_id))

type ending =
  | Completed of { reply : string; turn_outcome : Keeper_turn_outcome.t }
  | Failed of string
  | Cancelled

let finish t ending =
  Eio.Cancel.protect (fun () -> with_stream t (fun () -> if not t.closed then
    Fun.protect ~finally:(fun () ->
      t.closed <- true;
      Option.iter Events.close t.events;
      with_current (fun () ->
        match Hashtbl.find_opt current_turns (t.base_path, t.keeper_name) with
        | Some turn_ref when Ids.Turn_ref.equal turn_ref t.turn_ref ->
            Hashtbl.remove current_turns (t.base_path, t.keeper_name)
        | Some _ | None -> ())) (fun () ->
      flush t;
      (match ending with
       | Completed {reply; turn_outcome} ->
           publish t (Events.Reply_details { reply = t.redact_text reply; turn_outcome; turn_ref = t.turn_ref })
       | Failed message -> apply t (Bridge.fail_stream t.bridge ~reason:(t.redact_text message))
       | Cancelled -> apply t (Bridge.fail_stream t.bridge ~reason:"Autonomous turn cancelled"));
      publish t Events.Text_message_end;
      publish t (match ending with
        | Completed _ -> Events.Run_finished {run_id = Ids.Turn_ref.to_string t.turn_ref}
        | Failed message -> Events.Event_error {message = t.redact_text message}
        | Cancelled -> Events.Event_error {message = "Autonomous turn cancelled"}))))
