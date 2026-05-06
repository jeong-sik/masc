(** Keeper_recurring — In-memory recurring task registry.

    Keepers can register recurring tasks (broadcast, board post)
    that fire on a configurable interval.  The heartbeat loop calls
    [dispatch_due] each cycle to execute overdue tasks.

    Tasks are stored in memory only — they do not survive keeper restart.
    Re-register via MCP tools after restart if needed.

    Thread-safe: protected by Eio.Mutex when available. *)

type action =
  | Broadcast of string   (** Broadcast a message to the keeper's room *)

type recurring_task = {
  id : string;
  keeper_name : string;
  label : string;          (** Human-readable description *)
  interval_sec : int;      (** Minimum seconds between runs *)
  action : action;
  mutable last_run_ts : float;
  mutable run_count : int;
  mutable failure_count : int;
  max_failures : int;      (** Auto-disable after this many consecutive failures, 0 = unlimited *)
  mutable enabled : bool;
}

(** Generate a short unique task ID. *)
val generate_id : unit -> string

(** Register a new recurring task. Returns the task. *)
val add :
  keeper_name:string ->
  label:string ->
  interval_sec:int ->
  ?max_failures:int ->
  action ->
  recurring_task

(** Remove a recurring task by ID. Returns true if found and removed. *)
val remove : id:string -> bool

(** List all recurring tasks for a keeper. *)
val list : keeper_name:string -> recurring_task list

(** List all recurring tasks across all keepers. *)
val list_all : unit -> recurring_task list

(** Dispatch all due recurring tasks for a given keeper.
    [~now_ts] is the current timestamp.
    [~dispatch] is called for each due task's action.
    Returns the number of tasks dispatched. *)
val dispatch_due :
  keeper_name:string ->
  now_ts:float ->
  dispatch:(recurring_task -> action -> (unit, string) result) ->
  int

(** Re-enable disabled recurring tasks for [keeper_name] whose
    [last_run_ts] is older than [2 * interval_sec].

    Tasks are auto-disabled by [dispatch_due] after [max_failures]
    consecutive failures; without periodic re-enable, the keeper's
    heartbeat broadcasts go silent permanently and dependent
    keepers eventually stale-kill the entire fleet.

    Returns the number of tasks re-enabled this call.  Should be
    invoked from the keeper heartbeat tick before [dispatch_due]. *)
val reenable_due_tasks :
  keeper_name:string ->
  now_ts:float ->
  int

(** Serialize a task to JSON. *)
val task_to_json : recurring_task -> Yojson.Safe.t

(** Re-enable disabled recurring tasks after a cooldown period (2x the
    task interval).  Called by the supervisor sweep to prevent permanent
    coordination signal loss when tasks are auto-disabled after
    [max_failures] consecutive failures.

    Returns the number of tasks re-enabled. *)
val reenable_due_tasks : keeper_name:string -> now_ts:float -> int

(** Clear all tasks.  For testing only. *)
val clear : unit -> unit
