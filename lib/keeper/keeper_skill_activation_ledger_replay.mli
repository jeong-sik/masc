(** Applying event rows to a ledger, and replaying a whole store.

    A [builder] holds a ledger while rows are applied to it.
    [builder_of_ledger] starts one from a ledger, [apply_event] applies one
    event, and [ledger_of_builder] returns the ledger. [complete_rows] splits
    store bytes into the rows ended by a newline and refuses a blank row, and
    [apply_event_rows] decodes rows and applies their events to a ledger.
    [replay_store] reads a whole store, its header and then every event.
    [starts_with_complete_row] says whether bytes are empty or hold a complete
    first row, and [replay_store] refuses other bytes as
    [Unterminated_header_row]. [Keeper_skill_activation_ledger] includes this
    module. *)

open Keeper_skill_activation_ledger_errors
open Keeper_skill_activation_ledger_model
open Keeper_skill_activation_ledger_events
open Keeper_skill_activation_types

(* The ledger while rows are applied to it. Each activation sits in a cell
   an event updates in place, so applying a row costs the same however many
   activations came before it. A builder serves one batch of rows and is
   dropped when any of them fails. *)
type builder =
  { builder_workspace_key : workspace_key
  ; builder_session_id : Keeper_id.Trace_id.t
  ; cells : (string, activation ref) Hashtbl.t
  ; mutable cells_newest_first : activation ref list
  ; mutable rejections_newest_first : transition_rejection list
  ; mutable async_deliveries_newest_first : Keeper_skill_async_delivery.t list
  ; mutable async_actions_newest_first : Keeper_skill_async_action.t list
  }

val builder_of_ledger :
  t -> builder

val ledger_of_builder :
  builder -> t

val apply_event :
  builder ->
  event ->
  (unit, decode_error) result

val complete_rows :
  string ->
  (string list, decode_error)
  result

val apply_event_rows :
  expected_trace_id:Keeper_id.Trace_id.t ->
  t ->
  string list ->
  (t,
   decode_error)
  result

val starts_with_complete_row : string -> bool

val replay_store :
  workspace_root:string ->
  expected_trace_id:Keeper_id.Trace_id.t ->
  string ->
  (t * bool,
   decode_error)
  result
