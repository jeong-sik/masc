module Events = Keeper_chat_events
module Journal = Keeper_chat_event_log
module Bridge = Keeper_chat_agent_core_stream_bridge
module Accum = Keeper_stream_tool_accum

type open_stream = { mutable bridge : Bridge.state }
type stream_state = Open of open_stream | Closed

type t =
  { base_path : string
  ; keeper_name : string
  ; turn_ref : Ids.Turn_ref.t
  ; events : Events.t option
  ; accum : Accum.t
  ; child_journal : Keeper_child_content_journal.t
  ; task_journal : Keeper_native_task_journal.t
  ; text : Keeper_stream_text_redaction.Scoped.t
  ; redact_text : string -> string
  ; mutex : Eio.Mutex.t
  ; mutable stream : stream_state
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
        | Journal.Journal_unreadable detail | Journal.Journal_corrupt detail -> detail
        | Journal.Journal_unsupported_version version -> Journal.version_mismatch_to_string version in
      Log.Keeper.error ~keeper_name "autonomous stream journal unavailable: %s" detail;
      None
    | Ok first_seq -> Some (Events.create ~first_seq ~on_publish:(fun ~seq ~ts event ->
    Journal.append journal ~seq ~ts
      (Events.public_content
        ~redact_text:(Keeper_secret_redaction.redact_text redaction) event);
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
      child_journal = Keeper_child_content_journal.create ~base_path ~keeper_name
        ~source:(Keeper_native_task_journal.Autonomous_turn turn_ref)
        ~redact_text:(Keeper_secret_redaction.redact_text redaction);
      task_journal = Keeper_native_task_journal.create ~base_path ~keeper_name
        ~source:(Keeper_native_task_journal.Autonomous_turn turn_ref)
        ~redact_text:(Keeper_secret_redaction.redact_text redaction);
      redact_text = Keeper_secret_redaction.redact_text redaction;
      mutex = Eio.Mutex.create ();
      stream = Open {bridge = Bridge.empty_state ~generation:content_generation ()} }
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

let with_open_stream t f =
  with_stream t (fun () -> match t.stream with Open stream -> f stream | Closed -> ())

let apply t stream (translated : Bridge.translated_event) =
  stream.bridge <- translated.bridge_state;
  List.iter (publish t) translated.chat_events

let forward t stream scoped =
  List.iter (fun (stream_scope, event) ->
    apply t stream (Bridge.translate ~redact_text:t.redact_text ~base_dir:t.base_path
      ~stream_scope stream.bridge event)) scoped

let flush t stream = forward t stream (Keeper_stream_text_redaction.Scoped.flush t.text)

let mapping_failed t detail =
  publish t (Events.Agent_core_stream_protocol_error
    { kind = Events.Tool_occurrence_mapping_invalid; quarantined_occurrence = None;
      index = None; tool_call_id = None; event_type = None;
      reason = Some (t.redact_text detail); raw_bytes = None })

let result_ready t stream ~tool_call_id ~execution_id = function
  | Error detail -> mapping_failed t detail
  | Ok occurrence ->
      stream.bridge <- Bridge.record_tool_result stream.bridge occurrence;
      publish t (Events.Tool_result_ready {occurrence; tool_call_id; execution_id})

let on_event t event = with_open_stream t (fun stream ->
  Accum.on_event t.accum event;
  let stream_scope = Accum.current_stream_scope t.accum in
  forward t stream (Keeper_stream_text_redaction.Scoped.on_event t.text ~stream_scope event);
  ignore (Accum.take_protocol_errors t.accum))

let on_tool_stream_observation t = function
  (* Bound observations remain independently durable after the root stream
     closes; do not hold the unrelated publication mutex around them. *)
  | Keeper_hooks_agent_core.Child_content_observed {attempt; observation} ->
      Eio.Cancel.protect (fun () ->
        Keeper_child_content_journal.observe t.child_journal ~attempt observation
        |> Keeper_child_content_journal.report ~keeper_name:t.keeper_name)
  | Keeper_hooks_agent_core.Native_task_observed {attempt; bound} ->
      Eio.Cancel.protect (fun () ->
        Keeper_native_task_journal.observe t.task_journal ~attempt bound
        |> Keeper_native_task_journal.report ~keeper_name:t.keeper_name)
  | Keeper_hooks_agent_core.Provider_retry_observed {attempt; retry} ->
      with_open_stream t (fun _ -> publish t (Events.Provider_retry_observed {attempt; retry}))
  | Keeper_hooks_agent_core.Runtime_attempt_started {runtime_id; lane_attempt_index; _} ->
      with_open_stream t (fun stream ->
        flush t stream;
        let previous_scope = Accum.start_runtime_attempt t.accum in
        apply t stream (Bridge.start_runtime_attempt ~runtime_id ~attempt_index:lane_attempt_index
          ~previous_scope stream.bridge))
  | Keeper_hooks_agent_core.Turn_collected {turn; tool_source_map} ->
      with_open_stream t (fun _ ->
      (match Accum.seal_turn t.accum ~turn ~tool_source_map with
       | Ok events -> List.iter (publish t) events | Error detail -> mapping_failed t detail))
  | Keeper_hooks_agent_core.Turn_closed_without_sources {turn} ->
      with_open_stream t (fun _ ->
      (match Accum.close_turn_without_sources t.accum ~turn with
       | Ok () -> () | Error detail -> mapping_failed t detail))
  | Keeper_hooks_agent_core.Native_tool_progress {block_index; tool_call_id; progress} ->
      (* This observation updates an existing native row. It is not a model
         content boundary: keep any partial secret held across later deltas. *)
      with_open_stream t (fun stream ->
        apply t stream (Bridge.progress_native_tool ~redact_text:t.redact_text
          ~stream_scope:(Accum.current_stream_scope t.accum) ~block_index ~tool_call_id progress stream.bridge))
  | Keeper_hooks_agent_core.Native_tool_completion {block_index; tool_call_id; completion} ->
      with_open_stream t (fun stream ->
        apply t stream (Bridge.finish_native_tool ~redact_text:t.redact_text
          ~stream_scope:(Accum.current_stream_scope t.accum) ~block_index ~tool_call_id completion stream.bridge))
  | Keeper_hooks_agent_core.Official_tool_result {block_index; tool_call_id; execution_id} ->
      with_open_stream t (fun stream ->
        result_ready t stream ~tool_call_id:(Some tool_call_id) ~execution_id
          (Accum.record_official_execution_id t.accum ~block_index ~tool_call_id ~execution_id))

let on_tool_result_ready t ~tool_call_id ~turn ~planned_index ~execution_id = with_open_stream t (fun stream ->
  result_ready t stream ~tool_call_id:(if String.equal tool_call_id "" then None else Some tool_call_id) ~execution_id
    (Accum.record_execution_id t.accum ~tool_call_id ~turn ~planned_index ~execution_id))

type ending =
  | Completed of { reply : string; turn_outcome : Keeper_turn_outcome.t }
  | Failed of string
  | Cancelled

let publish_committed_tool_ownerships t ownerships = with_open_stream t (fun _ ->
  List.iter (fun (delivery_key, ({execution_id; ordinal} : Keeper_chat_store.tool_ownership)) ->
    publish t (Events.Tool_transcript_committed {delivery_key; execution_id; ordinal})) ownerships)

let finish t ending =
  Eio.Cancel.protect (fun () -> with_stream t (fun () -> match t.stream with
   | Closed -> ()
   | Open stream ->
    Fun.protect ~finally:(fun () ->
      t.stream <- Closed;
      Option.iter Events.close t.events;
      with_current (fun () ->
        match Hashtbl.find_opt current_turns (t.base_path, t.keeper_name) with
        | Some turn_ref when Ids.Turn_ref.equal turn_ref t.turn_ref ->
            Hashtbl.remove current_turns (t.base_path, t.keeper_name)
        | Some _ | None -> ())) (fun () ->
      flush t stream;
      (match ending with
       | Completed {reply; turn_outcome} ->
           publish t (Events.Reply_details { reply = t.redact_text reply; turn_outcome; turn_ref = t.turn_ref;
             terminal_stream_scope = Bridge.terminal_text_scope stream.bridge })
       | Failed message -> apply t stream (Bridge.fail_stream stream.bridge ~reason:(t.redact_text message))
       | Cancelled -> apply t stream (Bridge.fail_stream stream.bridge ~reason:"Autonomous turn cancelled"));
      publish t Events.Text_message_end;
      publish t (match ending with
        | Completed _ -> Events.Run_finished {run_id = Ids.Turn_ref.to_string t.turn_ref}
        | Failed message ->
          Log.Keeper.warn ~keeper_name:t.keeper_name
            "keeper_turn_error incident_id=%s detail=%s"
            (Ids.Turn_ref.to_string t.turn_ref) (t.redact_text message);
          Events.Event_error {message = t.redact_text message}
        | Cancelled -> Events.Event_error {message = "Autonomous turn cancelled"}))))

let task_journal_health t = Keeper_native_task_journal.health t.task_journal

let child_journal_health t = Keeper_child_content_journal.health t.child_journal
