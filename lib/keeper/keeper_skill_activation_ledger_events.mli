(** The rows of a session's durable event log.

    A log is one header row followed by one row per change. [event] is one
    change: an activation recorded, deliveries observed, an action observed, a
    transition rejected, or an async result delivered or an async action
    observed. [events_path] is the log file in a session directory.
    [header_to_yojson] and [event_to_yojson] render the header and an event,
    and [event_row] makes a JSON text line of either. [decode_header] refuses
    a header of another schema, session or workspace, and [decode_event]
    reads an event row back. [Keeper_skill_activation_ledger] includes this
    module. *)

open Keeper_skill_activation_ledger_errors
open Keeper_skill_activation_types

val events_path : string -> string

type event =
  | Activation_recorded of activation
  | Deliveries_observed of (string * delivery) list
  | Action_observed of
      { skill_tool_use_ids : string list
      ; action : action
      }
  | Transition_rejected of transition_rejection
  | Async_result_delivered of Keeper_skill_async_delivery.t
  | Async_action_observed of Keeper_skill_async_action.t

val header_to_yojson :
  workspace_key:string ->
  session_id:Keeper_id.Trace_id.t ->
  Yojson.Safe.t

val event_to_yojson : event -> Yojson.Safe.t

val event_row : Yojson.Safe.t -> string

val decode_header :
  expected_workspace_key:string ->
  expected_trace_id:Keeper_id.Trace_id.t ->
  Yojson.Safe.t ->
  (unit, decode_error) result

val decode_event :
  expected_trace_id:Keeper_id.Trace_id.t ->
  Yojson.Safe.t ->
  (event, decode_error) result
