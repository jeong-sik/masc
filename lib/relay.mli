(** Relay — context-aware session handoff and relay decisions.

    Provides context estimation, relay threshold checks, handoff prompt
    generation, and checkpoint persistence for multi-session continuity.

    @since 0.2.0 *)

(** {1 Types} *)

type relay_config =
  { threshold : float
  ; target_agent : string
  ; compress_ratio : float
  ; include_todos : bool
  ; include_pdca : bool
  ; neo4j_episode : bool
  }

type context_metrics =
  { estimated_tokens : int
  ; max_tokens : int
  ; usage_ratio : float
  ; message_count : int
  ; tool_call_count : int
  }

type handoff_payload =
  { summary : string
  ; current_task : string option
  ; todos : string list
  ; pdca_state : string option
  ; relevant_files : string list
  ; session_id : string option
  ; relay_generation : int
  ; active_goal_ids : string list
  ; goal_progress : (string * float) list
  ; goal_blockers : string list
  }

type task_hint =
  | Large_file_read of string
  | Multi_file_edit of int
  | Long_running_task
  | Exploration_task
  | Simple_task

(** {1 Configuration} *)

val default_config : relay_config

(** {1 Context Estimation} *)

val estimate_context : messages:int -> tool_calls:int -> model:string -> context_metrics

(** {1 Relay Decisions} *)

val should_relay : config:relay_config -> metrics:context_metrics -> bool

val should_relay_proactive
  :  config:relay_config
  -> metrics:context_metrics
  -> task_hint:task_hint
  -> bool

val should_relay_smart
  :  config:relay_config
  -> metrics:context_metrics
  -> task_hint:task_hint
  -> [> `No_relay | `Proactive | `Reactive ]

val estimate_task_cost : task_hint -> int

(** {1 Handoff} *)

val build_handoff_prompt : payload:handoff_payload -> generation:int -> string
val empty_payload : handoff_payload

val compress_context
  :  summary:string
  -> task:string option
  -> todos:string list
  -> pdca:string option
  -> files:string list
  -> ?goal_progress:(string * float) list
  -> ?goal_blockers:string list
  -> unit
  -> string

val get_calibration_info : unit -> Yojson.Safe.t
val record_actual_tokens : estimated:int -> actual:int -> unit

(** {1 Checkpoints} *)

type checkpoint =
  { cp_timestamp : float
  ; cp_summary : string
  ; cp_task : string option
  ; cp_todos : string list
  ; cp_pdca : string option
  ; cp_files : string list
  ; cp_metrics : context_metrics
  }

val save_checkpoint
  :  summary:string
  -> task:string option
  -> todos:string list
  -> pdca:string option
  -> files:string list
  -> metrics:context_metrics
  -> checkpoint

val get_latest_checkpoint : unit -> checkpoint option
val checkpoint_to_payload : checkpoint -> int -> handoff_payload

(** {1 JSON Serialization} *)

val metrics_to_json : context_metrics -> Yojson.Safe.t
val payload_to_json : handoff_payload -> Yojson.Safe.t
