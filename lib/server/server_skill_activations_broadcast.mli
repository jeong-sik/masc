(** Sends {!Keeper_skill_activations_changed_event} when a Keeper's skill
    activation ledger takes a record (RFC-0483 §4.2). *)

val keeper_of_trace :
  Keeper_registry.registry_entry list -> Keeper_id.Trace_id.t -> string option
(** The Keeper whose current trace is [trace_id], from registry entries. The
    ledger knows only the trace; the registry holds each Keeper's trace in
    [meta.runtime.trace_id]. *)

val start :
  sw:Eio.Switch.t -> config:Workspace.config -> trace_id:Keeper_id.Trace_id.t -> unit
(** Starts the announcing fiber on [sw] and returns the observer that feeds
    it. {!install} hands it to the ledger. *)

val install : sw:Eio.Switch.t -> unit
(** Installs the ledger's commit observer and the fiber that announces for
    it. The observer runs on the writer after its session lock is released;
    it records which trace changed and wakes the fiber. The fiber names each
    changed trace from the registry and sends one event per Keeper, so
    commits made while it waits are announced together. A trace no registry
    entry holds, as for a Keeper removed mid-turn, has no reader and is not
    announced; it is counted on [keeper_sse_broadcast_failures] with reason
    [unnamed_trace]. A failed lookup or broadcast is counted with reason
    [broadcast] and logged; the fiber goes on. When [sw] ends the ledger's
    observer is withdrawn, since nothing drains the changes after that; an
    observer installed later stays. *)
