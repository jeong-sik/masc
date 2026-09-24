(** Provider-neutral Keeper projection shared by official CLI runtimes.

    This module owns MASC/AGENT_CORE hooks, typed tool execution, and context
    injection. Protocol adapters only translate the resulting tool records to
    their official client's wire format. *)

val config_error : field:string -> string -> Agent_core.Error.t
(** Build the [InvalidConfig] error the official-client adapters report when a
    runtime is misconfigured. Shared so the three adapters name the offending
    field the same way. *)

val internal_error : string -> Agent_core.Error.t
(** Build the [Internal] error for a failure that is neither configuration nor
    provider behaviour. *)

type prepared_turn =
  { messages : Agent_core.Types.message list
  ; system_prompt : string
  ; tools : Agent_core.Tool.t list
  ; reasoning_effort : Llm_provider.Reasoning_effort.t option
  }

(** What an official-client lane can say about one turn's input handoff.

    [Whole_input_transmitted] carries the MASC-prepared messages handed to the
    client integration. It does not prove that the client placed every byte in
    the provider request or model context. Starts hand over the seed history.
    Codex resume behaviour needs its own evidence and is not inferred from the
    Claude Code path. Client-owned native conversation and tool history outside
    the snapshot are not included in this capture. Do not use this receipt to
    compare per-lane model-input byte totals.

    [Held_by_client_session] means that the lane did not retransmit that
    history, as on Antigravity and Claude Code resumes. The current goal and
    the composed per-turn context ({!resume_prompt}) may still be sent. The accumulated client-owned history is not observable
    here, so attributing the local prepared list would count bytes that were
    not sent. This distinction is not the [Start]/[Resume] distinction. *)
type transmitted_model_input =
  | Whole_input_transmitted of Agent_core.Types.message list
  | Held_by_client_session

type terminal_boundary_outcome = Runtime_official_client_tool.terminal_boundary_outcome =
  | Terminal_completed
  | Durable_stimulus_deferred
  | Terminal_failed of
      { failure_class : Tool_result.tool_failure_class
      ; effect_disposition : Tool_result.failure_effect_disposition
      ; detail : Keeper_terminal_effect_detail.t
      }

type host_stop = Runtime_official_client_tool.host_stop =
  | Repeated_tool_call of
      { tool_name : string
      ; repeated_count : int
      }
  | Terminal_tool_boundary of
      { tool_name : string
      ; outcome : terminal_boundary_outcome
      }

type dynamic_tool_result = Runtime_official_client_tool.dynamic_tool_result =
  { success : bool
  ; content : string
  ; content_blocks : Agent_core.Types.content_block list option
  ; abort_turn : host_stop option
  }

type dynamic_tool = Runtime_official_client_tool.dynamic_tool =
  { name : string
  ; description : string
  ; input_schema : Yojson.Safe.t
  ; call : call_id:string -> Yojson.Safe.t -> dynamic_tool_result
  }

(** One pre_tool_use rejection (typed [Block]) recorded during a turn.
    The official-client CLI owns the live conversation; when it
    escalates the reject to a dead turn this record is the only
    surviving copy of the corrective round-trip (masc#28885). *)
type rejected_tool_call =
  { call_id : string
  ; tool_name : string
  ; input : Yojson.Safe.t
  ; detail : string
  }

type raw_trace_stage =
  | Run_start
  | Assistant_block
  | Tool_start
  | Tool_finish
  | Native_tool_start
  | Native_tool_finish
  | Run_finish

val observe_raw_trace
  :  keeper_name:string
  -> stage:raw_trace_stage
  -> (unit -> ('a, Agent_core.Error.t) result)
  -> 'a option
(** Attempt one secondary RAW-trace observation. A typed trace failure is
    logged and counted but cannot replace the authoritative provider, tool, or
    cancellation result. Reserved exceptions from the observation still
    propagate. *)

val start_raw_trace
  :  keeper_name:string
  -> raw_trace:Agent_core.Raw_trace.t option
  -> prompt:string
  -> ?model:string
  -> ?reasoning_effort:string
  -> unit
  -> Agent_core.Raw_trace.active_run option

val finish_raw_error
  :  keeper_name:string
  -> Agent_core.Raw_trace.active_run option
  -> Agent_core.Error.t
  -> unit

val finish_raw_success
  :  keeper_name:string
  -> Agent_core.Raw_trace.active_run option
  -> Runtime_agent.run_result
  -> Runtime_agent.run_result
(** Complete one official-client RAW run. Observation failure cannot replace
    the authoritative runtime result; a trace reference is returned only when
    every assistant block and the terminal record were persisted. *)

val record_raw_native_tool
  :  keeper_name:string
  -> raw_trace_run:Agent_core.Raw_trace.active_run option
  -> phase:[ `Started | `Finished ]
  -> Runtime_native_tools.observation
  -> unit
(** Best-effort durable observation of an official client's built-in tool.
    It is deliberately separate from MASC tool execution and approval rows. *)

val resolve_reasoning_effort :
  enable_thinking:bool option ->
  reasoning_effort:Llm_provider.Reasoning_effort.t option ->
  (Llm_provider.Reasoning_effort.t option, Agent_core.Error.t) result
(** Reconcile provider-neutral thinking control with an explicit
    official-client effort. An absent effort remains absent. A generic
    [enable_thinking] value is rejected rather than translated. *)

(** One base64 image pulled out of a goal, ready for a transport that carries
    images alongside the prompt text. *)
type image_block =
  { media_type : string
  ; base64_data : string
  }

val text_and_images_of_blocks :
  runtime_label:string ->
  field:string ->
  Agent_core.Types.content_block list ->
  (string * image_block list, Agent_core.Error.t) result
(** Project a goal into the prompt text plus its base64 images. Use this for a
    transport that carries images; {!text_of_blocks} is for one that does not,
    and rejects an image rather than dropping it. Non-base64 image sources and
    every other block kind are rejected here too. *)

val text_of_blocks :
  runtime_label:string ->
  field:string ->
  Agent_core.Types.content_block list ->
  (string, Agent_core.Error.t) result

val encode_history_message : Agent_core.Types.message -> string
(** Preserve one canonical message on a text-only official-client wire. Every
    role uses the same versioned envelope, so raw user bytes cannot spoof the
    framing layer and typed block payloads, tool identities, structured result
    content, failure provenance, and message metadata remain visible. *)

val invoke_turn_completion_hooks :
  runtime_label:string ->
  keeper_name:string ->
  turn_count:int ->
  hooks:Agent_core.Hooks.hooks ->
  Agent_core.Types.api_response ->
  (unit, Agent_core.Error.t) result
(** Run the Agent Core [after_turn] and [on_stop] lifecycle for a completed
    official-client turn. Host-stop projections use the same hook order as a
    provider-emitted terminal before their durable session is settled. *)

val is_composed_system_context : Agent_core.Types.message -> bool
(** Whether this host composed the message for the provider instruction
    surface: the per-turn context carrier or the Librarian working state.
    Adapters keep such messages out of the canonical history snapshot and
    re-send them on resume. *)

val history_role_label : Agent_core.Types.role -> string
(** The role line ([SYSTEM:], [USER:], ...) and its newline that an adapter
    writes in front of one encoded message when it carries messages as prompt
    text. *)

val is_carried_on_resume : Agent_core.Types.message -> bool
(** Whether a resume sends this message in front of its prompt: a message
    {!is_composed_system_context} selects, or the historical task reference
    ({!Keeper_official_task_reference.is_reference}). Both change per turn or
    per operation, which the vendor session cannot already hold.

    A resumed Claude Code session sends the system prompt it recorded at its
    first launch, so a per-turn System message reaches a resumed session only
    when it carries one of these markers. A new kind of per-turn System
    context must be tagged with one; an untagged one lands in the system
    prompt file only, which a resume does not read. *)

val resume_prompt : goal:string -> Agent_core.Types.message list -> string
(** The user prompt a lane sends when it resumes a vendor session that already
    holds the conversation and the system prompt it recorded at its first
    launch. The messages {!is_carried_on_resume} selects are rendered, in
    order, each behind its {!history_role_label}, in front of [goal] and
    separated from it by a blank line. Everything else in [messages] is left
    out: the vendor session holds it. With none selected the prompt is [goal]
    exactly. Antigravity and Claude Code resumes both send this; Antigravity
    refuses a task reference before it composes, so on that lane the
    selection is the composed context alone. *)

val measure_message_bytes : Agent_core.Types.message -> int
(** Bytes one message occupies in the canonical MASC encoding
    ({!encode_history_message}), which is what the range this module composes
    is reported in.

    This is not a ceiling for a lane's own window. Antigravity charges a role
    label and a separator on top of this per message and charges its preamble
    whether or not one is inserted, so a range that measures inside a
    declared max-prompt-bytes here can still be refused there. A lane that has
    a byte ceiling enforces it with its own measure, at the point the refusal
    is raised. *)

(** Who named the front of a start seed. *)
type carried_start_front =
  | Carried_seed of Keeper_carried_front.source
      (** The seed: the newest completed turn record on this history,
          whichever runtime measured it, or the narrowest range an unfinished
          turn reached. *)
  | Lane_cut
      (** The lane's own cut, passed as [own_first_atom], sits at or past the
          seed's position. *)
  | Turn_start
      (** No seed held and the lane cut nothing later, so the range starts
          where the last completed turn on this history ended: this turn's
          own atoms (RFC keeper-context-window-in-tokens §13.4). *)
  | Turn_start_unknown of { reason : string }
      (** No seed, no lane cut, and the turn start could not be read
          ({!Keeper_carried_front.Turn_boundary_unknown}): the range opened
          on the newest atom alone. *)
  | Librarian_snapshot of { absorbed_through : int; boundary_line : int }
      (** The Librarian absorbed this history through [absorbed_through],
          the end of the completed turn on boundary-log row [boundary_line],
          and saved what the keeper was in the middle of. The range starts there
          and carries that working state in place of the atoms it summarises —
          the front the Agent Core lane already takes
          ([Keeper_carried_front.Librarian_snapshot]). [first_atom] is that
          position clamped to the newest atom, so a range that the Librarian
          read to the end still carries the turn it answers; the two differ
          only then. *)
  | Librarian_progress of { end_atom : int }
      (** No working state fits, and the Librarian read this history through
          [end_atom]: the range starts there and nothing is carried for the
          atoms before it, which are in the keeper's memory
          ([Keeper_carried_front.Librarian_progress] on the Agent Core lane).
          [first_atom] is that position clamped to the newest atom. *)

type carried_start =
  { messages : Agent_core.Types.message list
        (** The carried range: the atoms from [first_atom], the pinned
            messages in place, and the preamble when the range opens on a
            non-[User] message. *)
  ; projection : Runtime_model_input_tail_window.projection
  ; history_atom_count : int
  ; first_atom : int
  ; transmitted_bytes : int
  ; front : carried_start_front
  }

(** Where the turn's one continuity choice puts the range, as a position in
    the messages a lane is about to send
    ({!Keeper_turn_driver_try_provider.librarian_position}). The choice is
    made once per turn for every lane
    ({!Keeper_turn_driver_try_provider.continuity_for_request}); this lane
    only applies it. A position the messages no longer hold is not a value
    of this type but an error from the reader ({!librarian_front_reader}),
    and the lane refuses the request with it before any seed is weighed. *)
type librarian_position = Keeper_turn_driver_try_provider.librarian_position

type librarian_front_reader =
  Agent_core.Types.message list -> (librarian_position, Agent_core.Error.t) result
(** Reads the turn's choice as a position in exactly the messages a lane is
    about to cut ({!Keeper_turn_driver_try_provider.librarian_position}).
    [Error] when those messages no longer hold what the choice covered; the
    lane refuses the request with it, as the Agent Core lane refuses its
    own. *)

val read_librarian_front
  :  librarian_front_reader option
  -> Agent_core.Types.message list
  -> (librarian_position, Agent_core.Error.t) result
(** A lane's optional reader applied to its messages, before the range is
    cut. A lane handed no reader has
    {!Keeper_turn_driver_try_provider.No_position}. *)

val carried_start_front_to_string : carried_start_front -> string

val continuity_observation_input
  :  trace_id:string
  -> continuity:Keeper_turn_driver_try_provider.continuity option
  -> carried_start_front
  -> Keeper_continuity_observation.input
(** What the Memory screen records for a request this lane composed
    ({!Keeper_continuity_observation}), in the words the Agent Core lane
    records: [Summarized] when a working state named the front, [Absorbed]
    when the read position did, [Without_snapshot] when the turn's choice
    was no absorbed point, and [Not_applied] when the turn made no choice
    (no trace, or a recovery view) or its choice sat behind the seed or the
    lane's own cut and so was not applied to this request. *)

val carried_start_range
  :  keeper_name:string
  -> runtime_id:string
  -> carried_front_seed:(unit -> Keeper_carried_front.seed_read) option
  -> librarian_front:librarian_position
  -> own_first_atom:int
  -> turn_start:Keeper_carried_front.turn_start
  -> Agent_core.Types.message list
  -> carried_start
(** Where an official client's start seed begins
    (RFC keeper-context-window-in-tokens §10.4).

    The front is a position in the keeper's checkpoint history and this lane
    cuts from that same history, so a range an Agent Core turn measured names
    the same atoms here, and a lane walking to this candidate starts where the
    last completed turn ended instead of at the oldest atom.

    These lanes hold no ledger — it is written from the usage of a request
    this process composed, and an official client composes its own — so the
    caller's seed is the whole answer. Without one the range starts at
    [turn_start], the end of the last completed turn on this history, where
    the Agent Core path starts when no ledger answers either (RFC
    keeper-context-window-in-tokens §13.4); a history with no completed turn
    has [turn_start] 0.

    [librarian_front] is the turn's continuity choice as a position in these
    messages, read by the lane ({!read_librarian_front}): a fitting working
    state ([Librarian_snapshot]), the Librarian's read position alone
    ([Librarian_progress]), or none. That position wins when it is at or past the seed that
    holds, or the lane's own cut when no seed holds, so a Librarian that read
    less than the last request carried never moves the range back.
    [turn_start] is not weighed against it: it is where a request with no
    absorbed point begins, so a Librarian position behind it still names
    atoms nothing else carries, and they go out. A read position alone
    carries nothing for the atoms before it. The working state goes in
    front of the range, as
    extra system context, exactly when a [Librarian_snapshot] position is the
    one that wins: a position the seed or the lane cut already passed stands for
    atoms the range is carrying anyway, and summarising those would say twice
    what the request already says. When it does win, the request grows by
    those bytes, and they are pinned, so a lane with a byte ceiling of its
    own has to be ready for a composition that does not fit it.

    [own_first_atom] is the front the lane already chose for its own reason
    (Claude Code cuts its seed to the runtime's declared max-prompt-bytes). A
    seed at or past that cut decides, even when it is older than
    [turn_start]: the range the last answered request carried is this lane's
    continuity. Without a seed the range starts at the later of the lane's
    cut and [turn_start]; a lane with no cut of its own passes 0. A seed
    whose index this history does not open with the seed's message is
    dropped and reported, and the range starts over as with no seed. *)

(** {1 One window, one decision (RFC-0460)} *)

type windowed_range =
  { carried : carried_start
  ; sent : Agent_core.Types.message list  (** What goes out after the lane's window. *)
  ; atoms_kept : int  (** How many of the range's durable atoms are in [sent]. *)
  }

val carried_atoms : carried_start -> int
(** The durable atoms a range carries, before any window. *)

val window_carried_range
  :  measure_message_bytes:(Agent_core.Types.message -> int)
  -> capacity_bytes:int
  -> reserved_bytes:int
  -> ?source_projection:
       (Agent_core.Types.message list
        -> (Agent_core.Types.message list, Agent_core.Error.t) result)
  -> carried_start
  -> (windowed_range, Agent_core.Error.t) result
(** The range under a declared ceiling. [source_projection] runs first, on
    the range as composed. An omission preamble the range opened on is taken
    off before the window, which charges one itself, and put back when the
    window dropped nothing; a range that fit therefore goes exactly as cut.
    [atoms_kept] counts the range's durable atoms only: what the source
    projection appends is reached by a drop only after all of them. *)

val read_seed_once
  :  (unit -> Keeper_carried_front.seed_read) option
  -> (unit -> Keeper_carried_front.seed_read) option
(** The same seed read, taken at most once, for a lane that composes a range
    more than once in a turn ({!compose_librarian_range}). Sequential use on
    one fiber only. *)

val windowed_projection : windowed_range -> Runtime_model_input_tail_window.projection
(** The window reading counted against the whole history, for
    {!Runtime_model_input_tail_window.observe}: the front it names is an atom
    a later seed can reopen. *)

val compose_librarian_range
  :  keeper_name:string
  -> runtime_id:string
  -> compose:(librarian_position -> (windowed_range, Agent_core.Error.t) result)
  -> librarian_position
  -> (windowed_range, Agent_core.Error.t) result
(** Compose and window the range from the turn's Librarian position, with
    [compose] doing both the way the lane does them.

    A working state goes out only where it displaces none of the atoms after
    the range it leads. A [Librarian_snapshot] position is composed with it
    first, and kept when the window left every atom of the range. Otherwise
    the same position is composed alone ([Librarian_progress] at the
    snapshot's end), and the working state goes only when the window kept at
    least the newest atom and as many atoms with it as without it. When it
    stays out, the request goes with the position alone, a WARN names the
    reason and the first atom sent, and
    [masc_keeper_librarian_working_state_not_carried_total] counts it -- the turn is not
    refused, because that band is usually a Librarian that has not caught up
    yet. A composition the position alone cannot carry is refused with its
    own error. Other positions are composed once, as given. *)

val prepare_turn :
  runtime_label:string ->
  keeper_name:string ->
  turn_count:int ->
  system_prompt:string ->
  tools:Agent_core.Tool.t list ->
  initial_messages:Agent_core.Types.message list ->
  model_input_projection:Agent_core.Agent.model_input_projection option ->
  hooks:Agent_core.Hooks.hooks option ->
  configured_reasoning_effort:Llm_provider.Reasoning_effort.t option ->
  (prepared_turn, Agent_core.Error.t) result
(** [configured_reasoning_effort] seeds the turn params the
    [before_turn_params] hook receives, so a hook can still override it.

    The system prompt is refused when it trims to nothing, after a hook's
    [system_prompt_override] has been applied, as
    [InvalidConfig { field = "system_prompt" }]. Every official client runs
    its own built-in instructions when masc names none, with masc's tool
    surface still attached, so a blank composition is a configuration defect
    named here once rather than in each lane (#33165).

    The hook's [extra_system_context] is appended as a raw [System] message
    carrying {!Agent_core.Types.Extra_system_context_provenance}. Official
    adapters must keep that message on their provider instruction surface; it
    is not an Agent Core synthetic User carrier. The Librarian working state
    is a second [System] message on the same surface, tagged
    {!Runtime_model_input_tail_window.working_state_metadata}; adapters select
    both with {!is_composed_system_context}.

    The seed carries the projected history as-is. Nothing is cut here: the
    provider owns its context window and reports exceeding it as a typed
    terminal, which the shrink sequence in
    {!Keeper_turn_driver_try_provider.context_overflow_shrink_sequence}
    consumes to retry with less. A second ceiling applied before that one
    measured wire bytes instead of tokens and dropped the oldest atoms with no
    copy kept. *)

val dynamic_tools :
  content_transport:Runtime_official_client_tool.content_transport ->
  accepts_image_input:bool ->
  tool_approval:Agent_core.Hooks.tool_approval_callback option ->
  runtime_label:string ->
  keeper_name:string ->
  turn_count:int ->
  tools:Agent_core.Tool.t list ->
  hooks:Agent_core.Hooks.hooks ->
  event_bus:Agent_core.Event_bus.t option ->
  context_injector:Agent_core.Hooks.context_injector option ->
  context:Agent_core.Context.t option ->
  terminal_effect_state:(unit -> Keeper_tools_agent_core.terminal_effect_state) ->
  terminal_error:string option ref ->
  pre_tool_rejects:rejected_tool_call list ref ->
  ?on_tool_boundary:(unit -> (host_stop option, Agent_core.Error.t) result) ->
  ?on_result_handoff:
    (invocation:Agent_core.Tool_contract.Invocation.t -> content:string -> unit) ->
  raw_trace_run:Agent_core.Raw_trace.active_run option ->
  unit ->
  (dynamic_tool list, Agent_core.Error.t) result
(** Project Agent Core tools onto one official-client turn.

    [accepts_image_input] is the runtime's answer to "may a tool result carry an
    image", read from {!Runtime_agent.runtime_accepts_image_input} so it is the
    same composition dispatch applies to a turn's own media. When it is [false]
    an image-bearing result becomes a delivery error before settlement, rather
    than a payload the provider rejects after the tool has already run.

    [on_tool_boundary], when supplied, replaces the provider-local repetition
    detector. It runs after tool settlement and result observers, including when
    exact terminal evidence already stops the turn. Its errors are recorded in
    [terminal_error] and close the host loop without inventing a checkpoint.
    An existing terminal result takes priority over a callback stop.

    [tool_approval] settles a [pre_tool_use] hook that answers
    [ElicitToolApproval], exactly as it does on AGENT_CORE's own tool loop --
    both paths go through
    {!Agent_core.Agent_tool_pre_execution_gate.settle}. Without it such a
    decision is rejected rather than admitted, so a caller that does not
    supply one is no more permissive than before.

    Required rather than optional so a new runtime lane cannot inherit [None]
    by saying nothing. Silence is how one lane came to offer a decision the
    other refused. Three consecutive
    calls with the same tool, canonical input, disposition, and output produce
    [abort_turn]; this is the official-client equivalent of Agent Core's
    repeated exact tool boundary and prevents a vendor-owned loop from holding
    one Keeper and host resources indefinitely. *)

val persist_pre_tool_rejects :
  session_dir:string ->
  session_id:string ->
  rejected_tool_call list ->
  (int, string) result
(** Append a dead turn's reject round-trips to the canonical checkpoint
    so the next turn's replay carries the corrective text (masc#28885:
    every escalated turn lost its correction and the model resent the
    same broken call). Each reject becomes the pair a surviving turn
    already persists — an assistant [ToolUse] block answered by a
    tool-role [ToolResult] with the deterministic validation failure —
    appended in call order. Returns how many rejects were persisted; an
    empty list and a missing checkpoint (no replay exists to correct)
    are both [Ok 0]. Callers flush only on a failed turn: a surviving
    turn's round-trips reach the checkpoint through the next turn's
    history, and appending them here too would duplicate them. *)

val with_run_lifecycle_events :
  event_bus:Agent_core.Event_bus.t option ->
  keeper_name:string ->
  (unit -> (Runtime_agent.run_result, Agent_core.Error.t) result) ->
  (Runtime_agent.run_result, Agent_core.Error.t) result
(** Publish the same typed start and terminal lifecycle owned by Agent Core.
    Official clients own their internal model loop, so this host boundary is
    the single MASC owner for those events. *)

val clamp_reasoning_effort_to_catalog :
  model_id:string option ->
  requested:Llm_provider.Reasoning_effort.t option ->
  Llm_provider.Reasoning_effort.t option
(** Snap a requested reasoning effort into the catalog's accepted set for
    [model_id]: the requested effort when it is accepted, otherwise the
    nearest accepted effort (highest below; lowest when every accepted effort
    is higher). Pure; pinned by [test_keeper_codex_effort_clamp]. *)

val effective_reasoning_effort :
  runtime_label:string ->
  keeper_name:string ->
  runtime_id:string ->
  model_id:string option ->
  requested:Llm_provider.Reasoning_effort.t option ->
  Llm_provider.Reasoning_effort.t option
(** {!clamp_reasoning_effort_to_catalog} plus the operator-visible info log
    when the effort was snapped. One call site per official-client lane, so
    Codex and Claude Code treat the same declared effort identically. *)

val host_stop_result :
  runtime_id:string ->
  model:string ->
  session_id:string ->
  turn_id:string ->
  turns_used:int ->
  latency_ms:int option ->
  request_context:Runtime_observation.request_context option ->
  host_stop ->
  (Runtime_agent.run_result, Agent_core.Error.t) result
(** Build the provider-neutral checkpoint terminal after an official-client
    adapter stops its vendor-owned loop. The external client session is the
    durable continuation owner, so no Agent Core checkpoint is synthesized.

    The turn's spend is not observed: no adapter has a terminal usage frame
    after a host stop, so the response carries no usage and the scope is
    unavailable. [request_context] is the context the newest request
    occupied when the adapter saw one (Claude Code's assistant frames).

    Non-failed stops carry a one-attempt runtime observation (masc#31312):
    the vendor loop did run to reach this boundary, and a [None] observation
    here made every host-stopped turn classify as [Runtime_not_observed],
    which the operator disposition surfaced as "unmapped_runtime_state". *)



val admit_native_posture :
  posture:Runtime_native_tools.posture ->
  approval_mode:Keeper_tool_approval_mode.mode ->
  none_supported:bool ->
  client_label:string ->
  (unit, string) result
(** Pure admission rule for RFC-0390. [Native_none] is refused when the
    client cannot disable its built-in tools. [Native_full] is refused
    unless the keeper's approval stance is [Yolo]: built-in calls run inside
    the vendor process and never reach [ElicitToolApproval], so full native
    effects are admitted only where every MASC call would also run unasked.
    This is the typed predicate only — see {!resolve_native_posture} for
    what a refusal does to the turn. *)

val resolve_native_posture :
  posture_source:Runtime_native_tools.posture_source ->
  base_path:string ->
  keeper_name:string ->
  client_label:string ->
  default:Runtime_native_tools.posture ->
  none_supported:bool ->
  (Runtime_native_tools.posture, Agent_core.Error.t) result
(** The two sources of a posture are handled exhaustively.
    [Program_defined posture]: the program that created the keeper stated
    the posture; no [keepers/<name>.toml] is read (there is none — the
    task-completion reviewer runs in a fresh root it owns), and a stated
    posture is never degraded: failed admission is a config error.
    [Declared_on_disk]: read the keeper's declared posture from its profile
    TOML under [base_path], take [default] when the profile declares no
    [keeper.tools.native], then apply {!admit_native_posture} against the
    keeper's current approval stance. A profile that fails to load — a
    keeper nothing declares included (audit F386) — is a config error, not
    a silent default.
    An admission refusal does not fail this call: the posture degrades to
    the safest weaker one ([full] -> [read]; [none] -> [read] where the
    client cannot disable built-ins) and the downgrade is published as a
    typed event ([masc.keeper.native_posture_degraded]) — the turn keeps
    running, the record says what was declared and why it was not honored.

    Reporting cadence differs by branch (#30408 review): the [full] ->
    [read] degradation is turn state (the approval mode lives in process
    memory and can flip), so it emits one event per affected turn. The
    [none]-on-a-client-without-a-disable-switch case is a static
    profile-vs-assignment contradiction, so it emits once per process per
    (keeper, client) pair at the first offending resolution and then goes
    quiet until a resolution honors the declaration (which re-arms the
    gate). The effective posture returned is unchanged in both branches.
    The approval stance is in-memory by design; after a restart that means
    a [full] keeper runs degraded-to-[read] turns, each one recorded,
    until an operator re-arms [Yolo]. *)
