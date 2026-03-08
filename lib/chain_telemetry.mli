(** Chain Telemetry - Event Logging and Observability

    체인 실행 이벤트를 로깅하고 구독 기반 관찰 기능을 제공합니다.

    특징:
    - 비동기 이벤트 발행 (emit)
    - 다중 구독자 지원 (subscribe/unsubscribe)
    - 구조화된 이벤트 타입 (ChainStart, NodeComplete, Error 등)
    - Thread-safe 구독자 관리 (Stdlib.Mutex 사용)

    @author Chain Engine
    @since 2026-01
*)

(** {1 Event Payload Types} *)

(** Chain start event payload *)
type chain_start_payload = {
  start_chain_id: string;
  start_nodes: int;
  start_timestamp: float;
  start_mermaid_dsl: string option;  (** Mermaid diagram for visualization *)
}

(** Node start event payload *)
type node_start_payload = {
  node_start_id: string;
  node_start_type: string;
  node_parent: string option;
}

(** Node complete event payload *)
type node_complete_payload = {
  node_complete_id: string;
  node_duration_ms: int;
  node_tokens: Chain_category.token_usage;
  node_verdict: Chain_category.verdict;
  node_confidence: float;
  node_output_preview: string option;
}

(** Chain complete event payload *)
type chain_complete_payload = {
  complete_chain_id: string;
  complete_duration_ms: int;
  complete_tokens: Chain_category.token_usage;
  nodes_executed: int;
  nodes_skipped: int;
}

(** Error event payload *)
type error_payload = {
  error_node_id: string;
  error_message: string;
  error_retries: int;
  error_timestamp: float;
}

(** {1 Event Types} *)

(** All chain events *)
type chain_event =
  | ChainStart of chain_start_payload
  | NodeStart of node_start_payload
  | NodeComplete of node_complete_payload
  | ChainComplete of chain_complete_payload
  | Error of error_payload

val chain_event_to_yojson : chain_event -> Yojson.Safe.t
val chain_event_of_yojson : Yojson.Safe.t -> (chain_event, string) result

(** {1 Subscription Types} *)

(** Unique subscription identifier *)
type subscription_id = int

(** Subscription handle *)
type subscription

(** Event handler function type *)
type event_handler = chain_event -> unit

(** {1 Event Emission} *)

(** [emit event] sends an event to all active subscribers.

    Thread-safe: takes a snapshot of handlers under lock, then calls them
    outside the lock to prevent deadlocks.

    @param event The event to emit *)
val emit : chain_event -> unit

(** {1 Subscription API} *)

(** [subscribe handler] registers an event handler.

    @param handler Function called for each emitted event
    @return Subscription handle for later unsubscription *)
val subscribe : event_handler -> subscription

(** [unsubscribe sub] removes an event handler.

    Safe to call multiple times on the same subscription.

    @param sub The subscription to cancel *)
val unsubscribe : subscription -> unit

(** [is_active sub] checks if a subscription is still active.

    @param sub The subscription to check
    @return true if the subscription is active *)
val is_active : subscription -> bool

(** [subscriber_count ()] returns the number of active subscribers. *)
val subscriber_count : unit -> int

(** {1 Event Constructors} *)

(** [chain_start ~chain_id ~nodes ?mermaid_dsl ()] creates a ChainStart event.

    @param chain_id Unique identifier of the chain
    @param nodes Total number of nodes in the chain
    @param mermaid_dsl Optional Mermaid diagram for visualization *)
val chain_start : chain_id:string -> nodes:int -> ?mermaid_dsl:string -> unit -> chain_event

(** [node_start ~node_id ~node_type ?parent ()] creates a NodeStart event.

    @param node_id Unique identifier of the node
    @param node_type Type name (e.g., "llm", "tool", "fanout")
    @param parent Optional parent node ID for nested nodes *)
val node_start : node_id:string -> node_type:string -> ?parent:string -> unit -> chain_event

(** [node_complete ~node_id ~duration_ms ~tokens ~verdict ~confidence ?output_preview ()]
    creates a NodeComplete event.

    @param node_id The completed node's ID
    @param duration_ms Execution time in milliseconds
    @param tokens Token usage statistics
    @param verdict Pass/Warn/Fail/Defer result
    @param confidence Confidence score (0.0-1.0)
    @param output_preview Optional truncated output for debugging *)
