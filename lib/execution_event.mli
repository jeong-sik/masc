(** Canonical recursive execution events.

    This module describes execution topology and lifecycle only. Provider
    payloads remain opaque JSON owned by their provider codec; execution
    control must use the typed variants and identifiers below rather than
    inspecting those payloads.

    Events are immutable values. {!Execution_journal} is the authority that
    allocates identifiers and sequence numbers for live execution. *)

module type ID = sig
  type t

  val fresh : unit -> (t, string) result
  val of_string : string -> (t, string) result
  val to_string : t -> string
  val equal : t -> t -> bool
  val compare : t -> t -> int
  val pp : Format.formatter -> t -> unit
  val show : t -> string
end

module Event_id : ID
module Run_id : ID
module Node_id : ID
module Correlation_id : ID

type output_block_kind =
  | Text_block
  | Thinking_block
  | Reasoning_details_block
  | Redacted_thinking_block
  | Image_block
  | Document_block
  | Audio_block
[@@deriving show]

(** Exhaustive structural projection of the canonical provider content type.
    A new [Llm_provider.Types.content_block] variant must be classified here
    before the execution journal can compile. Tool calls and their results are
    structural nodes/updates, never provider output blocks. *)
type content_block_classification =
  | Output_content of output_block_kind
  | Tool_use_content
  | Tool_result_content
[@@deriving show]

val classify_content_block
  :  Llm_provider.Types.content_block
  -> content_block_classification

(** A node's immutable semantic identity.

    [provider_tool_use_id] is provider correlation evidence, not execution
    identity. It may be absent or reused by a provider; {!Node_id.t} remains
    authoritative.

    Provider response identity and canonical tool input are mutable stream
    outcomes, not node identity. They are therefore materialized exactly once
    through [Provider_response_snapshot] and [Tool_input_snapshot]. *)
type node_kind =
  | Agent_run of { agent_name : string }
  | Agent_turn of { ordinal : int }
  | Provider_attempt of
      { ordinal : int
      ; target : Binding_identity.Redacted_snapshot.t
      }
  | Output_block of
      { ordinal : int
      ; block_kind : output_block_kind
      }
  | Tool_invocation of
      { provider_tool_use_id : string option
      ; tool_name : string
      ; schedule : Tool_contract.schedule
      ; completion : Tool_contract.completion
      }
  | Tool_attempt

(** Construct one concrete provider-attempt kind from the authoritative binding
    identity already selected for dispatch. The stored target is its durable
    redacted observation, never a second config resolution or dispatch key. The
    journal allocates the attempt's occurrence identity when the node opens. *)
val provider_attempt : ordinal:int -> Binding_identity.t -> (node_kind, string) result

val pp_node_kind : Format.formatter -> node_kind -> unit
val show_node_kind : node_kind -> string

type node

val make_node
  :  node_id:Node_id.t
  -> run_id:Run_id.t
  -> parent_node_id:Node_id.t option
  -> kind:node_kind
  -> (node, string) result

val node_id : node -> Node_id.t
val node_run_id : node -> Run_id.t
val parent_node_id : node -> Node_id.t option
val node_kind : node -> node_kind
val equal_node : node -> node -> bool

(** Typed progress carriers. Streaming deltas and provider/tool progress remain
    opaque codec-owned JSON. Final output, tool-use input, and tool-result
    snapshots retain the canonical provider content type, so their structural
    classification cannot disagree with an untyped JSON label. *)
type node_update =
  | Provider_event of Yojson.Safe.t
  | Provider_response_snapshot of Llm_provider.Types.api_response
  | Output_delta of Yojson.Safe.t
  | Output_snapshot of Llm_provider.Types.content_block
  | Tool_input_delta of Yojson.Safe.t
  | Tool_input_snapshot of Llm_provider.Types.content_block
  | Tool_progress of Yojson.Safe.t
  | Tool_result of Llm_provider.Types.content_block
[@@deriving show]

type failure_kind =
  | Provider_failure
  | Tool_failure
  | Hook_failure
  | Observer_failure
  | Persistence_failure
  | Protocol_failure
  | Internal_failure
[@@deriving show]

type failure =
  { kind : failure_kind
  ; detail : string
  ; data : Yojson.Safe.t option
  }
[@@deriving show]

type terminal =
  | Succeeded
  | Failed of failure
  | Cancelled of
      { reason : string option
      ; data : Yojson.Safe.t option
      }
[@@deriving show]

type payload =
  | Node_opened of node
  | Node_updated of
      { node_id : Node_id.t
      ; update : node_update
      }
  | Node_closed of
      { node_id : Node_id.t
      ; terminal : terminal
      }
[@@deriving show]

(** Opaque external event-domain identity. Its diagnostic representation is not
    a control-flow protocol. *)
module External_source : sig
  type t

  val of_string : string -> (t, string) result
  val to_string : t -> string
  val equal : t -> t -> bool
  val compare : t -> t -> int
  val pp : Format.formatter -> t -> unit
end

(** Explicit execution causality. [Internal_event] references an event in the
    same journal. [External_event] identifies an event owned by another typed
    event domain without overloading the execution event identifier namespace. *)
type cause =
  | Internal_event of Event_id.t
  | External_event of
      { source : External_source.t
      ; event_id : string
      }
[@@deriving show]

type t
type validated_payload
type validated_terminal

(** Validate terminal-owned JSON and semantic boundaries once. The immutable
    certificate can be reused to close every node in one atomic subtree. *)
val validate_terminal : terminal -> (validated_terminal, string) result

(** Build a close payload from an already validated terminal without walking
    the terminal JSON again. This certifies payload data only; journal reducer
    topology and lifecycle validation still run when the event is appended. *)
val close_payload : node_id:Node_id.t -> validated_terminal -> validated_payload

(** Validate all payload-owned JSON and semantic boundaries. The returned
    value is immutable evidence that expensive payload validation completed. *)
val validate_payload : payload -> (validated_payload, string) result

(** Build a decoded or journal-issued event. The envelope must contain a
    positive sequence number and its [run_id] must match the payload's node or
    target node at reducer time. Graph invariants are enforced by
    {!Execution_journal.Reducer.apply}. *)
val make
  :  ?causes:cause list
  -> envelope:Event_envelope.t
  -> payload
  -> (t, string) result

(** Construct an event from a validation certificate. Envelope, cause, and
    graph validation still run; payload JSON is not traversed again. *)
val make_validated
  :  ?causes:cause list
  -> envelope:Event_envelope.t
  -> validated_payload
  -> (t, string) result

val envelope : t -> Event_envelope.t
val event_id : t -> Event_id.t
val run_id : t -> Run_id.t
val correlation_id : t -> Correlation_id.t
val seq : t -> int
val parent_event_id : t -> Event_id.t option
val causes : t -> cause list
val payload : t -> payload
val equal : t -> t -> bool
val node_kind_to_yojson : node_kind -> (Yojson.Safe.t, string) result
val node_kind_of_yojson : Yojson.Safe.t -> (node_kind, string) result
val node_update_to_yojson : node_update -> (Yojson.Safe.t, string) result
val node_update_of_yojson : Yojson.Safe.t -> (node_update, string) result
val terminal_to_yojson : terminal -> (Yojson.Safe.t, string) result
val terminal_of_yojson : Yojson.Safe.t -> (terminal, string) result
val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result

(** One canonical JSON object. Transport framing belongs to the durable store
    or transport adapter, not to this in-memory event model. *)
val to_json_string : t -> string

val of_json_string : string -> (t, string) result
