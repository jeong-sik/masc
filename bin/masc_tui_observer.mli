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
    every push. Nor are they read past their [type]: the server writes it as
    the first member, and a projection can run to megabytes after it. *)

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
type runtime_journal = Native_tasks_journal | Child_content_journal
(** The two journals a Keeper's runtime fills beside its chat. *)

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
  | Agent_input_required of { elapsed_s : float; request_id : string; question : string }
  | Tool_approval_completed
  | Telemetry
  | Relay_subscription_loss of { source_id : string; sequence : int; dropped_count : int }
      (** The relay subscriber lost this many events before SSE publication. *)
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
      (** Everything the turn sent, cache reads included. *)
  tc_cache_read_tokens : int option;
      (** The part of [tc_input_tokens] read from the provider's cache.
          [None] when the event does not carry it. *)
  tc_cache_creation_tokens : int option;
      (** The part of [tc_input_tokens] written to the cache this turn:
          processed fresh, not read back. [None] when the event does not
          carry it. *)
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

(** What changed in the Gate, the held tool calls, the tool approval modes
    or the questions put to the operator. Each is a server push with no
    data: the reader re-fetches. *)
type approval_change =
  | Approval_queue_changed
      (** [approval:pending], [approval:resolved], [approval:summary_updated] *)
  | Approval_rules_changed  (** [approval_rules_changed] *)
  | Gate_mode_changed  (** [gate_mode_changed], [gate_external_mode_changed] *)
  | Gate_keeper_settings_changed of { keeper : string }
      (** [gate_keeper_mode_changed], [keeper_exact_lane_preference_changed] *)
  | Tool_approval_waits_changed of { keeper : string }
      (** [keeper_tool_approval_waits_changed] *)
  | Tool_approval_mode_changed of { keeper : string }
      (** [keeper_tool_approval_mode_changed] *)
  | Keeper_asks_changed of { keeper : string }  (** [keeper_asks_changed] *)
  | Installation_asks_changed of { declaration_id : string }
      (** [lane_addon_asks_changed] *)

(** What a Keeper roster push says changed (RFC-0481 §3.2). *)
type roster_change =
  | Keeper_row_changed of { keeper : string }
      (** [keeper_row_changed]: that Keeper's row may have changed,
          appeared or gone. *)
  | Every_row_changed
      (** [keeper_roster_changed]: a value every row reads changed. *)

(** What a Keeper turns push says changed (RFC-0481 §3.4, §3.5). Either one
    reads the turns again. *)
type turn_change =
  | Turn_state
      (** [keeper_turn_changed]: the turn slot, turn ref, chat control
          token, shutdown operation or Owner availability. *)
  | Turn_preview
      (** [keeper_turn_preview_changed]: the running turn's preview. *)

(** A workspace store that announces a write with a payload-less server
    push. A reader that shows the store reads it again. Each is named by one
    server module's event type. *)
type workspace_store =
  | Schedule_store
      (** A schedule ledger write was attempted, a runner tick changed the
          list, or its status passed the staleness deadline
          ({!Masc.Schedule_invalidation_event}). *)
  | Pending_confirms
      (** Pending confirmations may have changed
          ({!Masc.Pending_confirm_invalidation_event}). *)
  | Goal_projection
      (** A Goal projection source changed: the Goal store, the verification
          ledger, the measurement store or the verifier's observations
          ({!Masc.Goal_projection_broadcast}). *)
  | Runtime_config
      (** The server committed a runtime.toml text
          ({!Masc.Runtime_config_changed_event}). *)
  | Skill_catalog
      (** A workspace skill catalog snapshot was published
          ({!Masc.Skill_catalog_published_event}). *)
  | Lane_addon_exports
      (** A Lane Add-on's exported tools or their readiness changed
          ([lane_addon_exports_changed], {!Masc.Lane_addon_exports_broadcast}). *)

(** A whole-projection push. The TUI re-reads what [Transport_health]
    measures ([/api/v1/dashboard/transport-health]); the others are named for
    the Acting row only. *)
type projection =
  | Transport_health
  | Unread_projection of string

val projection_name : projection -> string
(** The wire type the push arrived as. *)

type event =
  | Agent_core of agent_core
  | Keeper_heartbeat of keeper_heartbeat
  | Keeper_tool_call of keeper_tool_call
  | Keeper_turn_complete of keeper_turn_complete
  | Keeper_turn_observation of keeper_turn_observation
  | Keeper_composite_changed of { keeper : string; at : float }
  | Keeper_metrics_appended of { keeper : string; at : float }
      (** A [keeper_metrics_appended] event for the Keeper. The logs view and the
          Info tab read it again. *)
  | Keeper_chat_appended of { keeper : string; connector : string option; at : float }
  | Keeper_memory_journal_appended of { keeper : string; at : float }
      (** The keeper's memory journal gained a row. The chat pane shows that
          journal beside the transcript and reads it again. *)
  | Keeper_runtime_journal_appended of
      { keeper : string; journal : runtime_journal; at : float }
      (** [keeper_native_tasks_appended] or [keeper_child_content_appended],
          named by {!Masc.Keeper_runtime_journal_broadcast}: the Keeper's
          journal took a record. A server push: a reader that shows the
          records reads them again. *)
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
  | Keeper_turn_stream_frame of
      { keeper : string; turn_ref : Ids.Turn_ref.t; seq : int; at : float }
      (** Autonomous journal growth notification. Its ordered contents are read
          from the turn endpoint; this notification carries no display payload. *)
  | Keeper_waiting_inventory_changed of
      { keeper : string; queue_kind : string option; at : float }
      (** The keeper's waiting queue changed. Names the keeper in
          [keeper_name], not [name]. *)
  | Keeper_async_requests_changed of { keeper : string }
      (** [keeper_async_requests_changed]: the Keeper's durable async message
          requests, or one of its composition execution journals, changed. A
          server push: the reader re-fetches [/api/v1/async-requests] and an
          open request detail of that Keeper. *)
  | Keeper_skill_activations_changed of { keeper : string }
      (** [keeper_skill_activations_changed]: the Keeper's skill activation
          ledger changed ({!Masc.Keeper_skill_activations_changed_event}). A
          reader re-fetches that Keeper's
          [/api/v1/keepers/skill-activations] and [/api/v1/keepers/skill-usage]. *)
  | Keeper_roster_change of roster_change
      (** Named by {!Masc.Keeper_row_broadcast}. A server push: the roster
          reads the named row, or the whole roster, again. *)
  | Keeper_turn_changed of { keeper : string; change : turn_change }
      (** Named by {!Masc.Keeper_turn_broadcast} and
          {!Masc.Keeper_turn_preview_signal}. A server push: what
          [/api/v1/keepers/turns] answers for that Keeper may have changed,
          so the turns are read again. *)
  | Fusion_run_status of { keeper : string; run_id : string; status : string }
      (** A fusion deliberation changed stage or settled. A server push, not
          a keeper act: the Fusion surface re-fetches the run on it instead of
          reading the payload as data, so only the identity strings are kept
          and, unlike the keeper events, it carries no [at]. *)
  | Internal_agent_runs_changed of Masc.Internal_agent_runs_event.registry
      (** The named internal agent run registry -- verification, goal
          verification or exact lanes -- changed. A server push named by
          {!Masc.Internal_agent_runs_event}. *)
  | Workspace_store_changed of workspace_store
      (** The named workspace store was written: a server push with no
          payload. *)
  | Dataset_changed of Masc.Workspace_dataset_event.dataset
      (** One of the workspace's datasets was written. A server push named by
          {!Masc.Workspace_dataset_event}; it carries the dataset's name and
          none of its data. *)
  | Gate_connector_changed of { connector : string }
      (** [connector]'s bindings, recorded names or drawn connection state
          changed. A server push named by {!Masc.Gate_connector_changed_event}. *)
  | Keeper_event_queue_changed of { keeper : string }
      (** [keeper]'s event queue, or the reaction record beside it, was
          written. A server push named by
          {!Masc.Keeper_event_queue_changed_event}: a schedule row whose
          target is [keeper] carries that queue's evidence. *)
  | Board_changed of { post_id : string option }
      (** A Board write: a post, a comment, a vote, a reaction, or a change
          to an existing post. It arrives as the JSON-RPC
          [notifications/board] envelope rather than a typed event. A server
          push: the Board re-reads on it. [post_id] is the post its params
          name, and [None] when they name none -- a vote on a comment and a
          reaction carry a target instead. *)
  | Approval_change of approval_change
      (** A Gate, held tool call or tool approval mode change. *)
  | Lane_resource of lane_resource
      (** A Lane Add-on container was acquired, failed to start, was removed,
          or could not be shown removed. It arrives in the agent-core family
          and is recognised by the names {!Masc.Lane_addon_resource_events}
          mints, as {!Masc.Keeper_event_bridge.public_custom_event_type}
          spells them on the wire. *)
  | Snapshot of projection
      (** A whole-projection push; the payload is not kept. Which types these
          are comes from the wire's own routing table
          ({!Masc.Dashboard_event_slices}) rather than a list here, because
          the list here had drifted by two. *)
  | Execution_snapshot
      (** [execution_snapshot]: a backlog or goal index write, or the
          server's periodic refresh. The Work surface and the Verification
          queue read again on it. *)
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
    and reads its call details again. *)

val composite_changed_keeper : event -> string option
(** The keeper whose composite just changed — [Some] only for
    {!Keeper_composite_changed}. The Keeper detail reads that Keeper's
    composite again on this. *)

val metrics_appended_keeper : event -> string option
(** The Keeper whose metrics file just gained a row — [Some] only for
    {!Keeper_metrics_appended}. The logs view and the Info tab read that
    Keeper's metrics again on this. *)

val tool_call_keeper : event -> string option
(** The keeper a [keeper_tool_call] names — [Some] only for
    {!Keeper_tool_call}. The Keeper_calls surface reads that Keeper's calls
    again on this. *)

val gate_snapshot_changed : event -> bool
(** The Gate snapshot ([/api/v1/dashboard/gate]) may answer differently:
    the approval queue, the standing rules, a Gate mode or a Keeper's Gate
    settings changed. *)

val held_calls_changed : event -> bool
(** The tool calls a Keeper holds for an operator changed. *)

val tool_modes_changed : event -> bool
(** What [/api/v1/keepers/tool-approval-mode] and the Keeper Gate settings
    answer changed: a tool approval mode or a Keeper's Gate setting. *)

val async_requests_changed : event -> bool
(** The durable async message requests changed. *)

val async_requests_keeper : event -> string option
(** The Keeper whose async requests, or the execution journal of one, changed. *)

val skill_activations_keeper : event -> string option
(** The Keeper whose skill activation ledger changed. *)

val skill_catalog_published : event -> bool
(** Whether [event] is a {!Skill_catalog} store change: a workspace skill
    catalog snapshot was published. *)

val lane_addon_exports_changed : event -> bool
(** Whether [event] is a {!Lane_addon_exports} store change. The Keeper
    effective tool surface reads the exports. *)

val dataset_owed : event -> Masc.Workspace_dataset_event.dataset option
(** The workspace dataset a push owes a read: the dataset it names as
    written, or the verification requests when the verification run registry
    their rows read changed. The goal-verification and exact-lane registries
    owe nothing. A backlog commit arrives as {!Execution_snapshot}. *)

val gate_connector_changed : event -> bool
(** [true] for {!Gate_connector_changed}. The Connectors list and a Keeper's
    channels tab read the connectors again on it. *)

val goal_projection_changed : event -> bool
(** Whether [event] is a {!Goal_projection} store change. The Planning screen reads
    its Goals again on this. *)

val transport_health_measured : event -> bool
(** The server's transport refresh loop measured again; the Usage surface's
    transport health reads again on it. *)

val turn_change : event -> (string * turn_change) option
(** The Keeper a turns push names, and what it says changed. *)

val runtime_journal_appended : event -> (string * runtime_journal) option
(** The Keeper and journal a runtime journal push names. *)

val schedules_changed : event -> bool
(** The workspace's schedules changed: a {!Schedule_store} change. *)

val event_queue_changed : event -> string option
(** The Keeper whose event queue or reaction record a push names. *)

val runtime_config_changed : event -> bool
(** runtime.toml changed on the server: a {!Runtime_config} change. *)

val pending_confirms_changed : event -> bool
(** The confirmations waiting for an operator changed or one passed its
    deadline: a {!Pending_confirms} change. *)

val asks_changed : event -> bool
(** The questions a Keeper or a Lane Add-on installation puts to the operator
    changed. *)

val board_changed_post : event -> string option option
(** [Some post] for {!Board_changed}, where [post] is the post it names or
    [None] when it names none; [None] for every other event. *)

val memory_journal_appended_keeper : event -> string option
(** The keeper whose memory journal just gained a row — [Some] only for
    {!Keeper_memory_journal_appended}. The chat pane reloads its history,
    which includes that journal, on this. *)

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
    not acknowledge an event.

    A frame whose first member is a [type] that decides the event by itself
    -- a {!Snapshot}, {!Internal_agent_runs_changed}, a {!Schedule_store} or
    {!Pending_confirms} change, or {!Other} -- is
    delivered as that event without the rest of the frame being read, so the
    rest is not checked either. Every other frame is parsed whole, and one
    that is not JSON is {!Undecodable}. *)
