(** Event Bus sourcing layer for Cognitive Gravity's Memory OS decay.

    Phase4: Sources [decay_trigger] values from live Board posts, Task
    transitions, and Git events, then feeds them to
    {!Cognitive_gravity.apply_decay}.

    This module is the bridge between MASC workspace activity and the
    pure decay engine in {!Cognitive_gravity}. Each source function
    returns a list of [Cognitive_gravity.decay_trigger] values that
    represent recent events on that channel. *)

(** [source_board ~limit ()] queries recent Board posts and returns a
    [BoardPost post_id] trigger for each post that was created or
    updated within the current decay window. *)
val source_board : ?limit:int -> unit -> Cognitive_gravity.decay_trigger list

(** [source_tasks ~since_ids ()] returns [TaskTransition(task_id, status)]
    triggers for tasks whose status changed since the last poll. The
    optional [since_ids] skips already-processed task ids. *)
val source_tasks : ?since_ids:string list -> unit -> Cognitive_gravity.decay_trigger list

(** [source_git ~since_ref ()] returns [GitEvent event_type] triggers
    for recent git activity (pushes, merges, PRs) relative to
    [since_ref]. Default: last 5 commits. *)
val source_git : ?since_ref:string -> unit -> Cognitive_gravity.decay_trigger list

(** [poll_all ()] calls all three source functions and concatenates
    the results. Use as the main entry point for a periodic decay
    sweep. *)
val poll_all : unit -> Cognitive_gravity.decay_trigger list