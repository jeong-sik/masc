(** Successful deferred-tool loads that have not yet reached dispatch.

    The state is stored in one owned Checkpoint Context entry, independently
    of tool-result prose and transcript compaction. It contains only exact
    names actually installed by the loader, scoped to the current work and
    the deferred tools offered by that work.

    A load lives for the Keeper turn that made it and the one turn after it.
    That is the boundary it exists to cross: the loading turn may end before
    calling the tool, and the next turn, restarted or not, is placed with it
    rather than asking again. A load still uncalled when a further turn is
    bound is retired there; a tool that was called is carried by history
    instead. *)

type source =
  | Builtin
  | Attached of
      { provider_id : string
      ; endpoint : string
      ; remote_name : string
      }

type surface_entry =
  { source : source
  ; schema : Agent_core.Types.tool_schema
  }

type error =
  | Invalid_snapshot of string
  | Work_scope_unavailable of string

val error_to_string : error -> string

type restored

(** Validate and restore only this module's Context entry. An absent entry is
    an empty receipt state. Invalid data leaves [target] unchanged. Other
    Context entries are never copied or deleted. *)
val restore
  :  source:Agent_core.Context.t
  -> target:Agent_core.Context.t
  -> (restored, error) result

type t

(** Bind the restored receipts to this exact trace, Task (or no Task),
    absolute Keeper turn, and ordered deferred surface. A changed scope
    retires its outstanding loads. Of an unchanged scope, only loads made in
    [keeper_turn] or the turn immediately before it remain; loads made here
    record [keeper_turn]. A turn resumed under the same [keeper_turn] keeps
    its own loads.
    The surface digest includes each source identity and complete schema,
    including attached tools absent from [Keeper_capability_surface].
    [current_task_id] reads the authoritative work identity at each load,
    so a Task claimed during this turn owns the tools loaded for it. *)
val create
  :  restored:restored
  -> trace_id:Keeper_id.Trace_id.t
  -> task_id:Keeper_id.Task_id.t option
  -> keeper_turn:int
  -> current_task_id:(unit -> (Keeper_id.Task_id.t option, string) result)
  -> surface:surface_entry list
  -> t

val pending_names : t -> string list

(** Execute the actual tool-set extension, then record the installed names
    and exact load invocation in one serialized update. If [apply] raises,
    no receipt is added. An unavailable work identity returns
    [Work_scope_unavailable] without calling [apply] or changing receipts.
    Only the loader may supply [names], from the entries
    it resolved, never directly from the request. The callback must not call
    this module recursively. *)
val loaded
  :  t
  -> invocation:Agent_core.Tool_contract.Invocation.t
  -> names:string list
  -> apply:(unit -> unit)
  -> (unit, error) result

(** Consume only this name's outstanding load when its handler is reached.
    Ordinary history-based carry remains responsible for tools already used.
    A load never dispatched is retired by {!create} instead. *)
val dispatched : t -> name:string -> unit
