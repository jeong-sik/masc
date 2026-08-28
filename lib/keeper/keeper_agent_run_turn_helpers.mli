(** Small helpers used by [Keeper_agent_run.run_turn]. *)

val mark_task_link : keeper:string -> task_id:string -> trace_id:string -> unit

val task_link_already_recorded :
  keeper:string -> task_id:string -> trace_id:string -> bool

val sse_event_progress_kind : Agent_core.Types.sse_event -> string option
val sse_event_watchdog_progress_kind :
  Agent_core.Types.sse_event -> string option

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
  ?compaction_source:string ->
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
