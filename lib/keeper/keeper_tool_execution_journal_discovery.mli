(** How the pending continuations of a base path are found.

    [discovery_scope] says whether to look at every continuation marker
    ([All_pending]) or only at the markers a list of [result_notification]s
    names. [discover_pending_continuations] reads the markers of a scope,
    calls [on_ready] for each continuation that can resume, and returns the
    counts and the failures as a [pending_continuations] value.
    [pending_continuations] does the same for every marker without a callback,
    and [For_testing.pending_continuations] also takes a function that runs
    before a marker is retired.
    [Keeper_tool_execution_journal] includes this module. *)

open Keeper_tool_execution_journal_types
open Keeper_tool_execution_journal_completion
open Keeper_tool_execution_journal_model

type discovery_scope = All_pending | Result_notifications of result_notification list

type pending_continuations =
  { inspected : int; ready : continuation list; waiting : int; unselected : int; retired : int
  ; failures : (string * error) list }

val discover_pending_continuations :
  scope:discovery_scope -> on_ready:(continuation -> unit) -> read_composition_result:read_composition_result ->
  base_path:string -> (pending_continuations, error) result

val pending_continuations :
  read_composition_result:read_composition_result -> base_path:string -> (pending_continuations, error) result

module For_testing :
  sig
    val pending_continuations :
      before_retire:(string -> unit) ->
      read_composition_result:read_composition_result ->
      base_path:string ->
      (pending_continuations,
       error)
      result
  end
