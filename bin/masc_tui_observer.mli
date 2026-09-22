(** The whole-runtime event feed, read from [GET /mcp?sse_kind=observer].

    Every keeper's tool calls, turn boundaries, heartbeats, and turn
    settlements go out on one server-sent event stream the dashboard reads
    over its WebSocket. The TUI read none of it: each surface polled its own
    snapshot on a timer, and a keeper calling a tool was invisible until the
    next poll of whichever surface happened to show it.

    Nothing here performs I/O. The transport opens the MCP session and the
    stream; this module names the request that opens a session, reads the
    session id off the answer, and turns the bytes of the stream into typed
    events one chunk at a time.

    {2 Opening the stream}

    The MCP transport registers an observer only for a session it has seen
    [initialize]. Without a known session id the route refuses the
    registration with a JSON-RPC error object ([SSE registration failed:
    unknown session ...]) rather than opening a stream. The id comes back in
    the [Mcp-Session-Id] response header of the initialize POST, not in its
    body, and the server keeps the session after the stream closes, so one
    session serves every stream and tool call the TUI makes.

    {2 What the server sends}

    One SSE frame per event, [data:] carrying a JSON object with a [type].
    The [agent_core:*] family carries the agent name, the tool name, the
    task, and a [payload] with the turn number and tool-use id; the keeper
    family carries the keeper name and its own fields. Snapshot events carry
    whole dashboard projections and are identified but not retained here: a
    feed row has no use for a projection, and holding them would grow with
    every push. *)

val initialize_request_body : client_version:string -> string
(** The JSON-RPC [initialize] body the MCP transport needs before it will
    register an observer. [client_version] names this build in
    [clientInfo]. *)

val session_id_of_headers : (string * string) list -> (string, string) result
(** The [Mcp-Session-Id] response header, matched without regard to case.
    [Error] names the absence: a session-less observer GET is refused, so a
    caller must not try one. *)

(** The [agent_core:*] event family, by [event_type]. A type the server
    named and this build was not taught keeps its name rather than being
    dropped, so a new event draws as itself instead of vanishing.

    A run that ended carries how long it ran, and a failed one the error's
    code and text, read from the payload with {!Sse_event.Json}'s readers -- the
    contract the bridge writes it with. *)
type agent_core_kind =
  | Tool_called
  | Tool_completed
  | Turn_started
  | Turn_ready
  | Turn_completed
  | Agent_started
  | Agent_completed of { elapsed_s : float }
  | Agent_failed of { elapsed_s : float; error_code : string; error : string }
  | Agent_yielded of { elapsed_s : float }
  | Tool_approval_completed
  | Telemetry
  | Agent_core_other of string

type agent_core = {
  kind : agent_core_kind;
  agent : string option;
      (** [agent_name]: the runtime lane on tool and turn events, absent on
          provider streaming telemetry, which names no agent at all *)
  tool : string option;  (** [tool_name], set on tool events *)
  task : string option;  (** [task_id] *)
  turn : int option;  (** [payload.turn] *)
  tool_use_id : string option;  (** [payload.tool_use_id], pairs a call with its completion *)
  batch : (int * int) option;  (** [payload.batch_index], [payload.batch_size] *)
  at : float;  (** [ts_unix] *)
  correlation : string option;  (** [correlation_id], the trace *)
  parent : string option;  (** [parent_event_id], the producer-owned parent reference *)
  event_id : string option;
  run_id : string option;
  caused_by : string option;
  execution_id : string option;
}

type lane_resource = {
  lr_lifecycle : Masc.Lane_addon_resource_events.lifecycle;
  lr_package : string;  (** the add-on package the instance runs *)
  lr_instance : string;  (** the instance whose container this is *)
  lr_detail : string option;
      (** why it failed, for [Acquire_failed] and [Release_incomplete] *)
  lr_at : float;
}

type keeper_heartbeat = {
  hb_keeper : string;
  hb_phase : string option;  (** absent on the bare liveness beat *)
  hb_in_turn : bool option;
  hb_in_flight_ms : float option;
  hb_at : float;
}

type keeper_turn_complete = {
  tc_keeper : string;
  tc_turn : int option;
  tc_model : string option;
  tc_input_tokens : int option;
  tc_output_tokens : int option;
  tc_cost_usd : float option;
  tc_tool_calls : int option;
  tc_at : float;
}

(** One provider call inside a keeper turn, as the keeper's Agent-Core hook
    reports it ([keeper_turn_observation]). [to_session_turn] is the agent
    session's ordinal for the call -- the [turn] every [agent_core:*] frame
    and every {!keeper_tool_call} carries -- and [to_total_turns] is how many
    keeper turns had completed when the call ran, so the call belongs to
    keeper turn [to_total_turns + 1], the number that turn's
    {!keeper_turn_complete} settles with. The Activity fold reads these to
    file session-numbered frames under their keeper turn. *)
type keeper_turn_observation = {
  to_keeper : string;
  to_session_turn : int option;
  to_total_turns : int option;
  to_at : float;
}

