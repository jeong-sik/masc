(** Chain Trace Types - Execution Tracing Types *)

(** Trace event types for execution logging *)
type trace_event =
  | NodeStart of { node_type : string; attempt : int }
  | NodeComplete of { duration_ms : int; success : bool; node_type : string; attempt : int }
  | NodeError of { message : string; error_class : string option; node_type : string; attempt : int }
  | ChainStart of { chain_id : string; mermaid_dsl : string option }
  | ChainComplete of { chain_id : string; success : bool }

(** Internal trace entry for execution *)
type internal_trace = {
  timestamp : float;
  node_id : string;
  event : trace_event;
}

(** Execution phase for node status tracking *)
type exec_phase =
  | Planned
  | Running
  | Completed
  | Failed
  | Skipped

(** {1 Trace Conversion Functions} *)

(** Convert internal_trace to Chain_types.trace_entry *)
val trace_to_entry : internal_trace -> string -> Chain_types.trace_entry

(** Convert internal traces to trace_entry list, pairing start/complete events *)
val traces_to_entries : internal_trace list -> Chain_types.trace_entry list
