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
    dropped, so a new event draws as itself instead of vanishing. *)
type agent_core_kind =
  | Tool_called
  | Tool_completed
  | Turn_started
  | Turn_ready
  | Turn_completed
  | Agent_started
  | Agent_completed
  | Agent_failed
  | Agent_yielded
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
  parent : string option;  (** [parent_event_id], the composition parent *)
}

type keeper_heartbeat = {
  hb_keeper : string;
  hb_phase : string option;  (** absent on the bare liveness beat *)
  hb_in_turn : bool option;
  hb_in_flight_ms : float option;
  hb_since_progress_ms : float option;
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

(** A keeper's tool call as the keeper layer records it: named by keeper,
    with the call's duration and disposition. The agent_core family reports
    the same call from the runtime's side, named by lane. *)
type keeper_tool_call = {
  kt_keeper : string;
  kt_tool : string;
  kt_duration_ms : float option;
  kt_disposition : string option;  (** [completed], as the server writes it *)
  kt_at : float;
}

type event =
  | Agent_core of agent_core
  | Keeper_heartbeat of keeper_heartbeat
  | Keeper_tool_call of keeper_tool_call
  | Keeper_turn_complete of keeper_turn_complete
  | Keeper_composite_changed of { keeper : string; at : float }
  | Keeper_chat_appended of { keeper : string; connector : string option; at : float }
  | Keeper_chat_stream_frame of
      { keeper : string; frame : string option; at : float }
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

val feed : t -> string -> decoded list
(** Hand the reader the next chunk. Returns the frames completed by it, in
    order. A line the chunk cut in half is held until the rest arrives;
    [retry:], [id:], [event:], and comment lines are the stream's framing
    and produce nothing. *)
