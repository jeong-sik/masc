(** The write path of a ledger: appending an event to a store under its
    session lock.

    [with_write_lock] runs a function under the session lock with a [writer],
    and calls the commit observer after it when the function attempted an
    append, also when it raised. The commit-state observer receives [Some]
    exact ledger after a successful commit under the lock and [None] for an
    uncertain append after the lock. [install_commit_observer] sets the
    attempted-append observer, and [withdraw_commit_observer] unsets it when
    it is still the one installed. [install_commit_state_observer] installs
    the cacheable-state observer and returns its restoration.
    [commit_event_locked] appends one event after the rows a session log was
    read to and returns the ledger the event makes. [record] records an
    activation, and [record_original_invocation] does the same but ignores the
    activation time when it compares a nested composition invocation with the
    one already stored; both return [Already_recorded] for an activation that
    is already stored. [reject_transition_locked] records a transition
    rejection and returns the error that caused it.
    [Keeper_skill_activation_ledger] includes this module. *)

open Keeper_skill_activation_types
open Keeper_skill_activation_ledger_errors
open Keeper_skill_activation_ledger_model
open Keeper_skill_activation_ledger_events
open Keeper_skill_activation_ledger_load

type writer = { mutable appended : bool; mutable committed : bool }

val install_commit_observer :
  (config:Workspace.config -> trace_id:Keeper_id.Trace_id.t -> unit) -> unit

val withdraw_commit_observer :
  (config:Workspace.config -> trace_id:Keeper_id.Trace_id.t -> unit) -> unit

val install_commit_state_observer :
  (config:Workspace.config -> keeper_name:string -> trace_id:Keeper_id.Trace_id.t -> t option -> unit) ->
  (unit -> unit)

val with_write_lock :
  config:Workspace_utils_backend_setup.config ->
  keeper_name:string ->
  trace_id:Keeper_id.Trace_id.t ->
  (writer ->
   ownership_root:string ->
   string ->
   ('a, store_error) result) ->
  ('a, store_error) result

val commit_event_locked :
  config:Workspace.config ->
  keeper_name:string ->
  writer ->
  string ->
  session_log ->
  event ->
  (t,
   store_error)
  result

val record :
  config:Workspace.config ->
  keeper_name:string ->
  trace_id:Keeper_id.Trace_id.t ->
  activation ->
  (t * record_outcome, store_error) result

val record_original_invocation :
  config:Workspace.config -> keeper_name:string -> trace_id:Keeper_id.Trace_id.t -> activation ->
  (t * record_outcome, store_error) result

val reject_transition_locked :
  config:Workspace.config ->
  keeper_name:string ->
  writer ->
  string ->
  session_log ->
  transition_rejection ->
  store_error ->
  ('a, store_error) result