val node_complete :
  node_id:string ->
  duration_ms:int ->
  tokens:Chain_category.token_usage ->
  verdict:Chain_category.verdict ->
  confidence:float ->
  ?output_preview:string ->
  unit -> chain_event

(** [chain_complete ~chain_id ~duration_ms ~tokens ~executed ~skipped]
    creates a ChainComplete event.

    @param chain_id The completed chain's ID
    @param duration_ms Total execution time
    @param tokens Aggregated token usage
    @param executed Number of nodes executed
    @param skipped Number of nodes skipped *)
val chain_complete :
  chain_id:string ->
  duration_ms:int ->
  tokens:Chain_category.token_usage ->
  executed:int ->
  skipped:int -> chain_event

(** [error ~node_id ~message ~retries] creates an Error event.

    @param node_id The node that failed
    @param message Error description
    @param retries Number of retry attempts made *)
val error : node_id:string -> message:string -> retries:int -> chain_event

(** {1 Running Chains Tracking} *)

(** [register_running_chain ~chain_id ~total_nodes] marks a chain as running.

    @param chain_id The chain's unique ID
    @param total_nodes Total number of nodes for progress calculation *)
val register_running_chain : chain_id:string -> total_nodes:int -> unit

(** [update_chain_progress ~chain_id ~nodes_completed] updates progress.

    @param chain_id The chain to update
    @param nodes_completed Number of completed nodes *)
val update_chain_progress : chain_id:string -> nodes_completed:int -> unit

(** [unregister_running_chain ~chain_id] removes a chain from tracking.

    @param chain_id The chain to unregister *)
val unregister_running_chain : chain_id:string -> unit

(** [get_running_chains ()] returns all running chains.

    @return List of (chain_id, started_at, progress) tuples *)
val get_running_chains : unit -> (string * float * float) list

(** {1 Event Logging} *)

(** [enable_logging ?max_size ()] enables the built-in event log buffer.

    @param max_size Maximum events to retain (default: 10000) *)
val enable_logging : ?max_size:int -> unit -> unit

(** [disable_logging ()] disables the built-in event log. *)
val disable_logging : unit -> unit

(** [get_recent_events ?limit ()] retrieves recent events from the log.

    @param limit Maximum events to return (default: 100)
    @return Events in chronological order (oldest first) *)
val get_recent_events : ?limit:int -> unit -> chain_event list

(** [clear_log ()] clears all events from the log buffer. *)
val clear_log : unit -> unit

(** {1 Event Filtering} *)

(** Filter predicate type *)
type event_filter = chain_event -> bool

(** [chain_events_only event] returns true for ChainStart/ChainComplete. *)
val chain_events_only : event_filter

(** [node_events_only event] returns true for NodeStart/NodeComplete. *)
val node_events_only : event_filter

(** [errors_only event] returns true for Error events. *)
val errors_only : event_filter

(** [for_chain chain_id] creates a filter for a specific chain. *)
val for_chain : string -> event_filter

(** [for_node node_id] creates a filter for a specific node. *)
val for_node : string -> event_filter

(** [subscribe_filtered ~filter handler] subscribes with a filter.

    @param filter Predicate to select events
    @param handler Function called for matching events
    @return Subscription handle *)
val subscribe_filtered : filter:event_filter -> event_handler -> subscription

(** {1 Serialization} *)

(** [event_to_json_string event] converts an event to JSON string. *)
val event_to_json_string : chain_event -> string

(** [event_of_json_string str] parses an event from JSON string.

    @param str The JSON string
    @return Parsed event or error message *)
val event_of_json_string : string -> (chain_event, string) result

(** {1 Pretty Printing} *)

(** [string_of_event event] formats an event for human-readable output. *)
val string_of_event : chain_event -> string

(** {1 Console Logger} *)

(** [console_handler ?prefix event] prints an event to stdout.

    @param prefix Log line prefix (default: "[CHAIN]")
    @param event The event to print *)
val console_handler : ?prefix:string -> chain_event -> unit

(** [enable_console_logging ?prefix ()] subscribes a console logger.

    @param prefix Log line prefix (default: "[CHAIN]")
    @return Subscription handle *)
val enable_console_logging : ?prefix:string -> unit -> subscription