(** A keeper's tool call as the keeper layer records it: named by keeper,
    with the call's duration and disposition. The agent_core family reports
    the same call from the runtime's side, named by lane. *)
type keeper_tool_call = {
  kt_keeper : string;
  kt_turn : int option;
      (** The agent session's ordinal for the provider call this ran in --
          the plane the agent-core wire and {!keeper_turn_observation} number
          calls on; the settle numbers the keeper turn. [None] for a call the
          server reported without an invocation. *)
  kt_tool : string;
  kt_duration_ms : float option;
  kt_disposition : (Masc.Tui_decode.keeper_call_disposition, string) result option;
      (** [completed], [deferred] or [failed] as the call log spells them,
          typed at the wire so a reader never compares the word. None when
          the frame carried none; a word outside the vocabulary stays an
          Error beside the call's I/O, the way [kt_schedule] keeps its. *)
  kt_at : float;
  kt_tool_use_id : string option;
  kt_schedule : (Agent_core.Tool_contract.schedule, string) result option;
      (** None means no scheduling metadata was supplied. Invalid metadata
          remains an Error so the caller can still inspect the call's I/O. *)
  kt_tool_args : Yojson.Safe.t option;
  kt_tool_result : Yojson.Safe.t option;
  kt_tool_args_preview : string option;
  kt_tool_output_preview : string option;
}

type event =
  | Agent_core of agent_core
  | Keeper_heartbeat of keeper_heartbeat
  | Keeper_tool_call of keeper_tool_call
  | Keeper_turn_complete of keeper_turn_complete
  | Keeper_turn_observation of keeper_turn_observation
  | Keeper_composite_changed of { keeper : string; at : float }
  | Keeper_chat_appended of { keeper : string; connector : string option; at : float }
  | Keeper_chat_stream_frame of
      { keeper : string
      ; operation_id : string
          (** The chat operation the frame belongs to. The chat pane reads it
              to follow a turn it did not open: a frame says that operation's
              journal has grown, and the journal is what the pane draws.
              The server sends these frames for operations whose
              continuation channel is the dashboard (the dashboard, the TUI,
              the API); a turn a connector opened sends none. *)
      ; seq : int option
          (** The journal seq of the event this frame projects, when the
              server attached one; a log already holding it has nothing to
              read. [None] on the terminal the server synthesises at settle.
              A seq of another shape fails the frame rather than reading as
              absent. *)
      ; frame : string option
      ; at : float
      }
      (** One frame of a live chat stream ([keeper_chat_operation_event]).
          [frame] is the AG-UI event's own [type], plus its [name] when it
          carries one. A reply of any length sends one of these per token, so
          the Acting filter treats them as noise the way it treats
          heartbeats. *)
  | Keeper_waiting_inventory_changed of
      { keeper : string; queue_kind : string option; at : float }
      (** The keeper's waiting queue changed. Names the keeper in
          [keeper_name], not [name]. *)
  | Fusion_run_status of { keeper : string; run_id : string; status : string }
      (** A fusion deliberation changed stage or settled. A server push, not
          a keeper act: the Fusion surface re-fetches the run on it instead of
          reading the payload as data, so only the identity strings are kept
          and, unlike the keeper events, it carries no [at]. *)
  | Internal_agent_runs_changed
      (** An internal agent run registry -- verification, goal verification,
          exact lanes -- changed. A server push with no payload, named by
          {!Masc.Internal_agent_runs_event}. *)
  | Lane_resource of lane_resource
      (** A Lane Add-on container was acquired, failed to start, was removed,
          or could not be shown removed. It arrives in the agent-core family
          and is recognised by the names {!Masc.Lane_addon_resource_events}
          mints, as {!Masc.Keeper_event_bridge.public_custom_event_type}
          spells them on the wire. *)
  | Snapshot of string
      (** A whole-projection push; the name is kept, the payload is not. Which
          types these are comes from the wire's own routing table
          ({!Masc.Dashboard_event_slices}) rather than a list here, because
          the list here had drifted by two. *)
  | Other of string  (** A [type] this build was not taught, by name. *)

(** One decoded frame. A frame that is not an event this build can read is
    reported with the reason rather than skipped, so a feed that shows
    nothing says why. *)
type decoded =
  | Event of event
  | Undecodable of string

type delivery = {
  cursor : int option;
  decoded : decoded;
}
(** Transport identity from the SSE [id:] line, independent of the payload's
    event/run/tool identities. [None] means the frame carried no replay ID. *)

val chat_appended_keeper : event -> string option
(** The keeper whose chat just gained a turn — [Some] only for
    {!Keeper_chat_appended}. The chat pane reloads its history on this
    and on nothing else. *)

val event_of_json : Yojson.Safe.t -> (event, string) result
(** Decode one [data:] payload. [Error] for a payload with no [type], or an
    [agent_core:*] payload missing [event_type] or [ts_unix], which every
    row of the family carries. *)

(** Incremental reader over the stream's bytes. *)
type t

val create : unit -> t

val feed : t -> string -> delivery list
(** Hand the reader the next chunk. Returns the frames completed by it, in
    order. Both a cut line and an unterminated frame remain pending. A replay
    cursor travels only with its completed data frame; an ID-only frame does
    not acknowledge an event. *)
