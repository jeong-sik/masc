(** Small helpers used by [Keeper_agent_run.run_turn]. *)

val mark_task_link : keeper:string -> task_id:string -> trace_id:string -> unit

val task_link_already_recorded :
  keeper:string -> task_id:string -> trace_id:string -> bool

val per_provider_timeout_for_turn :
  ?oas_timeout_s:float ->
  ?oas_timeout_is_explicit:bool ->
  timeout_s:float ->
  unit ->
  float option

val sse_event_progress_kind : Agent_sdk.Types.sse_event -> string option
val sse_event_watchdog_progress_kind :
  Agent_sdk.Types.sse_event -> string option

val registry_progress_on_event :
  record_turn_progress:(string -> unit) ->
  (Agent_sdk.Types.sse_event -> unit) option ->
  Agent_sdk.Types.sse_event ->
  unit

val emit_turn_end_safely : keeper_name:string -> unit -> unit
val digest_text : string -> string
val digest_message_texts_as_joined : Agent_sdk.Types.message list -> string

val runtime_manifest_context :
  keeper_name:string ->
  agent_name:string ->
  trace_id:string ->
  generation:int ->
  keeper_turn_id:int ->
  Keeper_runtime_manifest.turn_context

val append_runtime_manifest :
  config:Workspace.config ->
  keeper_name:string ->
  agent_name:string ->
  trace_id:string ->
  generation:int ->
  runtime_id:string ->
  ?status:string ->
  ?decision:Yojson.Safe.t ->
  ?keeper_turn_id:int ->
  ?oas_turn_count:int ->
  ?elapsed_ms:int ->
  ?logical_seq:int ->
  ?checkpoint_path:string ->
  ?receipt_path:string ->
  ?compaction_source:string ->
  site:string ->
  Keeper_runtime_manifest.event_kind ->
  unit

val cleanup_agent_setup :
  keeper_name:string -> Keeper_run_tools.agent_setup -> unit

val run_with_setup_cleanup : cleanup:(unit -> unit) -> (unit -> 'a) -> 'a

type append_manifest_fn =
  ?elapsed_ms:int ->
  ?logical_seq:int ->
  ?status:string ->
  ?decision:Yojson.Safe.t ->
  ?keeper_turn_id:int ->
  ?oas_turn_count:int ->
  ?checkpoint_path:string ->
  ?compaction_source:string ->
  site:string ->
  Keeper_runtime_manifest.event_kind ->
  unit

val make_append_manifest :
  config:Workspace.config ->
  keeper_name:string ->
  agent_name:string ->
  trace_id:string ->
  generation:int ->
  runtime_id:string ->
  turn_start:Mtime.t ->
  seq_ref:int Atomic.t ->
  append_manifest_fn

val turn_progress_callbacks :
  config:Workspace.config ->
  keeper_name:string ->
  downstream:(Agent_sdk.Types.sse_event -> unit) option ->
  turn_id:int ->
  (string -> unit)
  * bool
  * (unit -> unit) option
  * (unit -> unit) option
  * (Agent_sdk.Types.sse_event -> unit) option
