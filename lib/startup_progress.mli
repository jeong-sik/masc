(** Startup_progress: how far the boot of the server has come, and when it
    last moved.

    The startup watchdog ends a boot that stops moving, not a boot that is
    slow. "Moves" is what the boot says through this module:

    - {!enter}: the boot reached a step;
    - {!beat}: one unit of work inside the current step finished.

    Both count as progress. The step is also what the readiness probe and
    [masc restart] show while the server is not ready.

    The state is process-global. A process that boots again (a test) starts
    over with {!reset}. *)

(** Where the boot is. The set is closed on purpose: the readiness probe
    answers every requester, so it can carry these words and no others. *)
type step =
  | Initializing  (** Nothing has reported yet. *)
  | Restoring_records  (** The Keeper configuration journal and the run registries. *)
  | Creating_server_state  (** Runtime configuration, workspace state, the Board, credentials. *)
  | Installing_keeper_owners  (** One owner per Keeper, one Keeper at a time. *)
  | Restoring_shutdown_fences  (** Shutdown admission of the previous process. *)
  | Reconciling_keeper_stores  (** Stores this build cannot decode. *)
  | Recovering_transcript_tails  (** Tool cycles the previous process left open. *)
  | Closing_open_turns  (** The turn log line of each Keeper. *)
  | Starting_executors  (** Domain pools and the execution runtime. *)
  | Settling_restarts  (** Operations the previous process left unsettled. *)
  | Activating_owner_state  (** Prompt, tool and MCP assets, gate state, lazy tasks. *)
  | Starting_keeper_loops  (** Claim of the persistence and the Keeper loops. *)

(** The word of a step in the readiness probe and in [masc restart]. *)
val step_to_string : step -> string

(** The boot starts over at {!Initializing}. That counts as progress. *)
val reset : unit -> unit

(** The boot reached [step]. Counts as progress. *)
val enter : step -> unit

(** One unit of work of the current step finished. Counts as progress. *)
val beat : unit -> unit

val current_step : unit -> step

(** Seconds since the last progress, on the monotonic clock. *)
val idle_seconds : unit -> float

(** What the watchdog does with one reading. *)
type verdict =
  | Settled  (** The server is ready: nothing to watch. *)
  | Wait of float  (** Still moving. The seconds are what is left of the stall limit. *)
  | Stalled of float  (** No progress for this many seconds. *)

(** [verdict ~stall_seconds ~ready ~idle_seconds] is {!Settled} once the server
    is ready, {!Stalled} when [idle_seconds] reached [stall_seconds], and
    {!Wait} otherwise. *)
val verdict : stall_seconds:float -> ready:bool -> idle_seconds:float -> verdict
