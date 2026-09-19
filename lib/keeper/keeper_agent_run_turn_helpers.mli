(** Small helpers used by [Keeper_agent_run.run_turn]. *)

val mark_task_link : keeper:string -> task_id:string -> trace_id:string -> unit

val task_link_already_recorded :
  keeper:string -> task_id:string -> trace_id:string -> bool

val sse_event_progress_kind : Agent_core.Types.sse_event -> string option
(** A low-cardinality label for what a stream event is, for the turn's
    [last_progress_kind]; [None] for a ping. *)

val sse_event_watchdog_progress_kind :
  Agent_core.Types.sse_event -> string option
(** The label when the event shows the provider still producing, which is
    what the attempt watchdog measures progress by: a non-empty text,
    reasoning, tool-argument, media or redacted-thinking delta, a redacted
    thinking block delivered whole in its block start, or a tool block
    opening. Carrier and control frames give [None]. Whether the
    production is deliverable is judged by the accept gate when the stream
    ends, not here. *)

val registry_progress_on_event :
  record_turn_progress:(string -> unit) ->
  (Agent_core.Types.sse_event -> unit) option ->
  Agent_core.Types.sse_event ->
  unit

val emit_turn_end_safely : keeper_name:string -> unit -> unit

val runtime_manifest_context :
  keeper_name:string ->
  trace_id:string ->
  keeper_turn_id:int ->
  Keeper_runtime_manifest.turn_context

val run_teardown_protected :
  keeper_name:string -> site:string -> (unit -> unit) -> unit
(** Run a teardown thunk inside [Eio.Cancel.protect] so it still performs its
    I/O when the caller's context is already cancelled, and report every
    failure — [Eio.Cancel.Cancelled] included — through the
    [DispatchEventFailures] counter and a WARN. No failure path is silent.

    Callers must already be inside an Eio context. The thunk is expected to
    bound its own work; [protect] makes it uncancellable for its duration. *)

val cleanup_agent_setup :
  keeper_name:string -> Keeper_run_tools.agent_setup -> unit
(** Tear down one turn's tool bundle through {!run_teardown_protected} at site
    ["tool_cleanup"]. Best effort: it never raises, so it cannot mask the
    turn's own outcome. *)

val run_with_setup_cleanup : cleanup:(unit -> unit) -> (unit -> 'a) -> 'a

type append_manifest_fn =
  ?elapsed_ms:int ->
  ?logical_seq:int ->
  ?status:string ->
  ?decision:Yojson.Safe.t ->
  ?keeper_turn_id:int ->
  ?agent_core_turn_count:int ->
  ?checkpoint_path:string ->
  site:string ->
  Keeper_runtime_manifest.event_kind ->
  unit

val make_append_manifest :
  config:Workspace.config ->
  keeper_name:string ->
  trace_id:string ->
  runtime_id:string ->
  turn_start:Mtime.t ->
  seq_ref:int Atomic.t ->
  append_manifest_fn

(** When a turn says that the atoms of its trace are numbered from zero (RFC
    librarian-lifecycle 4.6). A reader may act on a restart line as soon as it
    sees it, so the line must not be ahead of the restart. *)
type restart_notice =
  | No_restart_notice  (** The turn continues a history with atoms. *)
  | Notice_at_turn_start
      (** The turn starts from no atom and the saved history is known to hold
          none: nothing can be saved before the line. *)
  | Notice_after_first_save
      (** The turn starts from no atom because its checkpoint could not be
          loaded. What is saved may still hold atoms; the restart happens only
          if a save of this turn is accepted, so the line follows the first
          accepted stage save. If the first accepted save is the finalize
          save, this turn writes no restart line of its own and its
          [Fresh_history] end line is that line, counted by
          {!note_restart_line_stood_in} so the branch is not silent. *)

(** Pure. Every pair is listed. *)
val restart_notice :
  Keeper_turn_boundaries.history_at_start ->
  Keeper_run_context.saved_history ->
  restart_notice

type restart_site =
  | At_turn_start
  | After_first_save

(** The [site] label of the failure counter. *)
val restart_site_label : restart_site -> string

(** Append a [History_restarted] line. Never fails the turn: a line that cannot
    be written is logged and counted. Only a cancellation escapes. *)
val record_history_restart :
  config:Workspace.config ->
  keeper_name:string ->
  trace_id:string ->
  restart_site ->
  unit

(** Count a turn that owed [Notice_after_first_save] and reached its end with
    the notice unconsumed: no stage save was accepted, so its own
    [Fresh_history] line stood in for the restart line. Not a failure -- a
    reader is told the same thing -- but the only record that this branch
    ran. *)
val note_restart_line_stood_in : keeper_name:string -> unit

val turn_progress_callbacks :
  config:Workspace.config ->
  keeper_name:string ->
  downstream:(Agent_core.Types.sse_event -> unit) option ->
  turn_id:int ->
  (string -> unit)
  * bool
  * (unit -> unit) option
  * (unit -> unit) option
  * (Agent_core.Types.sse_event -> unit) option
