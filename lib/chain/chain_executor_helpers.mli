(** Chain Executor Helpers - Types, context, trace, input resolution, and
    substitution utilities used by chain_executor_eio.ml.

    This module contains all standalone helper functions that are not part of
    the mutually recursive execute_* block. *)

(** {1 Type Aliases} *)

type node = Chain_types.node
type node_type = Chain_types.node_type
type chain = Chain_types.chain
type chain_config = Chain_types.chain_config
type chain_result = Chain_types.chain_result
type execution_plan = Chain_types.execution_plan
type trace_entry = Chain_types.trace_entry
type token_usage = Chain_types.token_usage
type merge_strategy = Chain_types.merge_strategy
type adapter_transform = Chain_types.adapter_transform

(** {1 Trace Types} *)

type trace_event = Chain_trace_types.trace_event =
  | NodeStart of { node_type : string; attempt : int }
  | NodeComplete of { duration_ms : int; success : bool; node_type : string; attempt : int }
  | NodeError of { message : string; error_class : string option; node_type : string; attempt : int }
  | ChainStart of { chain_id : string; mermaid_dsl : string option }
  | ChainComplete of { chain_id : string; success : bool }

type internal_trace = Chain_trace_types.internal_trace = {
  timestamp : float;
  node_id : string;
  event : trace_event;
}

type exec_phase = Chain_trace_types.exec_phase =
  | Planned | Running | Completed | Failed | Skipped

(** {1 Execution Context} *)

type iteration_ctx = Chain_iteration.iteration_ctx
type conv_message = Chain_conversation.conv_message
type conversation_ctx = Chain_conversation.conversation_ctx

type checkpoint_config = {
  checkpoint_store: Checkpoint_store.checkpoint_store option;
  checkpoint_enabled: bool;
  resume_from: string option;
  run_id: string;
  fs: Eio.Fs.dir_ty Eio.Path.t option;
}

type exec_context = {
  outputs: (string, string) Hashtbl.t;
  traces: internal_trace list ref;
  start_time: float;
  trace_enabled: bool;
  timeout: int;
  mutable iteration_ctx: iteration_ctx option;
  mutable conversation: conversation_ctx option;
  cache: (string, string * float) Hashtbl.t;
  mutable total_tokens: Chain_category.token_usage;
  langfuse_trace: Langfuse.trace option;
  checkpoint: checkpoint_config;
  node_status: (string, exec_phase) Hashtbl.t;
  node_attempts: (string, int) Hashtbl.t;
  chain_id: string;
}

(** {1 Random State} *)

val executor_rng : Random.State.t

(** {1 Context Management} *)

val default_checkpoint_config : checkpoint_config
val make_context :
  start_time:float -> trace_enabled:bool -> timeout:int -> chain_id:string ->
  ?langfuse_trace:Langfuse.trace -> ?checkpoint:checkpoint_config -> unit -> exec_context
val set_node_status : exec_context -> string -> exec_phase -> unit
val next_attempt : exec_context -> string -> int

(** {1 Chain_utils re-exports} *)

include module type of Chain_utils

(** {1 Checkpoint} *)

val make_checkpoint_config :
  ?fs:Eio.Fs.dir_ty Eio.Path.t -> ?store:Checkpoint_store.checkpoint_store ->
  ?enabled:bool -> ?resume_from:string -> unit -> checkpoint_config
val save_checkpoint : exec_context -> chain_id:string -> node_id:string -> unit
val restore_from_checkpoint : exec_context -> chain_id:string -> (string, string) result
val node_completed_in_checkpoint : exec_context -> string -> bool

(** {1 Output Storage} *)

val store_node_output : exec_context -> node -> string -> unit

(** {1 Trace Helpers} *)

val add_trace : exec_context -> string -> trace_event -> unit
val record_start : ?node_type:string -> exec_context -> string -> unit
val record_complete : ?node_type:string -> exec_context -> string -> duration_ms:int -> success:bool -> unit
val record_error : ?node_type:string -> exec_context -> string -> string -> unit
val trace_to_entry : internal_trace -> string -> trace_entry
val traces_to_entries : internal_trace list -> trace_entry list

(** {1 Input Resolution} *)

val resolve_single_input : exec_context -> string -> string
val resolve_inputs : exec_context -> (string * string) list -> (string * string) list

(** {1 Substitution} *)

val substitute_prompt : string -> (string * string) list -> string
val substitute_json : exec_context -> Yojson.Safe.t -> Yojson.Safe.t
val substitute_iteration_vars : string -> iteration_ctx option -> string

(** {1 Conversation} *)

val estimate_tokens : string -> int
val make_conversation_ctx : ?models:string list -> ?token_threshold:int -> ?window_size:int -> unit -> Chain_conversation.conversation_ctx
val add_message : Chain_conversation.conversation_ctx -> role:string -> content:string -> iteration:int -> model:string -> unit
val rotate_model : Chain_conversation.conversation_ctx -> unit
val needs_summarization : Chain_conversation.conversation_ctx -> bool
val build_context_prompt : Chain_conversation.conversation_ctx -> string
val maybe_summarize_and_rotate : exec_fn:Chain_conversation.exec_fn -> Chain_conversation.conversation_ctx -> unit

(** {1 Node Execution Types} *)

type exec_fn = Chain_conversation.exec_fn

(** Judge/evaluator call routed through OAS cascade pipeline.
    Uses cascade_name "chain_judge" for inference parameter delegation. *)
val judge_call : prompt:string -> unit -> (string, string) result

type tool_exec = name:string -> args:Yojson.Safe.t -> (string, string) result
type execute_node_fn = exec_context -> sw:Eio.Switch.t -> clock:float Eio.Time.clock_ty Eio.Resource.t -> exec_fn:exec_fn -> tool_exec:tool_exec -> Chain_types.node -> (string, string) result

(** {1 Prompt Helpers} *)

val is_complex_prompt : string -> bool
val is_glm_model : string -> bool

val calculate_backoff_delay : Chain_types.backoff_strategy -> int -> float
val should_retry : string list -> string -> bool
