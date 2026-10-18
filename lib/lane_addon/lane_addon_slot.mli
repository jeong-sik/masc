(** Engine-facing procedures that decide who holds a container, written
    against a [port] so the worker's command runner and an in-memory engine
    run the same code. No procedure here spawns a process.

    A worker slot is one container name: the shared writer name of a
    persistent installation, or the per-incarnation name of an ephemeral
    worker. Incarnations of one installation share the persistent name, so a
    server that died abruptly leaves its worker's container holding the name
    the next incarnation needs. That is safe to clear only because one server
    process owns a workspace at a time: [Server_startup_takeover]'s base-path
    lock, taken by [bin/main_eio.ml] before any Add-on runs, refuses a second
    server on the same base path, so an instance that is not live in this
    process is not live anywhere. *)

type port = {
  read_engine :
    unit -> (Lane_addon_lifecycle.engine, Lane_addon_lifecycle.engine_fault) result;
      (** The identity of the engine the control command reaches now. *)
  find : Lane_addon_engine.lookup -> (string option, string) result;
      (** The container ID under a name or ID. [Ok None] is an absence read
          from whichever engine answered; see {!proven}. *)
  inspect : string -> (Lane_addon_engine.held, string) result;
  remove : string -> (unit, string) result;
      (** Removes exactly this container and confirms it no longer lists.
          Persistent state volumes are untouched. *)
  scoped : unit -> (string list, string) result;
      (** The containers that carry this server's base-path scope label. *)
}

val proven :
  port -> expected:Lane_addon_lifecycle.engine ->
  lift:(Lane_addon_lifecycle.failure -> 'error) ->
  (unit -> ('value, 'error) result) -> ('value, 'error) result
(** Runs [work] only on the [expected] engine and returns its result only if
    the engine answering afterwards is still that one. The CLI follows an
    ambient context that another process can change between two commands, so
    an answer such as "no such container" counts only when the same engine
    was reached before and after it. A different engine, or an engine that
    cannot name itself, yields [Engine_mismatch]; one that does not answer
    yields [Engine_unreachable]. [work] is not run in either case. *)

(** Who holds a slot, relative to the worker asking. *)
type holder_class =
  | Mine
  | Predecessor of { instance_id : string }
      (** The same persistent installation's container, made by an
          incarnation that is not live in this process. *)
  | Foreign of Lane_addon_lifecycle.holder
      (** Anything else, including a sibling incarnation that is live. *)

val classify :
  instance_id:string -> mine:string option -> is_live_instance:(string -> bool) ->
  Lane_addon_engine.held -> holder_class
(** [mine] is the state owner label this worker's containers carry, [None] for
    an ephemeral worker. A predecessor must carry that same owner label, so a
    container that merely has the slot's name is never one. *)

val claim :
  port -> name:string -> instance_id:string -> mine:string option ->
  is_live_instance:(string -> bool) -> (unit, Lane_addon_lifecycle.failure) result
(** Makes the slot free for a create. A dead predecessor, or a leftover of
    this very incarnation, is removed by exact ID. A foreign holder is refused
    with [Slot_foreign] naming it, and nothing is removed. *)

val release :
  port -> lookup:Lane_addon_engine.lookup -> instance_id:string -> mine:string option ->
  (unit, Lane_addon_lifecycle.failure) result
(** Removes this incarnation's container. By name, a container that is not
    this incarnation's is left alone and nothing is owed: a name held by
    another owner means this incarnation's create never landed. By ID, a
    container that is not this incarnation's is [Slot_foreign]. *)

(** What a sweep did with one container of this base path. *)
type sweep_verdict =
  | Removed
  | Live  (** Its incarnation is live in this process. *)
  | Refused of Lane_addon_lifecycle.failure

type sweep_item = {
  container_id : string;
  instance : string option;
  verdict : sweep_verdict;
}

val sweep :
  port -> runtime:Lane_addon_types.runtime -> is_live_instance:(string -> bool) ->
  (sweep_item list, Lane_addon_lifecycle.failure) result
(** Removes the containers a dead server left behind. Only containers that
    carry this base path's scope label are considered. A container whose
    incarnation is live is left alone. A dead one is removed by exact ID only
    when its labels explain its name: the writer name derived from its state
    owner label, or the per-incarnation name derived from its instance label.
    Anything else is refused and named. The engine must answer and name itself
    first; otherwise nothing is touched. *)

val sweep_item_to_string : sweep_item -> string
(** One log line for a removed or refused container. *)

val holder_changed : port -> Lane_addon_lifecycle.holder -> bool
(** True when the container is gone or its labels are no longer the ones the
    holder was refused for. False also when that cannot be read. *)
