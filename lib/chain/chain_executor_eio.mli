(** Chain Executor - Eio-based Parallel Execution Engine

    Executes compiled Chain DSL plans using Eio fibers for concurrency.
    Supports recursive subgraph execution, checkpoint/resume, and trace generation.

    The internal mutual recursion (20-arm [let rec ... and ...]) is hidden behind
    this interface. External code should only use {!execute} as the entry point.
*)

(** {1 Type Aliases from Chain_types} *)

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

(** {1 Execution Context Types} *)

type iteration_ctx = Chain_iteration.iteration_ctx
type conv_message = Chain_conversation.conv_message
type conversation_ctx = Chain_conversation.conversation_ctx

(** Checkpoint configuration for resume support *)
type checkpoint_config = {
  checkpoint_store: Checkpoint_store.checkpoint_store option;
  checkpoint_enabled: bool;
  resume_from: string option;
  run_id: string;
  fs: Eio.Fs.dir_ty Eio.Path.t option;
}

(** Context passed through execution *)
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

(** Type of MODEL execution callback *)
type exec_fn = Chain_conversation.exec_fn

(** Type of tool execution callback *)
type tool_exec = name:string -> args:Yojson.Safe.t -> (string, string) result

(** {1 Safe Helpers from Chain_utils} *)

include module type of Chain_utils

(** {1 Checkpoint} *)

(** Default checkpoint configuration - no checkpointing *)
val default_checkpoint_config : checkpoint_config

(** Create checkpoint configuration *)
val make_checkpoint_config :
  ?fs:Eio.Fs.dir_ty Eio.Path.t ->
  ?store:Checkpoint_store.checkpoint_store ->
  ?enabled:bool ->
  ?resume_from:string ->
  unit -> checkpoint_config

(** {1 Context} *)

(** Create a new execution context *)
val make_context :
  start_time:float ->
  trace_enabled:bool ->
  timeout:int ->
  chain_id:string ->
  ?langfuse_trace:Langfuse.trace ->
  ?checkpoint:checkpoint_config ->
  unit -> exec_context

(** {1 Trace Utilities} *)

val trace_to_entry : internal_trace -> string -> trace_entry
val traces_to_entries : internal_trace list -> trace_entry list

(** {1 Iteration Support} *)

val substitute_iteration_vars : string -> iteration_ctx option -> string

(** {1 Conversational Mode} *)

val estimate_tokens : string -> int
val make_conversation_ctx :
  ?models:string list -> ?token_threshold:int -> ?window_size:int ->
  unit -> conversation_ctx
val add_message :
  conversation_ctx -> role:string -> content:string ->
  iteration:int -> model:string -> unit
val rotate_model : conversation_ctx -> unit
val needs_summarization : conversation_ctx -> bool
val build_context_prompt : conversation_ctx -> string
val maybe_summarize_and_rotate : exec_fn:exec_fn -> conversation_ctx -> unit

(** {1 Execution Steps} *)

(** Execution step - either single node or parallel group *)
type execution_step =
  | Sequential of node
  | Parallel of node list

(** Convert parallel_groups to execution steps *)
val plan_to_steps : execution_plan -> execution_step list

(** {1 Main Entry Point} *)

(** Execute a compiled execution plan.
    All internal node execution (MODEL, tool, gate, subgraph, etc.)
    and the 20-arm mutual recursion are hidden behind this single entry point. *)
val execute :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  timeout:int ->
  trace:bool ->
  exec_fn:exec_fn ->
  tool_exec:tool_exec ->
  ?input:string ->
  ?checkpoint:checkpoint_config ->
  execution_plan -> chain_result
